[string] $DataPath = "$env:ProgramData\WayneKing\RouterControl"
if (-not (Test-Path $DataPath))
{
	mkdir $DataPath | Out-Null
}

[string] $LogFilename = 'RouterControl.log'
[string] $CredFilename = 'routerCredential.clixml'
[string] $KnownDeviceCacheFilename = 'knownDevices.clixml'
[int] $CacheForMinutes = 5

enum AccessControl
{
	Unknown
	Blocked
	Allowed
}

enum ConnectionState
{
	Undetected
	Online
	Offline
}

class Device
{
	[string] $Name
	[string] $DetectedName
	[string] $MacAddress
	[ConnectionState] $Connection
	[AccessControl] $AccessControl
}

function Write-Log ([string] $message)
{
	Write-Information $message
	'{0}: {1}' -f (Get-Date), $message >> "$DataPath\$LogFilename"
}

function Warn-Log #([string] $message)
{
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "")]
	param ([string] $message)

	Write-Warning $message
	'{0}: WARNING: {1}' -f (Get-Date), $message >> "$DataPath\$LogFilename"
}

#.SYNOPSIS
# Truncate text with an ellipsis.
function TextEllipsis([string] $text, [int] $ellipsisAtLength)
{
	if ($text.Length -gt $ellipsisAtLength)
	{
		$text.Substring(0, $ellipsisAtLength) + '...'
	}
	else
	{
		$text
	}
}

#.SYNOPSIS
# Prompts for a credential, then stores it to local disk for use whenever this module needs to access the router.
#.DESCRIPTION
# Call this once to set the credential that will be used in subsequent actions whenever the router is queried.
function Set-RouterCredential
{
	Get-Credential -Message 'Provide credentials for logging in to the router.' |
			Export-Clixml -Path "$DataPath\$CredFilename"
}

#.SYNOPSIS
# Indicates whether or not a credential has been set that this module will use for accessing the router.
#.DESCRIPTION
# Use Set-RouterCredential to set or change the credential.
function Test-RouterCredential
{
	Test-Path -Path "$DataPath\$CredFilename" -PathType Leaf
}

function Get-RouterCredential
{
	# just read every time for now
	if (Test-RouterCredential)
	{
		Import-Clixml -Path "$DataPath\$CredFilename"
	}
	else
	{
		Write-Log "Router credential not found; use 'Set-RouterCredential' before attempting other actions."
		throw "Router credential not found; use 'Set-RouterCredential' before attempting other actions."
	}
}

#.SYNOPSIS
# Import a CSV file that provides device names for known MAC addresses.
#.DESCRIPTION
# Imports the information into memory, and caches it to a private file for future use as needed.
# The CSV must include at least two columns, named 'Name' and 'Mac'.
function Import-KnownDeviceCsv([string] $Path)
{
	$devices = Import-Csv -Path $Path |
			Select-Object -Property 'Name', 'Mac' |
			Assert-KnownDevice

	if ($?)
	{
		if ($devices)
		{
			$devices | Export-Clixml -Path "$DataPath\$KnownDeviceCacheFilename"
		}
		else
		{
			Write-Error "No meaningful device records found in '$Path'."
		}
	}
}

filter Assert-KnownDevice ([parameter(ValueFromPipeline)] $device)
{
	if ($device.Name)
	{
		if ($device.Mac -match '^([0-9A-F]{2}:){5}[0-9A-F]{2}$')
		{
			$device
		}
		else
		{
			Write-Log "Import-KnownDeviceCsv: Malformed or missing MAC address '$($device.Mac)' for device named '$($device.Name)'."
		}
	}
	elseif ($device.Mac)
	{
		Write-Log "Import-KnownDeviceCsv: Missing Name for device with MAC '$($device.Mac)'."
	}
	# else no name and no MAC: completely ignore it
}

