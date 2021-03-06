@{

ModuleVersion = '1.04'
RootModule = '.\RouterControl.psm1'

Description = @'
Provides a command-line API for managing the device access control list of a NETGEAR Nighthawk router.
Works against the Nighthawk R7900P with firmware version V1.4.1.30_1.2.26.
'@

Author = 'Wayne King'
Copyright = '© 2019 Wayne King'

GUID = '14869107-9bd4-41dc-b27b-f90c6f0bada0'

PowerShellVersion = '5.0'

FormatsToProcess = @('.\RouterControl.Format.ps1xml')

FunctionsToExport = '*'
CmdletsToExport = @()
VariablesToExport = '*'
AliasesToExport = @()

PrivateData = @{
	PSData = @{

	}
}

}
