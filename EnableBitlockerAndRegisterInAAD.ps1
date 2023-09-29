<#	
	===========================================================================
     Created on:   	05/14/2021
     Updated on:    08/18/2021
	 Created by:   	Danny Sloderbeck
	 Organization: 	WestRock
	 Filename:     	EnableBitlockerAndRegisterInAAD.ps1
	===========================================================================
	.DESCRIPTION
    Enable BitLocker encryption on laptop devices, and upload BitLocker recovery key to Azure AD.
    Script is designed to run from scheduled task created during Autopilot enrollment.
    
    Original script is located here:
    https://www.lieben.nu/liebensraum/2017/06/automatically-bitlocker-windows-10-mdm-intune-azure-ad-joined-devices/

    Chassis types from WMI to detect laptop chassis type: 
    https://docs.microsoft.com/en-us/windows/win32/cimwin32prov/win32-systemenclosure

    .NOTES
    Change the path of "$RegistryRootPath" to your own custom path (used for application detection and storing BitLocker Recovery Key ID)

#>

## Set the current working directory to ensure when calling files from the current directory that the full path is used.
$WorkingDirectory = $MyInvocation.MyCommand.Path | Split-Path -Parent

# Define the company registry root key
$RegistryRootPath = "HKLM:\SOFTWARE\<MyCompanyName>\EnableBitlockerAndRegisterInAAD"

# Do not attempt to upload to BitLocker key to Azure AD, unless drive is fully encrypted
$postKeyToAAD = $False

# Set folder for log file
$now = Get-Date -Format "yyyy-MM-dd"
$RunningScriptName = "EnableBitlockerAndRegisterInAAD"
$LogFolder = "C:\Windows\Logs"
[String]$LogfileName = "$RunningScriptName"
[String]$Logfile = "$LogFolder\$LogfileName.log"

if (!(Test-Path "$LogFolder")) {
    New-Item -Path "$LogFolder" -ItemType Directory -Force
}

Function Write-Log {
    Param ([string]$logstring)
    If (Test-Path $Logfile) {
        If ((Get-Item $Logfile).Length -gt 2MB) {
            Rename-Item $Logfile $Logfile".bak" -Force
        }
    }
    $WriteLine = (Get-Date).ToString() + " " + $logstring
    Add-Content $Logfile -Value $WriteLine
    Write-Host $WriteLine
}

function Set-RegistryValue {
    param(
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,
    
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,        
    
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Value
    )
    try {
        $RegistryValue = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($RegistryValue -ne $null) {
            Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force -ErrorAction Stop
        }
        else {
            New-ItemProperty -Path $Path -Name $Name -PropertyType String -Value $Value -Force -ErrorAction Stop | Out-Null
        }
    }
    catch [System.Exception] {
        Write-Log "Failed to create or update registry value '$($Name)' in '$($Path)'. Error message: $($_.Exception.Message)"
    }
}

# Write device information to log file
$OSCaption = (Get-WmiObject Win32_OperatingSystem).Caption
$MachineInfo = Get-WmiObject Win32_ComputerSystemProduct
$Manufacturer = ($MachineInfo).Vendor
if ($Manufacturer -match "Lenovo*") {
    $Model = ($MachineInfo).Version
}
else {
    $Model = ($MachineInfo).Name
}
Write-Log "Machine name: $env:COMPUTERNAME"
Write-Log "Operating System installed: $OSCaption"
if ($OSCaption -match "Windows 10") {

    $Win10Version = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name ReleaseID -ErrorAction SilentlyContinue).ReleaseID
    Write-Log "Device is running Windows 10 $Win10Version"
}
Write-Log "Manufacturer: $Manufacturer"
Write-Log "Model: $Model"

# Detect if device is laptop
$isLaptop = "false"

#The chassis is the physical container that houses the components of a computer.
$ChassisType = Get-WmiObject -Class win32_systemenclosure | Select-Object -ExpandProperty chassistypes
Write-Log "Chassis Type detected: $ChassisType"

# Defined laptop chassis types (based on Microsoft documentation)
if ($ChassisType -eq 8 -or $ChassisType -eq 9 -or $ChassisType -eq 10 -or $ChassisType -eq 11 -or $ChassisType -eq 14 -or $ChassisType -eq 30 -or $ChassisType -eq 31 -or $ChassisType -eq 32) {

    $isLaptop = "true"
}

#Shows battery status , if true (and machine is not virtual), then the machine is a laptop.
$BatteryDetected = Get-WmiObject -Class win32_battery -ErrorAction SilentlyContinue

if (($BatteryDetected -ne $null) -and ($Model -notmatch "Virtual")) { 

    $isLaptop = "true"
}