#.SYNOPSIS
# Get the known devices from private cache.
function Get-KnownDevice
{
	if (Test-Path "$DataPath\$KnownDeviceCacheFilename")
	{
		# for now, just load the file every time (no in-memory cache)
		Import-Clixml -Path "$DataPath\$KnownDeviceCacheFilename"
	}
	else
	{
		Warn-Log 'A set of known devices (and their names) has not been provided; call Import-KnownDeviceCsv to provide it.'
	}
}

#.SYNOPSIS
# Retrieves an object from cache, or invokes a creator script if cache is empty or expired.
#.PARAMETER name
# A unique identifier for the cached object.
#.PARAMETER creator
# A script that will create or recreate the cached item when evaluated.
# The script should require no input parameters (for now).
function Restore-CachedObject ([string] $name, [ScriptBlock] $creator)
{
	$cached = Get-Variable -Name "cached$name" -ValueOnly -Scope Script -ErrorAction Ignore

	if (-not $cached -or $cached.Expiry -le (Get-Date))
	{
		$cached = @{
				Object = & $creator
				Expiry = (Get-Date).AddMinutes($CacheForMinutes) }
		Set-Variable -Name "cached$name" -Value $cached -Scope Script		
	}

	$cached.Object
}

#.SYNOPSIS
# Clears cached objects, accounting for known cached-object dependency chains.
function Clear-CachedObject ([string] $name)
{
	switch ($name)
	{
	 'Get-Device'
	 {
		Clear-Variable -Name 'cachedInvoke-RouterControlPage' -Scope Script -ErrorAction Ignore
		Clear-Variable -Name 'cachedGet-Device' -Scope Script -ErrorAction Ignore
		break
	 }
	 default
	 {
		Clear-Variable -Name "cached$name" -Scope Script -ErrorAction Ignore
	 }
	}
}

function Invoke-RouterControlPage
{
	Restore-CachedObject 'Invoke-RouterControlPage' { Invoke-RouterControlPage-Core }
}

