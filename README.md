# RouterControl PowerShell Module

Provides a command-line API for managing the device access control list of a NETGEAR Nighthawk router.

Initially developed to work upon the Nighthawk R7900P with firmware version V1.4.1.30_1.2.26.


## Basic Usage

1. import the module

		Import-Module .\RouterControl.psd1

2. see what commands are exposed by the module

		Get-Command -Module RouterControl

3. set the login credential for accessing your router

		Set-RouterCredential

	Supply the name & password, as appropriate.

4. see the devices known by the router

		Get-Device | Format-Table

	The *DetectedName* field is the name detected or assigned by the router.

	The *Name* column is a name that you can provide to this module, which allows for more meaningful names than the router is sometimes able to acquire. Use the **Import-KnownDeviceCsv** command to supply your names. (See 'Get-Help Import-KnownDeviceCsv' for details.)

5. block a device that is currently allowed

	For example, choose the first allowed device and block it:

		$device = Get-Device | ? AccessControl -eq 'Allowed' | select -First 1

		$device | Block-Device

6. unblock a device that is currently blocked

	For example, choose the first blocked device and unblock it:

		$device = Get-Device | ? AccessControl -eq 'Blocked' | select -First 1

		$device | Unblock-Device

7. requery the router for devices

	The module caches the device list for 5 minutes, so use the -Force parameter to refresh the list on-demand.

		Get-Device -Force | ft


## Notes

Currently, only devices that are already known or detected by the router can be managed by this module. Use **Get-Device** to acquire the device to manage, then pass it to the **Block-Device** or **Unblock-Device** command.