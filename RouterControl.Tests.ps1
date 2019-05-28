Get-Module RouterControl | Remove-Module -Force
Import-Module .\RouterControl.psm1
InModuleScope RouterControl `
{

# override module's DataPath to the test sandbox
$DataPath = 'TestDrive:'


describe 'Write-Log' {
	mock 'Write-Information' -MockWith { $Message -eq 'message' } -Verifiable
	Write-Log 'message'

	it 'calls Write-Information' {
		Assert-VerifiableMocks
	}
	it 'writes to log file' {
		Test-Path "$DataPath\$LogFilename" -Type Leaf | should be $true 
	}
}

describe 'Warn-Log' {
	mock 'Write-Warning' -MockWith { $Message -eq 'message' } -Verifiable
	Warn-Log 'message'

	it 'calls Write-Warning' {
		Assert-VerifiableMocks
	}
	it 'writes to log file' {
		Test-Path "$DataPath\$LogFilename" -Type Leaf | should be $true 
	}
	it 'writes "warning" text to log file' {
		Select-String -Path "$DataPath\$LogFilename" -Pattern 'WARNING' -CaseSensitive -SimpleMatch -Quiet |
				should be $true
	}
}

describe 'Test-RouterCredential' {
	it 'returns false when no cred' {
		Test-RouterCredential | should be $false
	}
	it 'returns true when cred file exists' {
		New-Item -Path "$DataPath\$CredFilename" -ItemType file
		Test-RouterCredential | should be $true
	}
}

describe 'Get-RouterCredential' {
	it 'throws when cred file does not exist' {
		{ Get-RouterCredential } | should throw
	}
	it 'returns the previously persisted credential' {
		'mock credential' | Export-Clixml "$DataPath\$CredFilename"
		Get-RouterCredential | should be 'mock credential'
	}
}

describe 'Set-RouterCredential' {
	mock 'Get-Credential' { 'mock credential' }
	Set-RouterCredential

	it 'prompts for a credential' {
		Assert-MockCalled 'Get-Credential'
	}
	it 'persists the cred to local disk' {
		Import-Clixml "$DataPath\$CredFilename" | should be 'mock credential'
	}
}

describe 'Import-KnownDeviceCsv' {
	[string] $testCsv = 'TestDrive:\knownDevices.csv'

	it 'generates error when non-existent file path' {
		{ Import-KnownDeviceCsv -Path 'TestDrive:\nonexistent.csv' } | should throw
	}

	it 'creates a cache file on disk' {
		@'
		Name,Mac
		Device 1,AA:BB:CC:DD:EE:FF
		"Device 2","FF:EE:DD:CC:BB:AA"
'@ 		| Set-Content -Path $testCsv

		Import-KnownDeviceCsv -Path $testCsv

		Test-Path -Path "$DataPath\$KnownDeviceCacheFilename" -PathType Leaf | should be $true
	}

	it 'ignores extra columns in the CSV' {
		@'
		Name,Extra,Mac
		Device 1,extra,AA:BB:CC:DD:EE:FF
		"Device 2","extra","FF:EE:DD:CC:BB:AA"
'@ 		| Set-Content -Path $testCsv

		Import-KnownDeviceCsv -Path $testCsv

		(Get-Content -Path "$DataPath\$KnownDeviceCacheFilename") -like '*extra*' | should be $null
	}

	it 'generates error if no meaningful records found in the CSV' {
		@'
		Name,Mac
		Malformed Mac,112233445566
		"","11:22:33:44:55:66"
'@ 		| Set-Content -Path $testCsv

		{	$ErrorActionPreference = 'Stop'
			Import-KnownDeviceCsv -Path $testCsv
		} | should throw
	}
}

describe 'Assert-KnownDevice' {
	it 'passes thru records with valid Name and MAC' {
		$rec = @{ Name = 'Valid Name'; Mac = 'AA:BB:CC:DD:EE:FF' }
		$rec | Assert-KnownDevice | should be $rec
	}
	it 'drops records with missing Name' {
		@{ Mac = 'AA:BB:CC:DD:EE:FF' } | Assert-KnownDevice | should be $null
	}
	it 'drops records with missing MAC' {
		@{ Name = 'Missing MAC' } | Assert-KnownDevice | should be $null
	}
	it 'drops records with malformed MAC' {
		@{ Name = 'Malformed MAC'; Mac = 'A:B:C:D:E:F' } | Assert-KnownDevice | should be $null
	}
}

describe 'Get-KnownDevice' {
	it 'logs warning when no previously imported devices exist' {
		mock 'Warn-Log' -Verifiable
		Get-KnownDevice
		Assert-VerifiableMocks
	}
	it 'returns devices previously imported by Import-KnownDeviceCsv' {
		@'
		Name,Mac
		Device 1,AA:BB:CC:DD:EE:FF
		"Device 2","FF:EE:DD:CC:BB:AA"
'@ 		| Set-Content -Path 'TestDrive:\knownDevices.csv'

		Import-KnownDeviceCsv -Path 'TestDrive:\knownDevices.csv'

		$devs = Get-KnownDevice
		$devs.Count | should be 2
		$devs[0].Name | should be 'Device 1'
		$devs[1].Mac | should be 'FF:EE:DD:CC:BB:AA'
	}
}

describe 'Restore-CachedObject' {
	it 'invokes the creator script when no cached object, and doesn''t invoke it subsequently' {
		mock 'Get-PSSession'
		Restore-CachedObject 'test1' { Get-PSSession }
		Assert-MockCalled 'Get-PSSession' -Times 1 -Exactly

		Restore-CachedObject 'test1' { Get-PSSession }
		Assert-MockCalled 'Get-PSSession' -Times 1 -Exactly
	}
	it 'caches the script output and returns it subsequently' {
		Restore-CachedObject 'test2' { 'initial' }
		Restore-CachedObject 'test2' { 'subsequent' } | should be 'initial'
	}
	it 'invokes the creator script after cached object expires' {
		Restore-CachedObject 'test3' { 'initial' }
		mock 'Get-Date' { [DateTime]::Now.AddMinutes($CacheForMinutes + 5) }		
		Restore-CachedObject 'test3' { 'subsequent' } | should be 'subsequent'
		Restore-CachedObject 'test3' { 'final' } | should be 'subsequent'
	}
}

describe 'Clear-CachedObject' {
	it 'clears a named cache' {
		Set-Variable -Name 'cachedTest' -Value 'value' -Scope Script
		Clear-CachedObject 'Test'
		Get-Variable -Name 'cachedTest' -ValueOnly -Scope Script | should be $null
	}
	it 'clears Get-Device''s chain of dependent caches' {
		Set-Variable -Name 'cachedGet-Device' -Value 'value' -Scope Script
		Set-Variable -Name 'cachedInvoke-RouterControlPage' -Value 'value' -Scope Script

		Clear-CachedObject 'Get-Device'

		Get-Variable -Name 'cachedGet-Device' -ValueOnly -Scope Script | should be $null
		Get-Variable -Name 'cachedInvoke-RouterControlPage' -ValueOnly -Scope Script | should be $null
	}
}

describe 'Invoke-RouterControlPage-Core' {
	mock 'Invoke-WebRequest'
	mock 'Get-RouterCredential' { [PSCredential]::Empty }
	Invoke-RouterControlPage-Core

	it 'invokes the correct page' {
		Assert-MockCalled 'Invoke-WebRequest' -ParameterFilter { $Uri -like '*/DEV_control.htm' }
	}
	it 'invokes with credentials' {
		Assert-MockCalled 'Get-RouterCredential'
		Assert-MockCalled 'Invoke-WebRequest' -ParameterFilter { $Credential -eq [PSCredential]::Empty }
	}
}

describe 'Invoke-RouterControlPage' {
	mock 'Invoke-RouterControlPage-Core' { 'response' }
	it 'returns the response' {
		Invoke-RouterControlPage | should be 'response'
	}
	it 'caches the response' {
		Invoke-RouterControlPage | should be 'response'
		Assert-MockCalled 'Invoke-RouterControlPage-Core' -Times 1 -Exactly
	}
}

describe 'Invoke-RouterControlPostback' {
	$session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
	mock 'Invoke-RouterControlPage' {
			'{ "Forms": [ { "Action": "action.cgi?a=b" } ] }' |
			ConvertFrom-Json |
			Add-Member -NotePropertyName 'Session' -NotePropertyValue $session -PassThru }

	context 'success response' {
		mock 'Invoke-WebRequest' { '{ "StatusCode": 200 }' | ConvertFrom-Json }
		
		$response = Invoke-RouterControlPostback 'fields'

		it 'invokes the correct page' {
			Assert-MockCalled 'Invoke-WebRequest' -ParameterFilter {
					$Uri -like '*/action.cgi?a=b' -and $Method -eq 'POST' }
		}
		it 'invokes with the passed fields' {
			Assert-MockCalled 'Invoke-WebRequest' -ParameterFilter { $Body -eq 'fields' }
		}
		it 'invokes with the prior session information' {
			Assert-MockCalled 'Invoke-WebRequest' -ParameterFilter { $WebSession -eq $session }
		}
		it 'returns nothing' {
			$response | should be $null
		}
	}
	context 'non-success response' {
		mock 'Invoke-WebRequest' { '{ "StatusCode": 400 }' | ConvertFrom-Json }
		mock 'Warn-Log' -Verifiable

		it 'logs a warning when response status is not successful' {
			Invoke-RouterControlPostback
			Assert-VerifiableMocks
		}
	}
}

describe 'Get-Device' {
	$dev1 = New-Object 'Device' -Property @{ DetectedName = 'Dev1'; MacAddress = 'AA:BB:CC:DD:EE:FF' }
	$dev2 = New-Object 'Device' -Property @{ DetectedName = 'Dev2'; MacAddress = '11:22:33:44:55:66' }

	mock 'Get-KnownDevice' { @(New-Object 'PSObject' -Property @{ Name = 'Known1'; Mac = 'AA:BB:CC:DD:EE:FF' })	}
	mock 'Get-DeviceFromRouter' { @($dev1, $dev2) }

	$devices = Get-Device

	it 'outputs the devices returned by Get-DeviceFromRouter' {
		$devices.Count | should be 2
		$devices[0] | should be $dev1
		$devices[1] | should be $dev2
	}
	it 'merges router devices with known devices' {
		$devices[0].Name | should be 'Known1'
		$devices[1].Name | should be '??'
	}
	it 'caches the devices' {
		$devices2 = Get-Device  # note this is second call

		Assert-MockCalled 'Get-DeviceFromRouter' -Times 1 -Exactly
		$devices2 | should be $devices
	}
	it 'ignores cache when Force is specified' {
		Get-Device -Force
		Assert-MockCalled 'Get-DeviceFromRouter' -Times 2 -Exactly
	}
}

describe 'Get-DeviceFromRouter' {
	it 'works' {
		# TODO: devise feasible way to unit test Get-DeviceFromRouter
		# either find way to compose a faked HtmlResponseObject (the return type of Invoke-RouterControlPage)
		# or find way to call Invoke-WebRequest in order to acquire a usable "test" response object
		$true
	}
}

describe 'ParseRuleProperties' {
	it 'basically works with a real example' {
		$ruleHtml = '<TD noWrap align=center><INPUT onclick=handle_checkboxElements(this); type=checkbox value="" name=checkbox></TD>
		<TD noWrap align=center name="show_status"><SPAN class=acl_blocked name="rule_status">Blocked</SPAN></TD>
		<TD noWrap align=center><SPAN name="rule_device_name">Unknown</SPAN></TD>
		<TD noWrap align=center><SPAN name="rule_ip">192.168.1.6</SPAN></TD>
		<TD noWrap align=center><SPAN name="rule_mac">77:88:AB:CD:EF:AA</SPAN><INPUT type=hidden value=block name=rule_status_org></TD>
		<TD noWrap align=center><SPAN name="rule_conn_type">Wireless(Foo)</SPAN></TD>'

		$propsVals = ParseRuleProperties $ruleHtml

		$propsVals.Count | should be 5
		$propsVals.status 		| should be 'Blocked'
		$propsVals.device_name 	| should be 'Unknown'
		$propsVals.ip 			| should be '192.168.1.6'
		$propsVals.mac 			| should be '77:88:AB:CD:EF:AA'
		$propsVals.conn_type 	| should be 'Wireless(Foo)'
	}
	it 'writes to log when unable to parse any properties' {
		mock 'Write-Log' -Verifiable
		ParseRuleProperties '<TD><SPAN>will not parse</SPAN></TD>'
		Assert-VerifiableMocks
	}

	# the expected behavior here is to work around a bug in the router's output
	#  where 'rule_device_name' may appear twice, as in the example $ruleHtml
	it 'ignores additional (duplicate) occurrences of properties of the same name' {
		$ruleHtml = '<TD noWrap align=center><INPUT onclick=handle_checkboxElements(this); type=checkbox value="" name=checkbox_black></TD>
		<TD noWrap align=center><SPAN name="rule_device_name">Device Name</SPAN></TD>
		<TD noWrap align=center><SPAN name="rule_mac_black">AA:BB:CC:DD:EE:FF</SPAN></TD>
		<TD noWrap align=center><SPAN name="rule_device_name">Wireless</SPAN></TD>'

		$propsVals = ParseRuleProperties $ruleHtml

		$propsVals.Count | should be 2
		$propsVals.device_name | should be 'Device Name'
		$propsVals.mac_black | should be 'AA:BB:CC:DD:EE:FF'
	}

	it 'handles multiple rules piped in' {
		$setsOfPropsVals= @(
			   '<TD><SPAN name="rule_device_name">Device 1</SPAN></TD>',
			   '<TD><SPAN name="rule_device_name">Device 2</SPAN></TD>') |
			   ParseRuleProperties

		$setsOfPropsVals.Count | should be 2
		$setsOfPropsVals[0].device_name | should be 'Device 1'
		$setsOfPropsVals[1].device_name | should be 'Device 2'
   }
}

describe 'TextEllipsis' {
	it 'truncates a too-long string with an ellipsis' {
		TextEllipsis '123456789abcdef' 9 | should be '123456789...'
	}
	it 'returns original when it is not too long' {
		TextEllipsis '123456789abcdef' 16 | should be '123456789abcdef'
	}
}

describe 'New-Device' {
	it 'handles regular rule records' {
		$device = @{ ip = '192.168.1.1'; status = 'Blocked'; conn_type = 'Wireless(Foo)';
		device_name = 'Device Name'; mac = 'AA:BB:CC:DD:EE:FF' } | New-Device
		
		$device.GetType().Name 	| should be 'Device'
		$device.Name 			| should be $null
		$device.DetectedName 	| should be 'Device Name'
		$device.MacAddress 		| should be 'AA:BB:CC:DD:EE:FF'
		$device.AccessControl 	| should be 'Blocked'
		$device.Connection		| should be 'Undetected'
	}
	it 'handles white-list rule records' {
		$device = @{ device_name = 'White Device'; mac_white = 'FF:EE:DD:CC:BB:AA' } | New-Device
		
		$device.Name 			| should be $null
		$device.DetectedName 	| should be 'White Device'
		$device.MacAddress 		| should be 'FF:EE:DD:CC:BB:AA'
		$device.AccessControl 	| should be 'Allowed'
	}
	it 'handles black-list rule records' {
		$device = @{ device_name = 'Black Device'; mac_black = 'FF:FF:FF:AA:AA:AA' } | New-Device
		
		$device.Name 			| should be $null
		$device.DetectedName 	| should be 'Black Device'
		$device.MacAddress 		| should be 'FF:FF:FF:AA:AA:AA'
		$device.AccessControl 	| should be 'Blocked'
	}
	it 'handles multiple objects piped in' {
		$devices = @( @{ device_name = 'First' }, @{ device_name = 'Second' } ) | New-Device

		$devices.Count | should be 2
	}
	it 'accepts ''connection'' parameter' {
		@{ device_name = 'Device' } | New-Device -connection 'Online' | select -expand Connection | should be 'Online'
		@{ device_name = 'Device' } | New-Device -connection 'Offline' | select -expand Connection | should be 'Offline'
	}
}

describe 'Merge-Device' {
	$knownDevices = @(
		(New-Object 'PSObject' -Property @{ Name = 'Known 1'; Mac = 'AA:BB:CC:DD:EE:FF' }),
		(New-Object 'PSObject' -Property @{ Name = 'Known 2'; Mac = '11:22:33:44:55:66' }))

	$dev1 = New-Object 'Device' -Property @{ DetectedName = 'Fixed'; MacAddress = 'AA:BB:CC:DD:EE:FF' }
	$dev2 = New-Object 'Device' -Property @{ DetectedName = 'Fixed'; MacAddress = '11:22:33:44:55:66' }
	$dev3 = New-Object 'Device' -Property @{ DetectedName = 'Fixed'; MacAddress = 'FF:EE:DD:CC:BB:AA' }

	it 'sets input object''s Name from matching known device' {
		$dev1 | Merge-Device $knownDevices | should be $dev1

		$dev1.Name | should be 'Known 1'
		$dev1.DetectedName | should be 'Fixed'
	}
	it 'sets input object''s name to ?? when no matching known device' {
		$dev3 | Merge-Device $knownDevices | should be $dev3

		$dev3.Name | should be '??'
		$dev3.DetectedName | should be 'Fixed'
	}
	it 'sets input object''s name to ?? when knownDevices parameter is null or omitted' {
		$dev2 | Merge-Device
		$dev3 | Merge-Device $null

		$dev2.Name | should be '??'
		$dev3.Name | should be '??'
	}
	it 'handles multiple devices piped in' {
		$dev1, $dev2 | Merge-Device $knownDevices

		$dev1.Name | should be 'Known 1'
		$dev2.Name | should be 'Known 2'
	}
}

describe 'ComposeRuleSettingsPostbackValue' {
	$mac1 = 'AA:BB:CC:DD:EE:FF'
	$mac2 = '11:22:33:44:55:66'
	$mac3 = 'FF:EE:DD:CC:BB:AA'
	$mac4 = '66:55:44:33:22:11'

	mock 'Get-Device' { @(
			[Device] @{ Name = 'Dev1'; MacAddress = $mac1; AccessControl = 'Allowed'; Connection = 'Online' },
			[Device] @{ Name = 'Dev2'; MacAddress = $mac2; AccessControl = 'Blocked'; Connection = 'Online' },
			[Device] @{ Name = 'Dev3'; MacAddress = $mac3; AccessControl = 'Blocked'; Connection = 'Online' },
			[Device] @{ Name = 'Dev4'; MacAddress = $mac4; AccessControl = 'Allowed'; Connection = 'Offline'} ) }

	it 'basically works to Allow target device' {
		$targetDevice = New-Object 'Device' -Property @{ MacAddress = $mac2 }
		$field = ComposeRuleSettingsPostbackValue $targetDevice 'Allowed'

		$field.Count | should be 1
		$field | should be "3:${mac1}:1:${mac2}:1:${mac3}:0:"
	}
	it 'basically works to Block target device ' {
		$targetDevice = New-Object 'Device' -Property @{ MacAddress = $mac1 }
		$field = ComposeRuleSettingsPostbackValue $targetDevice 'Blocked'

		$field.Count | should be 1
		$field | should be "3:${mac1}:0:${mac2}:0:${mac3}:0:"
	}
}

describe 'Unblock-Device and Block-Device' {
	$allowedDevice = New-Object 'Device' -Property @{
			Name = 'Allowed'; MacAddress = 'AA:BB:CC:DD:EE:FF'; AccessControl = 'Allowed' }
	$blockedDevice = New-Object 'Device' -Property @{
			Name = 'Blocked'; MacAddress = '11:22:33:44:55:66'; AccessControl = 'Blocked' }
	$unknownDevice = New-Object 'Device' -Property @{
			Name = 'Unknown'; MacAddress = 'AA:AA:AA:BB:BB:BB' }

	mock 'Get-Device' { @( $allowedDevice, $blockedDevice ) }
	mock 'GetPostFieldsForDeviceUpdate'
	mock 'Invoke-RouterControlPostback'

	context 'Unblock-Device' {
		it 'logs a warning when the device is not recognized' {
			mock 'Warn-Log' -Verifiable

			Unblock-Device $unknownDevice | should be $null
			Assert-VerifiableMocks
		}
		it 'logs a message when the device is already allowed' {
			mock 'Write-Log' -Verifiable

			Unblock-Device $allowedDevice | should be $null
			Assert-VerifiableMocks
		}
		it 'calls Update-ConnectedDevice' {
			mock 'Update-ConnectedDevice' -ParameterFilter { $access -eq 'Allowed' } -Verifiable

			Unblock-Device $blockedDevice
			Assert-VerifiableMocks
		}
	}
	context 'Block-Device' {
		it 'logs a warning when the device is not recognized' {
			mock 'Warn-Log' -Verifiable
			
			Block-Device $unknownDevice | should be $null
			Assert-VerifiableMocks
		}
		it 'logs a message when the device is already blocked' {
			mock 'Write-Log' -Verifiable
			
			Block-Device $blockedDevice | should be $null
			Assert-VerifiableMocks
		}
		it 'calls Update-ConnectedDevice' {
			mock 'Update-ConnectedDevice' -ParameterFilter { $access -eq 'Blocked' } -Verifiable

			Block-Device $allowedDevice
			Assert-VerifiableMocks
		}
	}

	context 'Block-Device pipeline input' {
		it 'accepts pipeline input' {
			mock 'Get-Device' -Verifiable
			mock 'Warn-Log'

			$unknownDevice | Block-Device
			Assert-VerifiableMocks
		}
	}
	context 'Block-Device pipeline error' {
		it 'writes error and no-ops when more than one device is piped' {
			mock 'Write-Error'
			mock 'Get-Device'

			@($allowedDevice, $blockedDevice) | Block-Device

			Assert-MockCalled 'Write-Error' -ParameterFilter { $Exception -is [NotSupportedException] }
			Assert-MockCalled 'Get-Device' -Times 0 -Exactly
		}
	}

	context 'Unblock-Device pipeline input' {
		it 'accepts pipeline input' {
			mock 'Get-Device' -Verifiable
			mock 'Warn-Log'

			$unknownDevice | Unblock-Device
			Assert-VerifiableMocks
		}
	}
	context 'Unblock-Device pipeline error' {
		it 'writes error and no-ops when more than one device is piped' {
			mock 'Write-Error'
			mock 'Get-Device'

			@($blockedDevice, $allowedDevice) | Unblock-Device

			Assert-MockCalled 'Write-Error' -ParameterFilter { $Exception -is [NotSupportedException] }
			Assert-MockCalled 'Get-Device' -Times 0 -Exactly
		}
	}
}

describe 'Update-ConnectedDevice' {
	$onlineDevice = New-Object 'Device' -Property @{ Connection = 'Online'; MacAddress = 'AA:BB:CC:DD:EE:FF' }
	$offlineDevice = New-Object 'Device' -Property @{ Connection = 'Offline' }

	mock 'Get-Device'

	it 'calls Update-OnlineDevice when the device is online' {
		mock 'Update-OnlineDevice' -Verifiable
		Update-ConnectedDevice $onlineDevice 'Unknown'
		Assert-VerifiableMocks
	}
	it 'calls Update-OfflineDevice when the device is offline' {
		mock 'Update-OfflineDevice' -Verifiable
		Update-ConnectedDevice $offlineDevice 'Unknown'
		Assert-VerifiableMocks
	}
	context 'output' {
		mock 'Update-OnlineDevice'
		mock 'Get-Device' { @{ MacAddress = 'AA:BB:CC:DD:EE:FF' } } -ParameterFilter { $Force } -Verifiable

		$result = Update-ConnectedDevice $onlineDevice 'Blocked'

		it 'calls Get-Device with -Force' {
			Assert-VerifiableMocks
		}
		it 'outputs a copy of input device with the new status' {
			$result | should not be $null
		}
	}
}

describe 'Update-OnlineDevice' {
	it 'acquires post fields & POSTs' {
		$fakeDevice = New-Object 'Device'

		mock 'GetPostFieldsForDeviceUpdate' { 'fields' } -ParameterFilter {
				$device -eq $fakeDevice -and $access -eq 'Blocked' } -Verifiable
		mock 'GetPostFieldsForDeviceUpdate' { 'fields' } -ParameterFilter {
				$device -eq $fakeDevice -and $access -eq 'Allowed' } -Verifiable

		mock 'Invoke-RouterControlPostback' -ParameterFilter {
				$fields -eq 'fields' } -Verifiable

		Update-OnlineDevice $fakeDevice 'Blocked'
		Update-OnlineDevice $fakeDevice 'Allowed'
		Assert-VerifiableMocks
	}
}

describe 'Update-OfflineDevice' {
	$fakeDevice = New-Object 'Device'
	$script:callSequence = ''
	mock 'Remove-Device' { $script:callSequence += 'Remove;' } -ParameterFilter {
			$device -eq $fakeDevice } -Verifiable
	mock 'Add-Device' { $script:callSequence += 'Add;' } -ParameterFilter {
			$device -eq $fakeDevice -and $access -eq 'Blocked' } -Verifiable
	mock 'Add-Device' { $script:callSequence += 'Add;' } -ParameterFilter {
			$device -eq $fakeDevice -and $access -eq 'Allowed' } -Verifiable
	
	Update-OfflineDevice $fakeDevice 'Blocked'
	Update-OfflineDevice $fakeDevice 'Allowed'
	
	it 'calls Remove-Device and Add-Device with correct parameters' {
		Assert-VerifiableMocks
	}
	it 'calls Remove-Device, then Add-Device' {
		$callSequence | should be 'Remove;Add;Remove;Add;'
	}
}

describe 'Remove-Device' {
	$onlineDevice = [Device] @{ Connection = 'Online' }
	$offlineDevice = [Device] @{ Connection = 'Offline' }

	it 'logs a warning when the device is not Offline' {
		mock 'Warn-Log' -Verifiable

		Remove-Device $onlineDevice
		Assert-VerifiableMocks
	}
	it 'acquires post fields & POSTs' {
		mock 'GetPostFieldsForDeviceRemove' { 'fields' } -ParameterFilter { $Device -eq $offlineDevice } -Verifiable
		mock 'Invoke-RouterControlPostback' -ParameterFilter { $fields -eq 'fields' } -Verifiable

		Remove-Device $offlineDevice
		Assert-VerifiableMocks
	}
}

describe 'Enable-AccessControl' {
	it 'acquires post fields & POSTs when device access is not specified' {
		mock 'GetPostFieldsForAccessControlEnable' { 'fieldsNoDevice' }
		mock 'Invoke-RouterControlPostback' -ParameterFilter {
				$fields -eq 'fieldsNoDevice' } -Verifiable

		Enable-AccessControl
		Assert-VerifiableMocks
	}
	it 'acquires post fields & POSTs when device access is specified' {
		mock 'GetPostFieldsForAccessControlEnable' { 'fieldsBlocked' } -ParameterFilter {
				$NewDeviceAccess -eq 'Blocked' } -Verifiable
		mock 'Invoke-RouterControlPostback' -ParameterFilter {
				$fields -eq 'fieldsBlocked' } -Verifiable

		Enable-AccessControl 'Blocked'
		Assert-VerifiableMocks
	}
	it 'clears the cached html page {after effecting the change}' {
		# don't know simple way to verify when clear-cache is called

		mock 'GetPostFieldsForAccessControlEnable'
		mock 'Invoke-RouterControlPostback'

		mock 'Clear-CachedObject' -ParameterFilter {
				$name -eq 'Invoke-RouterControlPage' } -Verifiable

		Enable-AccessControl
		Assert-VerifiableMocks
	}
}

describe 'Disable-AccessControl' {
	it 'acquires post fields and POSTs' {
		mock 'GetPostFieldsForAccessControlDisable' { 'fields' }
		mock 'Invoke-RouterControlPostback' -ParameterFilter {
				$fields -eq 'fields' } -Verifiable

		Disable-AccessControl
		Assert-VerifiableMocks
	}
	it 'clears the cached html page {after effecting the change}' {
		# don't know simple way to verify when clear-cache is called

		mock 'GetPostFieldsForAccessControlDisable'
		mock 'Invoke-RouterControlPostback'

		mock 'Clear-CachedObject' -ParameterFilter {
				$name -eq 'Invoke-RouterControlPage' } -Verifiable

		Disable-AccessControl
		Assert-VerifiableMocks
	}
}

#.SYNOPSIS
# Compose a fake that looks like an HTML response object with a Form and its fields.
function ComposeFormFieldsFake ([hashtable] $fields)
{
	$fake = '{ "Forms" : [ { "Fields" : "stub" } ] }' | ConvertFrom-Json
	$fake.Forms[0].Fields = $fields

	$fake	
}

describe 'Get-AccessControl' {
	$fields = @{
		enable_access_control = ''
		access_all_settings = '' }

	mock 'Invoke-RouterControlPage' { ComposeFormFieldsFake $fields }

	it 'outputs Disabled|NotApplicable when disabled' {
		$fields['enable_access_control'] = '0'

		$result = Get-AccessControl

		$result.AccessControl | should be 'Disabled'
		$result.NewDeviceAccess | should be 'NotApplicable'
	}
	it 'outputs Enabled|Blocked' {
		$fields['enable_access_control'] = '1'
		$fields['access_all_setting'] = '0'

		$result = Get-AccessControl

		$result.AccessControl | should be 'Enabled'
		$result.NewDeviceAccess | should be 'Blocked'
	}
	it 'outputs Enabled|Allowed' {
		$fields['enable_access_control'] = '1'
		$fields['access_all_setting'] = '1'

		$result = Get-AccessControl

		$result.AccessControl | should be 'Enabled'
		$result.NewDeviceAccess | should be 'Allowed'
	}
	it 'outputs ''??'' when fields are wrong/unrecognized (test 1/2)' {
		$fields.Remove('enable_access_control')

		$result = Get-AccessControl

		$result.AccessControl | should be '??'
		$result.NewDeviceAccess | should be 'NotApplicable'
	}
	it 'outputs ''??'' when fields are wrong/unrecognized (test 2/2)' {
		$fields['enable_access_control'] = '1'
		$fields.Remove('access_all_setting')

		$result = Get-AccessControl

		$result.AccessControl | should be 'Enabled'
		$result.NewDeviceAccess | should be '??'
	}
}

describe 'Add-Device' {
	$fakeDevice = New-Object 'Device'

	mock 'Invoke-RouterControlAddPage' { 'form' } -Verifiable
	mock 'GetPostFieldsForDeviceAdd' { 'fields' } -ParameterFilter {
			$device -eq $fakeDevice -and $access -eq 'Blocked' } -Verifiable
	mock 'GetPostFieldsForDeviceAdd' { 'fields' } -ParameterFilter {
			$device -eq $fakeDevice -and $access -eq 'Allowed' } -Verifiable
	mock 'Invoke-RouterControlAddPostback' -ParameterFilter {
			$fields -eq 'fields' } -Verifiable

	it 'acquires the add-device page form, post fields, and POSTs' {
		Add-Device $fakeDevice 'Blocked'
		Add-Device $fakeDevice 'Allowed'
		Assert-VerifiableMocks
	}
}

describe 'GetPostFieldsForAccessControl Enable/Disable' {
	$fields = @{
			enable_acl = 'original'
			enable_access_control = 'original'
			access_all = 'original' }

	mock 'Invoke-RouterControlPage' { ComposeFormFieldsFake $fields }

	$whenEnable      = GetPostFieldsForAccessControlEnable
	$whenEnableAllow = GetPostFieldsForAccessControlEnable 'Allowed'
	$whenEnableBlock = GetPostFieldsForAccessControlEnable 'Blocked'
	$whenDisable     = GetPostFieldsForAccessControlDisable

	it 'does not modify the router control page''s form fields' {
		$fields.Count | should be 3
		'enable_acl', 'enable_access_control', 'access_all' |
				foreach { $fields[$_] | should be 'original' }
	}
	it 'sets correct fields when Enable' {
		foreach ($resultFields in $whenEnable, $whenEnableAllow, $whenEnableBlock)
		{
			$resultFields['enable_acl'] | should be 'enable_acl'
			$resultFields['enable_access_control'] | should be 'original'
		}
	}
	it 'sets correct fields when Enable with no device access specified' {
		$whenEnable['access_all'] | should be 'original'
	}
	it 'sets correct fields when Enable with new devices allowed' {
		$whenEnableAllow['access_all'] | should be 'allow_all'
	}
	it 'sets correct fields when Enable with new devices blocked' {
		$whenEnableBlock['access_all'] | should be 'block_all'
	}
	it 'sets correct fields when Disable' {
		$whenDisable['enable_acl'] | should be $null
		$whenDisable['enable_access_control'] | should be 'original'
	}
}

describe 'GetPostFieldsForDeviceUpdate' {
	context 'short circuit' {
		it 'short-circuits and returns nothing when the RuleSettings field cannot be composed' {
			mock 'ComposeRuleSettingsPostbackValue' { }
			mock 'Invoke-RouterControlPage'

			GetPostFieldsForDeviceUpdate $null 0 | should be $null

			Assert-MockCalled 'Invoke-RouterControlPage' -Times 0 -Exactly
		}
	}
	context 'basic functionality' {
		$fields = @{ rule_settings = 'original'; rule_status_org = 'original' }

		mock 'Invoke-RouterControlPage' { ComposeFormFieldsFake $fields }
		mock 'ComposeRuleSettingsPostbackValue' { 'settings' }

		$returned = GetPostFieldsForDeviceUpdate $null 'Allowed'

		it 'does not modify the cached router control page''s form fields' {
			$fields['rule_settings'] | should be 'original'
			$fields['rule_status_org'] | should be 'original'
			$fields['allow'] | should be $null
			$fields['block'] | should be $null
		}
		it 'returns correct post fields to the postback when Allowed' {
			$returned | should not be $null
			$returned.ContainsKey('rule_status_org') | should be $false
			$returned['rule_settings'] | should be 'settings'
			$returned['allow'] | should be 'allow'
		}
		it 'returns correct post fields to the postback when Blocked' {
			(GetPostFieldsForDeviceUpdate $null 'Blocked')['block'] | should be 'block'
		}
	}
}

describe 'GetPostFieldsForDeviceRemove' {
	$fields = @{
			delete_white_lists = 'original'
			delete_black_lists = 'original' }

	mock 'Invoke-RouterControlPage' { ComposeFormFieldsFake $fields } -Verifiable
			
	$device = [Device] @{ MacAddress = 'AA:BB:CC:DD:EE:FF' }
	$device.AccessControl = 'Allowed'
	$allowedReturn = GetPostFieldsForDeviceRemove $device

	$device.AccessControl = 'Blocked'
	$blockedReturn = GetPostFieldsForDeviceRemove $device

	it 'does not modify the cached router control page''s form fields' {
		Assert-VerifiableMocks
		$fields['delete_white_lists'] | should be 'original'
		$fields['delete_black_lists'] | should be 'original'
		$fields['delete_white'] | should be $null
		$fields['delete_black'] | should be $null
	}
	it 'composes correct post fields when device in Allowed list' {
		$allowedReturn['delete_white_lists'] | should be '1:AA:BB:CC:DD:EE:FF:'
		$allowedReturn['delete_white'] | should beExactly 'Delete'

		$allowedReturn['delete_black_lists'] | should be 'original'
		$allowedReturn['delete_black'] | should be $null
	}
	it 'composes correct post field when device in Blocked list' {
		$blockedReturn['delete_black_lists'] | should be '1:AA:BB:CC:DD:EE:FF:'
		$blockedReturn['delete_black'] | should beExactly 'Delete'

		$blockedReturn['delete_white_lists'] | should be 'original'
		$blockedReturn['delete_white'] | should be $null
	}
}

describe 'GetPostFieldsForDeviceAdd' {
	$fakeDevice = New-Object 'Device'
	$fakeForm = [PSObject] @{ Fields = @{} }

	context 'short circuit' {
		it 'short-circuits and returns nothing when bad MAC' {
			mock 'Get-CleanedMac' { }
			mock 'Get-CleanedName' { 'name' }

			GetPostFieldsForDeviceAdd $null $fakeForm | should be $null
		}
		it 'short-circuits and returns nothing when bad name' {
			mock 'Get-CleanedMac' { 'AABBCCDDEEFF' }
			mock 'Get-CleanedName' { }

			GetPostFieldsForDeviceAdd $null $fakeForm | should be $null
		}
	}
	context 'basic functionality' {
		mock 'Get-CleanedMac' { 'AABBCCDDEEFF' } -ParameterFilter { $device -eq $fakeDevice }
		mock 'Get-CleanedName' { 'Name' } -ParameterFilter { $device -eq $fakeDevice }

		$fakeDevice.AccessControl = 'Allowed'
		$returned = GetPostFieldsForDeviceAdd $fakeDevice $fakeForm

		it 'does not directly modify the form''s fields' {
			$fakeForm.Fields.Count | should be 0
		}
		it 'returns correct post fields when Allowed' {
			$returned | should not be $null
			$returned['mac_addr'] | should be 'AABBCCDDEEFF'
			$returned['dev_name'] | should be 'Name'
			$returned['action'] | should be 'Apply'
			$returned['access_control_add_type'] | should be 'allowed_list'
		}
		it 'returns correct post fields when Blocked' {
			$fakeDevice.AccessControl = 'Blocked'
			$returned = GetPostFieldsForDeviceAdd $fakeDevice $fakeForm
			$returned['access_control_add_type'] | should be 'blocked_list'
		}
	}
}

describe 'Get-CleanedMac' {
	$device = New-Object 'Device'
	$script:warnLogCount = 0

	mock 'Warn-Log' { Write-Debug "warn msg: $message"}

	it 'warns when MAC is <descrip>' -TestCases @(
			@{ descrip = 'too short'; 		mac = 'AA:BB:CC:DD:EE' },
			@{ descrip = 'too long'; 		mac = 'AA:BB:CC:DD:EE:FF:11' },
			@{ descrip = 'invalid digit'; 	mac = 'AA:BB:CC:DD:EE:FG' },
			@{ descrip = 'invalid delim'; 	mac = 'AA.BB.CC.DD.EE.FG' },
			@{ descrip = 'only F and 0'; 	mac = 'FF:FF:FF:00:00:00' },
			@{ descrip = 'multicast'; 		mac = '01:BB:CC:DD:EE:FF' }
			) -test {
		param ($descrip, $mac)

		$device.MacAddress = $mac
		Get-CleanedMac $device | should be $null

		$script:warnLogCount++
		Assert-MockCalled 'Warn-Log' -Times $warnLogCount -Exactly
	}
	it "removes ':' and '-' delimiters" {
		$device.MacAddress = 'AA:BB:CC:DD-EE-FF'
		Get-CleanedMac $device | should be 'AABBCCDDEEFF'
	}
	it 'converts digits to upper case' {
		$device.MacAddress = 'aa:bb:cc:dd:ee:ff'
		Get-CleanedMac $device | should be 'AABBCCDDEEFF'
	}
}

describe 'IsMulticastMac' {
	it 'returns <expect> when <mac>' -TestCases @(
			@{ mac = '01:22:33:44:55:66'; expect = $true },
			@{ mac = '10:22:33:44:55:66'; expect = $false },
			@{ mac = '33:11:22:33:44:55'; expect = $true },
			@{ mac = '0A:BB:CC:DD:EE:FF'; expect = $false },
			@{ mac = '0B:11:22:33:44:55'; expect = $true }
			) -test {
		param ($mac, $expect)
		IsMulticastMac $mac | should be $expect
	}
}

describe 'Get-CleanedName' {
	$device = New-Object 'Device'
	$script:warnLogCount = 0

	mock 'Warn-Log' { Write-Debug "warn msg: $message"}

	it 'warns when name is <descrip>' -TestCases @(
			@{ descrip = 'null'; name = $null },
			@{ descrip = 'empty'; name = '' },
			@{ descrip = 'whitespace'; name = ' ' },
			@{ descrip = 'invalid char'; name = 'Section § symbol' }
			) -test {
		param ($descrip, $name)

		$device.Name = $name
		$device.DetectedName = $name
		Get-CleanedName $device | should be $null

		$script:warnLogCount++
		Assert-MockCalled 'Warn-Log' -Times $warnLogCount -Exactly
	}
	it 'prefers Name over DetectedName' {
		$device.Name = 'Name Value'
		$device.DetectedName = 'Detected Name Value'
		Get-CleanedName $device | should be 'Name Value'
	}
	it 'uses DetectedName when no Name' {
		$device.Name = ''
		$device.Name = 'Detected Name Value'
		Get-CleanedName $device | should be 'Detected Name Value'
	}
	it "uses DetectedName when Name is '??'" {
		$device.Name = '??'
		$device.Name = 'Detected Name Value'
		Get-CleanedName $device | should be 'Detected Name Value'
	}
}

}