function Invoke-RouterControlPage-Core
{
	$resp = Invoke-WebRequest `
			-Uri 'http://www.routerlogin.net/DEV_control.htm' `
			-Credential (Get-RouterCredential) `
			-SessionVariable session

	if ($resp.StatusCode -ne 200)
	{
		Write-Log "Non-success response status code '$($resp.StatusCode)' when requesting router control page."
	}

	# retain the session info with the response
	$resp | Add-Member -NotePropertyName 'Session' -NotePropertyValue $session

	$resp
}

#.SYNOPSIS
# Get the list of devices known and controlled by the router.
#.PARAMETER Force
# Query the router for the list instead of returning a list that may have been cached from a prior call.
function Get-Device ([switch] $Force)
{
	if ($Force)
	{
		Clear-CachedObject 'Get-Device'
	}

	Restore-CachedObject 'Get-Device' { @(Get-DeviceFromRouter | Merge-Device (Get-KnownDevice)) }
}

function Get-DeviceFromRouter
{
	$response = Invoke-RouterControlPage
	$elements = $response.AllElements
	
	# there are three sets of rules, each within its own <table>
	# each body row of the tables is a rule: <tr name='row_rules...' >
	$elements | Where-Object name -eq row_rules       | ParseRuleProperties | New-Device -connection 'Online'
	$elements | Where-Object name -eq row_rules_white | ParseRuleProperties | New-Device -connection 'Offline'
	$elements | Where-Object name -eq row_rules_black | ParseRuleProperties | New-Device -connection 'Offline'

	# TODO: do "Assert-RouterDevices" to confirm necessary properties are present
	# 	do it here, or maybe do it JIT in New-Device
}

function ParseRuleProperties([parameter(Mandatory, ValueFromPipeline)] [string] $ruleHtml)
{
 process
 {
	$props = [ordered] @{}

	$matches = [regex]::Matches($ruleHtml,
			# the html is multiple <td><span> that are the rule's properties & values
			'<SPAN .*?name="rule_(?''property''[^"]+)">(?''value''[^<]*)</SPAN>')
	foreach ($match in $matches)
	{
		$prop = $match.Groups['property'].Value
		$value = $match.Groups['value'].Value

		# ignore duplicate properties
		if (-not $props.Contains($prop))
		{
			$props.$prop = $value
		}
	}

	if ($props.Count -eq 0)
	{
		Write-Log ("Unable to extract properties and values for rule with HTML '{0}'." -f (TextEllipsis $ruleHtml 25))
	}

	$props
 }
}

function New-Device (
		[parameter(Mandatory, ValueFromPipeline)] [hashtable] $propertiesValues,
		[parameter()] [ConnectionState] $connection)
{
 process
 {
	$device = New-Object -TypeName 'Device'

	# map raw names to formal names
	switch ($propertiesValues.Keys)
	{
	 'device_name'
	 {
		$device.DetectedName = $propertiesValues.device_name
	 }
	 'mac' 
	 {
		$device.MacAddress = $propertiesValues.mac
	 }
	 'status'
	 {
		$device.AccessControl = $propertiesValues.status
	 }
	 'mac_black'
	 {
		# records with a 'mac_black' have no explicit status property, but are 'blocked'
		$device.MacAddress = $propertiesValues.mac_black
		$device.AccessControl = 'Blocked'
	 }
	 'mac_white'
	 {
		# records with a 'mac_white' have no explicit status property, but are 'allowed'
		$device.MacAddress = $propertiesValues.mac_white
		$device.AccessControl = 'Allowed'
	 }
	}

	if ($connection)
	{
		$device.Connection = $connection
	}

	$device
 }
}

#.SYNOPSIS
# Merge known device information into router-provided device information.
function Merge-Device (
		[parameter(Mandatory, ValueFromPipeline)] [Device] $device,
		[parameter(Mandatory=$false, Position = 1)] [array] $knownDevices)
{
 process
 {
	$knownDevice = $knownDevices.Where({$_.Mac -eq $device.MacAddress}, 'First')

	if ($knownDevice)
	{
		$device.Name = $knownDevice.Name
	}
	else
	{
		$device.Name = '??'
	}

	$device
 }
}

#.SYNOPSIS
# Set a device's AccessControl to Allowed.
function Unblock-Device ([parameter(Mandatory, ValueFromPipeline)] [Device] $Device)
{
 begin
 {
	[int] $count = 0
 }
 process
 {
	if ($count)
	{
		Write-Error -Exception ([NotSupportedException]::new('This cmdlet acts on only one device at a time.'))
	}

	$count++
 }
 end
 {
	if ($Device -and $count -eq 1)
	{
		$current = Get-Device | Where-Object MacAddress -eq $Device.MacAddress

		if (-not $current)
		{
			Warn-Log "Cannot Unblock-Device for device with MAC '$($Device.MacAddress)' because that device is not among the devices known by the router."
			return
		}

		if ($current.AccessControl -eq 'Allowed')
		{
			Write-Log "Unblock-Device for device with MAC '$($Device.MacAddress)' is a no-op because the device is already listed by the router as AccessControl Allowed."
			return
		}

		Update-ConnectedDevice $current 'Allowed'
	}
 }
}

#.SYNOPSIS
# Set a device's AccessControl to Blocked.
function Block-Device ([parameter(Mandatory, ValueFromPipeline)] [Device] $Device)
{
 begin
 {
	[int] $count = 0
 }
 process
 {
	if ($count)
	{
		Write-Error -Exception ([NotSupportedException]::new('This cmdlet acts on only one device at a time.'))
	}

	$count++
}
 end
 {
	if ($Device -and $count -eq 1)
	{
		$current = Get-Device | Where-Object MacAddress -eq $Device.MacAddress

		if (-not $current)
		{
			Warn-Log "Cannot Block-Device for device with MAC '$($Device.MacAddress)' because that device is not among the devices known by the router."
			return
		}

		if ($current.AccessControl -eq 'Blocked')
		{
			Write-Log "Block-Device for device with MAC '$($Device.MacAddress)' is a no-op because the device is already listed by the router as AccessControl Blocked."
			return
		}

		Update-ConnectedDevice $current 'Blocked'
	}
 }
}

#.OUTPUTS
# A Device object with the updated access control state.
function Update-ConnectedDevice ([Device] $device, [AccessControl] $access)
{
	switch ($device.Connection)
	{
	 'Online'
	 {
		Update-OnlineDevice $device $access
		break
	 }
	 'Offline'
	 {
		Update-OfflineDevice $device $access
		break
	 }
	}

	Get-Device -Force | Where-Object MacAddress -eq $device.MacAddress
}

#.PARAMETER access
# The desired access control for the device.
function Update-OnlineDevice ([Device] $device, [AccessControl] $access)
{
	$postFields = GetPostFieldsForDeviceUpdate $device $access
	Invoke-RouterControlPostback $postFields
}

#.PARAMETER access
# The desired access control for the device.
function Update-OfflineDevice ([Device] $device, [AccessControl] $access)
{
	Remove-Device $device
	Add-Device $device $access
}

function Remove-Device ([Device] $device)
{
	# assert this is a private function and that we can trust that the $Device's Connection value
	#  is accurate; otherwise, should lookup device & its Connection via Get-Device
	if ($device.Connection -ne 'Offline')
	{
		Warn-Log "Cannot Remove-Device for device with MAC '$($device.MacAddress)' because that device is not among the devices listed by the router as Connnection Offline."
		return
	}

	$postFields = GetPostFieldsForDeviceRemove $device
	Invoke-RouterControlPostback $postFields
}

function Add-Device ([Device] $device, [AccessControl] $access)
{
	# CONSIDER: this will mutate the passed-in $device; not ideal, OK for now
	$device.AccessControl = $access

	$form = Invoke-RouterControlAddPage

	$postFields = GetPostFieldsForDeviceAdd $device $form
	if ($postFields)
	{
		Invoke-RouterControlAddPostback $form $postFields
	}
}

#.SYNOPSIS
# Enable the router's access control functionality.
#.PARAMETER NewDeviceAccess
# The access behavior to apply to all new (unrecognized) devices.
# When this parameter is omitted, the router's access control functionality will be enabled
#  and the current (or previously set) access behavior for new devices will not modified.
function Enable-AccessControl ([ValidateSet('Blocked','Allowed')] [AccessControl] $NewDeviceAccess)
{
	if ($NewDeviceAccess)
	{
		$postFields = GetPostFieldsForAccessControlEnable $NewDeviceAccess
	}
	else
	{
		$postFields = GetPostFieldsForAccessControlEnable
	}
	
	Invoke-RouterControlPostback $postFields

	Clear-CachedObject 'Invoke-RouterControlPage'
}

#.SYNOPSIS
# Disable the router's access control functionality.
function Disable-AccessControl
{
	$postFields = GetPostFieldsForAccessControlDisable
	Invoke-RouterControlPostback $postFields

	Clear-CachedObject 'Invoke-RouterControlPage'
}

#.SYNOPSIS
#. Gets the current state of the router's access control functionality.
function Get-AccessControl
{
	$page = Invoke-RouterControlPage
	$fields = $page.Forms[0].Fields

	$access = switch ($fields['enable_access_control'])
	{
		'1' { 'Enabled' }
		'0' { 'Disabled' }
		default { '??' }
	}

	$newDevice = if ($access -eq 'Enabled')
	{
		switch ($fields['access_all_setting'])
		{
			'0' { 'Blocked' }
			'1' { 'Allowed' }
			default { '??' }
		}
	}
	else
	{
		'NotApplicable'
	}

	[PSCustomObject] @{ AccessControl = $access; NewDeviceAccess = $newDevice }
}

function GetPostFieldsForAccessControlEnable ([AccessControl] $newDeviceAccess)
{
	# acquire copy of current fields
	$fields = [Hashtable]::new((Invoke-RouterControlPage).Forms[0].Fields)

	$fields['enable_acl'] = 'enable_acl'

	switch ($newDeviceAccess)
	{
		'Allowed' { $fields['access_all'] = 'allow_all' }
		'Blocked' { $fields['access_all'] = 'block_all' }
	}

	$fields
}

function GetPostFieldsForAccessControlDisable
{
	# acquire copy of current fields
	$fields = [Hashtable]::new((Invoke-RouterControlPage).Forms[0].Fields)

	$fields.Remove('enable_acl')

	$fields
}

function GetPostFieldsForDeviceUpdate ([Device] $device, [AccessControl] $access)
{
	$ruleSettings = ComposeRuleSettingsPostbackValue $device $access
	if (-not $ruleSettings)
	{
		return
	}

	# acquire copy of current fields
	$fields = [Hashtable]::new((Invoke-RouterControlPage).Forms[0].Fields)

	# rule_settings effects the change we're making
	$fields['rule_settings'] = $ruleSettings

	# authentic postback includes multiple rule_status_org, one per each device, but dictionary
	#  doesn't allow multiple; router doesn't seem to mind if none are included, so drop it
	$fields.Remove('rule_status_org')

	# indicate whether 'Allow' or 'Block' button was clicked
	if ($access -eq 'Allowed')
	{
		$fields['allow'] = 'allow'
	}
	elseif ($access -eq 'Blocked')
	{
		$fields['block'] = 'block'
	}

	$fields
}

function GetPostFieldsForDeviceRemove ([Device] $device)
{
	# acquire copy of current fields
	$fields = [Hashtable]::new((Invoke-RouterControlPage).Forms[0].Fields)

	$deleteList = '1:{0}:' -f $device.MacAddress

	switch ($Device.AccessControl)
	{
	 'Allowed'
	 {
		$fields['delete_white_lists'] = $deleteList  # device to remove
		$fields['delete_white'] = 'Delete'           # "Remove" button
		break
	 }
	 'Blocked'
	 {
		$fields['delete_black_lists'] = $deleteList  # device to remove
		$fields['delete_black'] = 'Delete'           # "Remove" button
		break
	 }
	}

	$fields
}

function GetPostFieldsForDeviceAdd ([Device] $device, $addPageForm)
{
	$mac = Get-CleanedMac $device
	$name = Get-CleanedName $device
	if (-not ($mac -and $name))
	{
		return
	}

	# acquire copy of the form's fields
	$fields = [Hashtable]::new($addPageForm.Fields)

	$fields['mac_addr'] = $mac
	$fields['dev_name'] = $name
	$fields['action'] = 'Apply'

	switch ($device.AccessControl)
	{
	 'Allowed' { $fields['access_control_add_type'] = 'allowed_list'; break }
	 'Blocked' { $fields['access_control_add_type'] = 'blocked_list'; break }
	}

	$fields
}

#.PARAMETER device
# The device for which access control will be set.
#.PARAMETER access
# Desired access state for device.
function ComposeRuleSettingsPostbackValue ([Device] $device, [AccessControl] $access)
{
	function Convert-AccessToToken ([AccessControl] $access)
	{
		switch ($access)
		{
		 'Allowed' { '1:' }
		 'Blocked' { '0:' }
		 default { throw [ArgumentOutOfRangeException]::new('$access', $access, 'Bad or missing value.') }
		}
	}

	$online = Get-Device | Where-Object Connection -eq 'Online'

	$builder = [Text.StringBuilder]::new()
	$builder.Append($online.Count).Append(':') | Out-Null

	foreach ($dev in $online)
	{
		$builder.Append($dev.MacAddress).Append(':') | Out-Null

		# set target device to $access; others unchanged
		if ($dev.MacAddress -eq $device.MacAddress)
		{
			$builder.Append((Convert-AccessToToken $access)) | Out-Null
		}
		else
		{
			$builder.Append((Convert-AccessToToken $dev.AccessControl)) | Out-Null
		}
	}

	$builder.ToString()
}

#.SYNOPSIS
# Apply the same MAC validations used by the router's add-device page.
function Get-CleanedMac ([Device] $device)
{
	$original = $device.MacAddress

	$mac = $original -replace '[:-]', ''
	$mac = $mac.ToUpper()

	if ($mac -notmatch '^[0-9A-F]{12}$')
	{
		Warn-Log "The MAC '$original' has invalid characters or incorrect length and cannot be used."
	}
	elseif ($mac -match '^[F0]*$')
	{
		Warn-Log "The MAC '$original' is meaningless and cannot be used."
	}
	elseif (IsMulticastMac $mac)
	{
		Warn-Log "The MAC '$original' cannot be used because it is multicast."
	}
	else
	{
		$mac
	}
}

function IsMulticastMac ([string] $mac)
{
	[int]::Parse($mac.Substring(0, 2), [Globalization.NumberStyles]::HexNumber) -band 1
}

#.SYNOPSIS
# Apply the same device name validations used by the router's add-device page.
function Get-CleanedName ([Device] $device)
{
	$name = $device.Name
	if ([string]::IsNullOrWhiteSpace($name) -or $name -eq '??')
	{
		$name = $device.DetectedName
	}

	if ([string]::IsNullOrWhiteSpace($name))
	{
		Warn-Log "The device name '$name' cannot be used because it is empty or only whitespace."
	}
	elseif ($name -match '[^\x20-\x7e]')
	{
		Warn-Log "The device name '$name' has invalid characters and cannot be used."
	}
	else
	{
		$name
	}
}

function Invoke-RouterControlPostback ($fields)
{
	$prior = Invoke-RouterControlPage

	$uri = 'http://www.routerlogin.net/' + $prior.Forms[0].Action
	Write-Log "POSTing to '$uri'."
	Write-Verbose 'POST fields:'
	Write-Verbose (($fields | Format-Table -Wrap | Out-String -Stream) -join "`n")

	$resp = Invoke-WebRequest `
			-Uri $uri `
			-WebSession $prior.Session `
			-Method POST `
			-Body $fields

	if ($resp.StatusCode -eq 200)
	{
		Write-Log 'POST status successful.'
	}
	else
	{
		Warn-Log "Non-success response status code '$($resp.StatusCode)' when posting back from router control page."
	}

	# no output (for now)
}