# Laptop detected. Enforcing BitLocker encryption
If ($isLaptop -eq "true") { 

    Write-Log "Laptop chassis type detected. Detecting if BitLocker encryption is required."

    try {
        $BitLockerStatus = Get-BitLockerVolume $env:SystemDrive -ErrorAction Stop | Select-Object -Property VolumeStatus
    }
    catch {
        Write-Log "Failed to retrieve BitLocker status of system drive $_"
        $postKeyToAAD = $False
        Throw "Failed to retrieve BitLocker Status of System Drive"
    }

    if ($BitLockerStatus.VolumeStatus -eq "FullyDecrypted") {
        Write-Log "$($env:SystemDrive) system volume not yet encrypted, ejecting media and attempting to encrypt"
        <#
        try {
            # Automatically unmount any iso/dvd's
            $Diskmaster = New-Object -ComObject IMAPI2.MsftDiscMaster2 
            $DiskRecorder = New-Object -ComObject IMAPI2.MsftDiscRecorder2 
            $DiskRecorder.InitializeDiscRecorder($DiskMaster) 
            $DiskRecorder.EjectMedia() 
        }
        catch {
            Write-Log "Failed to unmount DVD $_"
        }
        #>

        try {
            # Automatically unmount any USB sticks
            $volumes = Get-WmiObject -Class Win32_Volume | Where-Object { $_.drivetype -eq '2' }  
            foreach ($volume in $volumes) {
                $ejectCmd = New-Object -ComObject Shell.Application
                $ejectCmd.NameSpace(17).ParseName($volume.driveletter).InvokeVerb("Eject")
            }
        }
        catch {
            Write-Log "Failed to unmount USB device $_"
        }

        try {
            # Check if TPM chip is currently owned, if not take ownership
            $TPMClass = Get-WmiObject -Namespace "root\cimv2\Security\MicrosoftTPM" -Class "Win32_TPM"
            $IsTPMOwned = $TPMClass.IsOwned().IsOwned
            if ($IsTPMOwned -eq $false) {
                Write-Log "TPM chip is currently not owned, value from WMI class method 'IsOwned' was: $($IsTPMOwned)"
                            
                # Generate a random pass phrase to be used when taking ownership of TPM chip
                $NewPassPhrase = (New-Guid).Guid.Replace("-", "").SubString(0, 14)
        
                # Construct owner auth encoded string
                $NewOwnerAuth = $TPMClass.ConvertToOwnerAuth($NewPassPhrase).OwnerAuth
        
                # Attempt to take ownership of TPM chip
                $Invocation = $TPMClass.TakeOwnership($NewOwnerAuth)
                if ($Invocation.ReturnValue -eq 0) {
                    Write-Log "TPM chip ownership was successfully taken"
                }
                else {
                    Write-Log "Failed to take ownership of TPM chip, return value from invocation: $($Invocation.ReturnValue)"
                }
            }
            else {
                Write-Log "TPM chip is currently owned, will not attempt to take ownership"
            }
        }
        catch [System.Exception] {
            Write-Log "An error occurred while taking ownership of TPM chip. Error message: $($_.Exception.Message)"
        }
        
        try {
            #Enable BitLocker using TPM
            Enable-BitLocker -MountPoint $env:SystemDrive -UsedSpaceOnly -EncryptionMethod XtsAes256 -TpmProtector -ErrorAction Stop -SkipHardwareTest -Confirm:$False
            Write-Log "BitLocker enabled using TPM"
        }
        catch {
            Write-Log "Failed to enable BitLocker using TPM: $_"
            $postKeyToAAD = $False
            Throw "Error while setting up BitLocker during TPM step: $_"
        }

        try {
            #Enable BitLocker with a normal password protector
            Enable-BitLocker -MountPoint $env:SystemDrive -UsedSpaceOnly -EncryptionMethod XtsAes256 -RecoveryPasswordProtector -ErrorAction Stop -SkipHardwareTest -Confirm:$False
            Write-Log "BitLocker recovery password set"
        }
        catch {
            if ($_.Exception -like "*0x8031004E*") {
                Write-Log "reboot required before BitLocker can be enabled"
            }
            else {
                Write-Log "Error while setting up BitLocker: $_"
                $postKeyToAAD = $False
                Throw "Error while setting up BitLocker during noTPM step: $_"
            }
        } 

        # Validate that previous configuration was successful and all key protectors have been enabled and encryption is on
        Start-Sleep -Seconds 15
        $BitLockerStatus = Get-BitLockerVolume $env:SystemDrive -ErrorAction Stop | Select-Object -Property VolumeStatus
    
    } # end section "if ($BitLockerStatus.VolumeStatus -eq "FullyDecrypted")"

    # Wait for encryption to complete
    if ($BitLockerStatus.VolumeStatus -like "EncryptionInProgress") {
        do {
            $BitLockerPercentage = Get-BitLockerVolume $env:SystemDrive -ErrorAction Stop | Select-Object -Property EncryptionPercentage
            Write-Log "Current encryption percentage progress: $($BitLockerPercentage.EncryptionPercentage)"
            Write-Log "Waiting for BitLocker encryption progress to complete, sleeping for 15 seconds"
            Start-Sleep -Seconds 15
        }
        until ($BitLockerPercentage.EncryptionPercentage -eq 100)
        Write-Log "Encryption of operating system drive has now completed"

        # Validate that device is now fully encrypted
        Start-Sleep -Seconds 5
        $BitLockerStatus = Get-BitLockerVolume $env:SystemDrive -ErrorAction Stop | Select-Object -Property VolumeStatus
    }

    if ($BitLockerStatus.VolumeStatus -like "FullyEncrypted") {

        Write-Log "System volume $($env:SystemDrive) is fully encrypted"
        $postKeyToAAD = $true
    }

    if ($postKeyToAAD) {
        
        # Get BitLocker and registry information
        try {

            # Get BitLocker recovery information
            $AllProtectors = (Get-BitLockerVolume -MountPoint $env:SystemDrive).KeyProtector
            $RecoveryProtector = ($AllProtectors | Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" })
            
            # Full BitLocker Recovery ID
            $RecoverProtectorID = ($RecoveryProtector | Select-Object -ExpandProperty KeyProtectorID).Trim('{')
            
            # Get BitLocker Escrow registry key
            $BitLockerEscrowResultsValue = Get-ItemProperty "$RegistryRootPath" -Name "BitLockerEscrowResult" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty BitLockerEscrowResult -ErrorAction SilentlyContinue

            # Get BitLocker RecoveryID registry key
            $BitLockerRecoveryIDValue = Get-ItemProperty "$RegistryRootPath" -Name "RecoveryKeyID" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty RecoveryKeyID -ErrorAction SilentlyContinue

            # Escrow BitLocker recovery key to Azure AD
            if (((($BitLockerEscrowResultsValue -eq $null) -or ($BitLockerEscrowResultsValue -ne "True") -or ($BitLockerRecoveryIDValue -eq $null) -or ($RecoverProtectorID -notlike "$($BitLockerRecoveryIDValue)*")))) {
                
                try {

                    if ($RecoverProtectorID -notlike "$($BitLockerRecoveryIDValue)*") {

                        Write-Log "BitLocker recovery ID has changed"
                    }
                    
                    Write-Log "Attempting to backup BitLocker recovery password to Azure AD for device $env:COMPUTERNAME"

                    #Push Recovery Password AAD
                    BackupToAAD-BitLockerKeyProtector $env:systemdrive -KeyProtectorId $RecoveryProtector.KeyProtectorID -ErrorAction Stop
                    Set-RegistryValue -Path $RegistryRootPath -Name "BitLockerEscrowResult" -Value "True"
                    Write-Log "Successfully backed up recovery password details"

                }

                catch [System.Exception] {
                    Write-Log "An error occurred while attempting to backup recovery password to Azure AD. Error message: $($_.Exception.Message)"
                    Set-RegistryValue -Path $RegistryRootPath -Name "BitLockerEscrowResult" -Value "False"
                }

                try {
                    # First 8 characters of BitLocker Recovery ID
                    $PswdProtectorID = (($RecoveryProtector | Select-Object -ExpandProperty KeyProtectorID).split('-')[0]).Trim('{')
                    $PswdProtectorID = $PswdProtectorID.Trim()

                    # Create registry key with first 8 characters of Recovery key ID (in case this changes in the future)
                    Set-RegistryValue -Path $RegistryRootPath -Name "RecoveryKeyID" -Value $PswdProtectorID
                }

                catch [System.Exception] {
                    Write-Log "An error occurred while attempting to create Recovery Key ID registry key. Error message: $($_.Exception.Message)"
                }

            }
                                
            else {

                Write-Log "Value for 'BitLockerEscrowResults' in registry is '$($BitLockerEscrowResultsValue)', and recovery key ID is up to date. No further action required."
            }
        }
        catch [System.Exception] {

            Write-Log "An error occurred while detecting BitLocker and registry values. Error message: $($_.Exception.Message)"
        }

    } # end section "if ($postKeyToAAD)"

}

else {

    Write-Log "Device is not a laptop. Skipping BitLocker encryption."

    try {

        # Remove files and scheduled task, so script will not re-run
        Write-Log "Removing files and scheduled task, so script will not re-run"
        Remove-Item -Path "$WorkingDirectory\$($RunningScriptName).ps1" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$WorkingDirectory\$($RunningScriptName).xml" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$WorkingDirectory\*" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$WorkingDirectory" -Force -ErrorAction SilentlyContinue

        # Delete scheduled task (so that script does not re-run)
        cmd /c 'schtasks.exe /delete /tn "EnableBitlockerAndRegisterInAAD" /F'
        Write-Log "Successfully deleted scheduled task named `"EnableBitlockerAndRegisterInAAD`""
    }

    catch [System.Exception] {
        Write-Log "An error occurred while deleting scheduled task. Error message: $($_.Exception.Message)"
    }
}