function Invoke-RouterControlAddPage
{
	$prior = Invoke-RouterControlPage

	$uri = 'http://www.routerlogin.net/DEV_control_add.htm'
	Write-Log "GETting from '$uri'."
	$resp = Invoke-WebRequest -Uri $uri -WebSession $prior.Session

	if ($resp.StatusCode -eq 200)
	{
		Write-Log 'GET status successful.'
	}
	else
	{
		Warn-Log "Non-success response status code '$($resp.StatusCode)' when getting router control add page."
	}

	# return just the form instead of whole response
	$resp.Forms[0]
}

function Invoke-RouterControlAddPostback ($form, $fields)
{
	$prior = Invoke-RouterControlPage

	$uri = 'http://www.routerlogin.net/' + $form.Action
	Write-Log "POSTing to '$uri'."
	Write-Verbose 'POST fields:'
	Write-Verbose (($fields | Format-Table -Wrap | Out-String -Stream) -join "`n")

	$resp = Invoke-WebRequest `
			-Uri $uri `
			-WebSession $prior.Session `
			-Method POST `
			-Body $fields

	if ($resp.StatusCode -eq 200)
	{
		Write-Log 'POST status successful.'
	}
	else
	{
		Warn-Log "Non-success response status code '$($resp.StatusCode)' when posting back from router control add page."
	}

	# no output (for now)
}


Export-ModuleMember -Function @(
		'Set-RouterCredential'
		'Test-RouterCredential'
		'Import-KnownDeviceCsv'
		'Get-Device'
		'Unblock-Device'
		'Block-Device'
		'Enable-AccessControl'
		'Disable-AccessControl'
		'Get-AccessControl'
		)
