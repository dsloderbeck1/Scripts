<#	
	.NOTES
	===========================================================================
	 Created on:   	12/7/2017
     Created by:    Danny Sloderbeck
	 Filename:      Create-NewBootImage.ps1
     File Version:  1.0
	===========================================================================
    .DESCRIPTION
    This script is used to create a new customized boot image, using the latest version of the Windows ADK installed on your ConfigMgr Primary Site Server.
    This is a modified version of the "RegenerateBootImageWinPE10-v7" script downloaded from here: https://gallery.technet.microsoft.com/RegenerateBootImageWinPE10-f508f1e4

    This script allows you to configure the following options when creating a new boot image:
    
    - Create 64-bit boot image, 32-bit boot image, or both
    - Designate the location where you would like to store the new boot image (instead of using the default location created by ConfigMgr)
    - Install designated WinPE 10 drivers for each boot image architecture
    - Copy to package share on distribution points
    - Set WinPE background
    - Increase WinPE scratch size space
    - Enables command support for each boot image (optional - for "F8" support in WinPE)
    - Enable PXE support for PXE-enabled distribution point
    - Enables pre-start command, with the option to also include prestart files
    - Allows you to specify the FQDN of the intended SCCM provider (if script is not running from ConfigMgr primary site server)
    - Update and distribute boot image to ConfigMgr distribution point group
        * ($UpdateDistributionPoints is only honored if OverwriteExistingImage is set to $True)
    - Enables Nomad support in the boot image properties

    - Enables the following optional components in the boot image properties:

        - Windows PowerShell (WinPE-DismCmdlets) 
        - Microsoft .NET (winPE-Dot3Svc)
        - Storage (WinPE-EnhancedStorage)
        - HTML (WinPE-HTA)
        - Windows PowerShell (WinPE-StorageWMI)
        - Microsoft Secure Boot Cmdlets (WinPE-SecureBootCmdlets)
    
    .NOTES
    This script must be run from a machine that has Windows 10 ADK installed (such as the ConfigMgr primary site server), and contains the ConfigMgr PowerShell module.
    This script must be run with elevated privileges that have proper access to the ConfigMgr.

    Please note the following if you are setting any of the following script parameters to $true:

        if $UpdateDistributionPoints = $true, be sure to list the name of the distribution point group
        if $EnablePrestartCommand = $true, be sure to list the pre-start command
        if $PrestartIncludeFilesDirectory = $true, be sure to list the directory path of the prestart files
        if $IntegrateWinPeDrivers = $true, Dism.exe MUST be installed on the device where script is running from. Also, be sure to list the path to your WinPE 10 drivers
            * WinPE 10 drivers must be placed into a "x64" or "x86" folder at the root of the "$WinPeDriversPath" path (found in "optional parameters" section) to install correctly

    All of these settings are found under the "optional parameters" section.
#>  

## Script parameters ##
[CmdLetBinding()]
Param
(
    [Parameter(Mandatory = $false,
        HelpMessage = 'If you are NOT running this script from your ConfigMgr primary site server, enter the FQDN of the primary site server. Otherwise, this can be left blank.')]
    [AllowEmptyString()]
    [String]$SccmServer,

    [Parameter(Mandatory = $false,
        HelpMessage = 'Name can be changed to match your personal preference, as long as it ends with .wim - Example: CMBootImage.wim')]
    [ValidateScript( { $_.EndsWith(".wim") })]
    [String]$BootImageName = "boot.wim",

    [Parameter(Mandatory = $false,
        HelpMessage = 'Just cosmetics to display the OS version of your boot image. If left blank, the OS version is used as the version name')]
    [AllowEmptyString()]
    [String]$BootImageConsoleVersion,
    
    [Parameter(Mandatory = $false,
        HelpMessage = 'Allows you to set the directory path of where you would like to create the new boot image. If left blank, will use the default path where the ConfigMgr boot image is located.')]
    [AllowEmptyString()]
    [String]$BootWimFolderPath = "\\winsys\winsys\Packages\Deployment_WRK\_BootFiles",

    [Parameter(Mandatory = $false,
        HelpMessage = 'Set to $true to inject WinPE10 drivers into boot image')] 
    [Boolean]$InjectWinPe10Drivers = $true,

    [Parameter(Mandatory = $false,
        HelpMessage = 'Set to $true if you want to Copy the content in this package to a package share on distribution points')] 
    [Boolean]$CopytoDpPkgShare = $true,

    [Parameter(Mandatory = $false,
        HelpMessage = 'Allows you to set the directory path of where you would like to create the new boot image. If left blank, will use the default path where the ConfigMgr boot image is located.')]
    [AllowEmptyString()]
    [String]$WinPeBackground = "\\winsys\winsys\Packages\Deployment_WRK\_BootFiles\WestRock.bmp",

    [Parameter(Mandatory = $false,
        HelpMessage = 'Valid Values True/False - Set to True if you want to enable Command Command support on your new created boot images (applies only to new  created boot images)')]
    [ValidateSet('32', '64', '128', '256', '512')]
    [int32]$BootImageScratchSpace = "512",

    [Parameter(Mandatory = $false,
        HelpMessage = 'Set to $true if you want to enable Command Command support on your new created boot images')]
    [Boolean]$EnableDebugShell = $true,

    [Parameter(Mandatory = $false,
        HelpMessage = 'Set to $true if the newly created boot image should be enabled to be deployed from PXE enabled DP')]
    [Boolean]$PxeEnabled = $false,

    [Parameter(Mandatory = $false,
        HelpMessage = 'Set to $true to enable prestart command on boot image')] 
    [Boolean]$EnablePrestartCommand = $true,

    [Parameter(Mandatory = $false,
        HelpMessage = 'Set to $true if prestart command should include files')] 
    [Boolean]$PrestartIncludeFilesDirectory = $true,
    
    [Parameter(Mandatory = $false,
        HelpMessage = 'Set to $true if you want to distribute boot images to ConfigMgr Distribution Group')] 
    [Boolean]$DistributeBootImage = $true,

    [Parameter(Mandatory = $false,
        HelpMessage = 'Set to $true if you want update Distribution Point (applies only if $OverwriteExistingImage = $true and the script detects an existing boot image matching $BootImageName)')] 
    [Boolean]$UpdateDistributionPoints = $true,

    [Parameter(Mandatory = $false,
        HelpMessage = 'Set to $true if you want to replace an existing boot image')] 
    [Boolean]$OverwriteExistingImage = $true,

    [Parameter(Mandatory = $false,
        HelpMessage = 'Set to $true to integrate Nomad components into boot image')] 
    [Boolean]$IntegrateNomad = $true
)

# Set the current working directory to ensure when calling files from the current directory that the full path is used.
$WorkingDirectory = $MyInvocation.MyCommand.Path | Split-Path -Parent

#Create QuestionBox for desired architecture of new boot image(s)
$title = "Choose desired architecture of new boot image(s)"
$message = "Do you want to create a 64-bit boot image, 32-bit boot image, or both?"
$x64 = New-Object System.Management.Automation.Host.ChoiceDescription "&64-bit"
$x86 = New-Object System.Management.Automation.Host.ChoiceDescription "&32-bit"
$Both = New-Object System.Management.Automation.Host.ChoiceDescription "&Both"
$options = [System.Management.Automation.Host.ChoiceDescription[]]($x64, $x86, $Both)
$result = $host.ui.PromptForChoice($title, $message, $options, 0)

#Echo the architecture selected
switch ($result) {
    
    0 {
        #user selected 64-bit
        Write-Output "`nCreating 64-bit boot image only."
        $OSArchitecture = "x64"
    }

    1 {
        #user selected 32-bit
        Write-Output "`nCreating 32-bit boot image only."
        $OSArchitecture = "x86"
    }

    2 {
        #user selected Both
        Write-Output "`nCreating both 64-bit & 32-bit boot images."
        $OSArchitecture = "Both"
    }
}


## Start of Optional Parameter values section ##
if ($UpdateDistributionPoints -eq $true) {
    # Specify the ConfigMgr Distribution Group name used when distributing new boot image
    $DpGroupName = "Tier 1 - All Distribution Points"
}

if ($EnablePrestartCommand -eq $true) {
    # Specify the prestart command line
    [String]$PrestartCommandLine = "WRK-OSDFrontEnd.exe"
}

if ($PrestartIncludeFilesDirectory -eq $true) {
    # Specify the directory path for the prestart files
    [String]$PrestartFilesPath = "\\winsys\winsys\Packages\Deployment_WRK\WestRock\ConfigMgr OSD FrontEnd"
}

if ($InjectWinPe10Drivers -eq $true) {
    # Specify the root path of your WinPE10 drivers. This path should have sub-folders of "x64" and "x86" which contain the respective WinPE 10 drivers.
    $WinPeDriversRootPath = "\\winsys\winsys\Drivers_WRK\SCCM_Driver_Source\WinPE\WinPE10"
}
## End of optional parameter values section ##

# Capture current date
$Date = (Get-Date).ToString("MM-dd-yyyy")

# Set log folder location
$LogFolder = "$WorkingDirectory\Logs"
if (!(Test-Path "$LogFolder")) {
    New-Item -Path "$LogFolder" -ItemType Directory -Force
}
[String]$LogfileName = "Create-NewBootImage"
[String]$Logfile = "$LogFolder\$LogfileName.log"

Function Write-Log {
    Param ([string]$logstring)
    If (Test-Path $Logfile) {
        If ((Get-Item $Logfile).Length -gt 2MB) {
            Rename-Item $Logfile $Logfile".bak" -Force
        }
    }
    $WriteLine = (Get-Date).ToString() + " " + $logstring
    Add-content $Logfile -value $WriteLine
    Write-Host $WriteLine
}
 
if ($OSArchitecture -eq "both") {
    Write-Log "Beginning process to create new x64 and x86 boot images."
}

else {
    Write-Log "Beginning process to create new $OSArchitecture boot image."
}
 
# Verify access to Configuration Manager Console for a PowerShell Commandlet import
Try {
    $ConfigMgrModule = ($Env:SMS_ADMIN_UI_PATH.Substring(0, $Env:SMS_ADMIN_UI_PATH.Length - 5) + '\ConfigurationManager.psd1')
    Import-Module $ConfigMgrModule
    Write-Log "Found SCCM-Console-Environment"
    Write-Log $ConfigMgrModule
}
Catch {
    Write-Log "Exception Type: $($_.Exception.GetType().FullName)"
    Write-Log "Exception Message: $($_.Exception.Message)"
    Write-Log "ERROR! Console not installed or found"
    Write-Log "Script will exit"
    Exit 1
}

if ($SccmServer.Length -ne 0) {
    # Get Site-Code and Site-Provider-Machine from FQDN of primary site server entered in script parameters
    Try {
        $SMS = Get-WmiObject -ComputerName $SccmServer -Namespace 'root\sms' -query "SELECT SiteCode,Machine FROM SMS_ProviderLocation" 
        $SiteCode = $SMS.SiteCode
        $SccmServer = $SMS.Machine
        Write-Log "SiteCode: $SiteCode" 
        Write-Log "SiteServer: $SccmServer" 
    }
    Catch {
        Write-Log "Exception Type: $($_.Exception.GetType().FullName)" 
        Write-Log "Exception Message: $($_.Exception.Message)"
        Write-Log "Unable to find in WMI SMS_ProviderLocation. This Script has to run on a SiteServer!"
        Exit 1
    }
}

else {
    # Get Site-Code and Site-Provider-Machine directly from WMI (assumes script is running directly from primary site server)
    Try {
        $SMS = Get-WmiObject -Namespace 'root\sms' -query "SELECT SiteCode,Machine FROM SMS_ProviderLocation" 
        $SiteCode = $SMS.SiteCode
        $SccmServer = $SMS.Machine
        Write-Log "SiteCode: $SiteCode" 
        Write-Log "SiteServer: $SccmServer" 
    }
    Catch {
        Write-Log "Exception Type: $($_.Exception.GetType().FullName)" 
        Write-Log "Exception Message: $($_.Exception.Message)"
        Write-Log "Unable to find in WMI SMS_ProviderLocation. This Script has to run on a SiteServer!"
        Exit 1
    }
}

# Change to CM-Powershell-Drive
Write-Log "Prepare Environment for $OSArchitecture Boot Image operations. Create PS-Drive if not found."
$CMDrive = Get-PSProvider -PSProvider CMSite
If ($CMDrive.Drives.Count -eq 0) {
    Write-Log "CMSite-Provider does not have a Drive! Trying to create it."
    Try {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteProvider
        Write-Log "CMSite-Provider-Drive created!"
    }
    Catch {
        Write-Log "Exception Type: $($_.Exception.GetType().FullName)"
        Write-Log "Exception Message: $($_.Exception.Message)"
    }
}

## ReCreate BootImage Function
Function CreateBootImage {
    
    [CmdLetBinding()]
    Param 
    (
        [Parameter(Mandatory = $True)]
        [ValidateSet("x86", "x64")]
        [string]$Architecture
    )

    Switch ($Architecture) {
        "x86" { $ArchitecturePath = "i386"; $OSArchitecture = "x86"; $DismArchPath = "x86"; Break }
        "x64" { $ArchitecturePath = "x64"; $OSArchitecture = "x64"; $DismArchPath = "amd64"; Break }
    }

    # Specify date parameter used when creating folder for new boot image
    $BootWimDate = (Get-Date).ToString("yyyyMMdd")

    # Create folder for new boot image
    if ($BootWimFolderPath.Length -ne 0) {
        $BootWimFolder = "filesystem::$BootWimFolderPath\$OSArchitecture"
        Write-Log "Creating folder for new boot image at the following location: $BootWimFolder"
    }

    else {
        # Use ConfigMgr default boot image folder location
        Write-Log "Boot image folder location not specified. Using default location of \\$($SccmServer)\SMS_$($SiteCode)\OSD\boot"
        $BootWimFolderPath = "\\$($SccmServer)\SMS_$($SiteCode)\OSD\boot"
        $BootWimFolder = "filesystem::\\$($SccmServer)\SMS_$($SiteCode)\OSD\boot\$($OSArchitecture)"
    }
        
    # Verify that boot image folder does not already exist
    if (Test-Path "$BootWimFolder\$BootWimDate") {
        Write-Log "Boot Wim folder already exists. Creating another folder for new boot image."
        $BootWimDate = "$BootWimDate" + "_" + "1"
        New-Item -Path "$BootWimFolder\$BootWimDate" -ItemType Directory -Force
    }
        
    else {
        Write-Log "Creating folder for new boot image at $BootWimFolder\$BootWimDate"
        New-Item -Path "$BootWimFolder\$BootWimDate" -ItemType Directory -Force
    }

    # Create local folders for temporarily mounting boot image
    $BootWimTemp = "$WorkingDirectory\BootWim_Temp\$OSArchitecture"
    if (!(Test-Path "$BootWimTemp")) {
        New-Item -Path "$BootWimTemp" -ItemType Directory -Force
    }

    $BootWimTempMount = "$WorkingDirectory\BootWimMount_Temp\$OSArchitecture"
    if (!(Test-Path "$BootWimTempMount")) {
        New-Item -Path "$BootWimTempMount" -ItemType Directory -Force
    }
    
    # Start creation of new boot image
    Write-Log "Connecting to WMI Namespace: \\$SccmServer\root\sms\site_$SiteCode`:SMS_BootImagePackage"
    $BootImageWMIClass = [wmiclass]"\\$SccmServer\root\sms\site_$SiteCode`:SMS_BootImagePackage"
    [String]$BootImageTempPath = "$BootWimTemp\$BootImageName"
    [String]$BootImageSourcePath = "$($BootWimFolderPath)\$OSArchitecture\$BootWimDate\$BootImageName"

    If ($(Get-Location) -match $SiteCode) {
        Write-Log "Switching Drive to File System"
        Set-Location "C:"
    }

    If (Test-Path -Path $BootImageTempPath -PathType Leaf) {
        If (!$OverwriteExistingImage) {
            Write-Log "Error: $BootImageTempPath found and OverwriteExistingImage is set to `$False"
            # Critical Error occured exit function
            break
        }   
        Write-Log "$BootImageTempPath found need to backup first"
        Copy-Item $BootImageTempPath $BootImageTempPath".bak" -Force
        [boolean]$BootImageFound = $True        
    } 
    Else {
        Write-Log "$BootImageTempPath not found no need to backup"            
    }

    Try {
        Write-Log "Generating new boot image ($OSArchitecture). This will take a few minutes... "
        $BootImageWMIClass.ExportDefaultBootImage($Architecture , 1, $BootImageTempPath) | Out-Null

        Write-Log "New $OSArchitecture Boot Image created. Continue with post tasks "
        $BootImageConsoleName = "Boot Image $OSArchitecture ($Date)"
        $NewBootImageName = "$BootImageConsoleName"

        # Inject WinPE 10 drivers into new boot image
        if ($InjectWinPe10Drivers -eq $true) {

            # Exit script if Dism.exe does not exist on device
            if (!(Test-Path "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\DISM\dism.exe")) {

                Write-Log "Dism.exe not found on this device. Unable to inject WinPE 10 drivers. Script will not exit."
                Remove-Item -Path "$BootImageTempPath" -Force
                Exit 1
            }

            Try {

                Write-Log "Mounting $OSArchitecture Boot Image at $BootWimTempMount"
                Mount-WindowsImage -ImagePath "$BootImageTempPath" -Index 1 -Path "$BootWimTempMount"

                # Set relative path for WinPE 10 drivers (so that correct architecture of WinPE drivers are installed)
                $WinPeDriversArchPath = "$WinPeDriversRootPath" + "\" + "$OSArchitecture"
                Write-Log "Attempting to install WinPE 10 drivers from the following location: $WinPeDriversArchPath"


                # Create variables with double quotation marks (so that DISM commands will work correctly if paths contain spaces)
                $WinPeDrivers = "`"$WinPeDriversArchPath`""
                $DismLogFolder = "`"$LogFolder`""
                $BootWimTempMountFolder = "`"$BootWimTempMount`""
        
                # Attempt to install WinPE 10 Drivers
                Write-Log "Attempting to install WinPE 10 drivers to $OSArchitecture boot image"
                Start-Process "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$DismArchPath\DISM\dism.exe" -ArgumentList "/image:$BootWimTempMountFolder /LogPath:$DismLogFolder\AddBootWimDrivers_$Date.log /add-driver /driver:$WinPeDrivers /Recurse /forceunsigned" -Wait

                # Commit changes to boot image
                Write-Log "Commit WinPE driver installation changes to $OSArchitecture boot image"
                Dismount-WindowsImage -Path "$BootWimTempMount" -Save
            }

            Catch {
                Write-Log "Exception Type: $($_.Exception.GetType().FullName)"
                Write-Log "Exception Message: $($_.Exception.Message)"
                Write-Log "Error: Failed to inject drivers in $OSArchitecture boot image"
                Dismount-WindowsImage -Path "$BootWimTempMount" -Discard
                Remove-Item -Path "$BootImageTempPath" -Force
                Break
            }

        } #end section "if ($InjectWinPe10Drivers -eq $true)"

        # Copy new boot image to $BootImageSourcePath
        Copy-Item -Path "$BootImageTempPath" -Destination "$BootImageSourcePath" -Force

        # Delete local copy of boot image
        Remove-Item -Path "$BootImageTempPath" -Force

        If (-not($BootImageFound)) {
            # Actions to perform if Boot Image file did not exist
            Write-Log "Performing actions section $OSArchitecture Boot Image not exist"
            If (-not($(Get-Location) -match $SiteCode)) {
                Write-Log "Switching Drive for ConfigMgr-CmdLets"
                Set-Location $SiteCode":"
            }

            Try {
                Write-Log "Import $OSArchitecture Boot Image into SCCM"
                If ($BootImageConsoleDescription.Length -eq 0) {
                    New-CMBootImage -Path $BootImageSourcePath -Index 1 -Name $NewBootImageName -Version $BootImageConsoleVersion | Out-Null
                    Write-Log "Successfully imported $BootImageSourcePath"
                }
                Else {
                    New-CMBootImage -Path $BootImageSourcePath -Index 1 -Name $NewBootImageName -Version $BootImageConsoleVersion -Description $BootImageConsoleDescription | Out-Null
                    Write-Log "Successfully imported $BootImageSourcePath"
                }
            }
            Catch {
                Write-Log "Exception Type: $($_.Exception.GetType().FullName)"
                Write-Log "Exception Message: $($_.Exception.Message)"
                Write-Log "Error: Failed to import $BootImageSourcePath"

                # Delete copy of new boot wim (since boot image could not be imported into ConfigMgr successfully)
                Remove-Item -Path "$BootImageSourcePath" -Force
            
                # Critical Error occured exit function
                break
            }
        
if ($IntegrateNomad -eq $true ) {
<#
Enable Nomad on boot image
NOTE: Enabling Nomad settings on boot image may NOT work if this section of script is tab-indented.
Recommendation is to leave this section of script left-aligned.
#>

Try {
Set-Location $SiteCode":"

Write-Log "Get Package ID of $OSArchitecture boot image"
$BootImageID = (Get-CMBootImage -Name $NewBootImageName).PackageID
Write-Log "Package ID of $OSArchitecture boot image is $BootImageID"

$acp =
@"
<AlternateDownloadSettings SchemaVersion="1.0"><Provider Name="NomadBranch"><Data><ProviderSettings /><pc>8</pc></Data></Provider></AlternateDownloadSettings>
"@
$MaxWorkRate = 80
$pkg = Get-WmiObject -ComputerName $SccmServer -class SMS_BootImagePackage -namespace root\sms\site_$($SiteCode) -Filter "PackageID='$BootImageID'"
#this displays the explicit path to the object
$pkg2 = [wmi] $pkg.__Path    #use wmi accelerator to grab the object, including lazy

if ($pkg2.AlternateContentProviders -notmatch "nomad") {
"enabling acp"
Write-Log "Enabling default Nomad Branch settings on $OSArchitecture boot image ($BootImageID)"
$pkg2.AlternateContentProviders = $acp
$pkg2.Put()
}

else {
#acp already enabled, checking settings
#check to see if work rate is configured properly
$pkg2xml = [xml] $pkg2.AlternateContentProviders

if ($pkg2xml.AlternateDownloadSettings.Provider.data.wr -ne $null) {
if ($pkg2xml.AlternateDownloadSettings.Provider.data.wr -gt $MaxWorkRate) {
"non-standard config Resetting acp default settings"
$pkg2.AlternateContentProviders = $acp
$pkg2.Put()
}
else {
Write-Log "acp already enabled, and work rate is acceptable"
}
}
else {
Write-Log "wr is Null, which is considered acceptable"
}
}

}

Catch {
Write-Log "Exception Type: $($_.Exception.GetType().FullName)"
Write-Log "Exception Message: $($_.Exception.Message)"
Write-Log "Error: Failed to enable Nomad on $OSArchitecture boot image ($BootImageID)"
# Critical Error occured exit function
break
}

} # end of "$IntegrateNomad" statement

            # Enable optional components on boot image
            Try {

                # Get Package ID of newly created boot image
                $BootImageID = (Get-CMBootImage -Name $NewBootImageName).PackageID

                If ($BootImageConsoleVersion.Length -eq 0) {
                    Write-Log "Get ImageOSVersion value of new $OSArchitecture boot image."
                    $BootImageConsoleVersion = (Get-CMBootImage -Id $BootImageID).ImageOSVersion
                }

                Write-Log "Apply $OSArchitecture Boot Image with the following properties: EnableCommandSupport = $EnableDebugShell, DeployFromPxeDistributionPoint = $PxeEnabled, Version = $BootImageConsoleVersion, Copy to Package share on distribution points = $CopytoDpPkgShare"
                Set-CMBootImage -Id $BootImageID -EnableCommandSupport $EnableDebugShell -DeployFromPxeDistributionPoint $PxeEnabled -Version $BootImageConsoleVersion -Priority High -CopyToPackageShareOnDistributionPoint $CopytoDpPkgShare

                if ($EnablePrestartCommand -eq $true) {
                    Write-Log "Enabling prestart command of $PrestartCommandLine"
                    Set-CMBootImage -Id $BootImageID -PrestartCommandLine "$PrestartCommandLine"
                }

                if ($PrestartIncludeFilesDirectory -eq $true) {
                    Write-Log "Including prestart files from $PrestartFilesPath"
                    Set-CMBootImage -Id $BootImageID -PrestartIncludeFilesDirectory "$($PrestartFilesPath)"
                }

                if ($WinPeBackground.Length -ne 0) {
                    Write-Log "Setting WinPE background to $WinPeBackground"
                    Set-CMBootImage -Id $BootImageID -BackgroundBitmapPath "$($WinPeBackground)"
                }

                if ($BootImageScratchSpace.Length -ne 0) {
                    Write-Log "Setting scratch space to $BootImageScratchSpace MB"
                    Set-CMBootImage -Id $BootImageID -ScratchSpace $BootImageScratchSpace
                }

                # Get WMI information of Optional Components to add to boot image
                    #- Windows PowerShell (WinPE-DismCmdlets) 
                    #- Microsoft .NET (winPE-Dot3Svc)
                    #- Storage (WinPE-EnhancedStorage)
                    #- HTML (WinPE-HTA)
                    #- Windows PowerShell (WinPE-StorageWMI)
                    #- Microsoft Secure Boot Cmdlets (WinPE-SecureBootCmdlets)

                if ($OSArchitecture -eq "x64") {

                    $OptCompIDs = "(27,28,29,36,37,40,41,44,45,50,52,58)"
                }

                if ($OSArchitecture -eq "x86") {

                    $OptCompIDs = "(1,2,3,10,11,14,15,18,19,24,26,57)"
                }
                
                $LangID = '1033'
                $SMSNameSpace = "root\sms\site_$($SiteCode)"

                $WmiObject = Get-WmiObject -ComputerName $SccmServer -Query "SELECT * FROM SMS_OSDeploymentKitWinPEOptionalComponent WHERE LanguageID=$LangID AND UniqueID is in $OptCompIDs" -Namespace $SMSNameSpace 
            
                foreach ($z in $WmiObject) {
                    $x = $z | ConvertTo-CMIResultObject
                    Set-CMBootImage -Id $BootImageID -AddOptionalComponent $x 
                }
            
                Write-Log "Successfully applied Boot image properties to $OSArchitecture Boot image"

            }

            Catch {
                Write-Log "Exception Type: $($_.Exception.GetType().FullName)"
                Write-Log "Exception Message: $($_.Exception.Message)"
                Write-Log "Failed to apply $OSArchitecture Boot image properties"
            }

        } # end section "If (-not($BootImageFound))"

        Else {
            # Actions to perform if Boot Image file did exist
            Write-Log "Performing actions section $OSArchitecture Boot Image did exist"
            $BootImageQuery = Get-WmiObject -ComputerName $SccmServer -Class SMS_BootImagePackage  -Namespace root\sms\site_$($SiteCode) -ComputerName $SccmServer | where-object { $_.ImagePath -like "*$ArchitecturePath*" -and $_.ImagePath -like "*$BootImageName*" }
        
            ForEach ($BootImagexIndex in $BootImageQuery) {
                $BootImageLogName = $BootImagexIndex.Name
                Write-Log "Working on $OSArchitecture Boot Image: $BootImageLogName" 
                # Verify if the current Site is owner of this Boot Image (Unneeded in single Primary Site environments)
                If ($BootImagexIndex.SourceSite -ne $SiteCode) {
                    Write-Log "Error: Site is not owner of this $OSArchitecture Boot Image $BootImageLogName will stop post actions"       
                } 
                Else {
                    If ($BootImageConsoleVersion.Length -eq 0) {
                        $BootImageConsoleVersion = $BootImagexIndex.ImageOSVersion
                    }
                
                    $BootImagexIndexVersion = $BootImagexIndex.Version
                    Write-Log "Will use version: $BootImageConsoleVersion as Version value"
                }
                
                $BootImage = Get-WmiObject -Class SMS_BootImagePackage  -Namespace root\sms\site_$($SiteCode) -ComputerName $SccmServer | where-object { $_.Name -like "*$BootImageLogName*" }
                Try {
                    Write-Log "Reload Image Properties to update console with new information"
                    $BootImage.ReloadImageProperties() | Out-Null
                }
                Catch {
                    Write-Log "Error: Failed to Reload $OSArchitecture Image Properties to update console with new information"
                }

                If ($UpdateDistributionPoints -eq $true) {
                    Try {
                        Write-Log "Trigger update Distribution Points"            
                        $BootImage.UpdateImage | Out-Null
                    }
                    Catch {
                        Write-Log "Error: Failed to Trigger update Distribution Points"
                    }
                }

                If (-not($(Get-Location) -match $SiteCode)) {
                    Write-Log "Switching Drive for ConfigMgr-CmdLets"
                    Set-Location $SiteCode":"
                }

                Try {
                    Write-Log "Apply $OSArchitecture Boot Image Properties for Version with Value $BootImageConsoleVersion"
                    Set-CMBootImage -Name $BootImageLogName -Version $BootImageConsoleVersion
                    Write-Log "Successfully applied Boot image properties"
                }
                Catch {
                    Write-Log "Exception Type: $($_.Exception.GetType().FullName)"
                    Write-Log "Exception Message: $($_.Exception.Message)"
                    Write-Log "Failed to apply $OSArchitecture Boot image properties"
                }
            }
        }
    } # end of section to generate new boot image
    
    Catch {
        Write-Log "Error: Failed to create $Architecture Boot Image. Exit $Architecture Boot Image post tasks."
        # Critical Error occured exit function
        Remove-Item -Path "$BootImageTempPath" -Force
        break
    }
    $BootImageFound = $False  


    if ($DistributeBootImage -eq $true ) {

        # Update boot image on distribution points
        Write-Log "Attempting to update $OSArchitecture Boot image"

        Try {
                
            Set-Location $SiteCode":"
            $BootImageID = (Get-CMBootImage -Name $NewBootImageName).PackageID
            Write-Log "Trigger update Distribution Points for boot image $BootImageID"
            Update-CMDistributionPoint -BootImageId $BootImageID
        }
            
        Catch {
            Write-Log "Exception Type: $($_.Exception.GetType().FullName)"
            Write-Log "Exception Message: $($_.Exception.Message)"
            Write-Log "Error: Failed to Trigger update Distribution Points for boot image $BootImageID"
            Exit 1
        }

        # Pause script to allow boot images to finish updating
        Write-Log "Pausing script for 60 seconds to allow $OSArchitecture boot image ($BootImageID) time to update on distribution points"
        Start-Sleep -Seconds 60

        # Distribute boot images to distribution point group
        Write-Log "Attempting to distribute $OSArchitecture Boot image to $DpGroupName Group"

        Try {              
            Set-Location $SiteCode":"
            $BootImageID = (Get-CMBootImage -Name $NewBootImageName).PackageID
            Write-Log "distribute boot image $BootImageID to $DpGroupName"
            Start-CMContentDistribution -BootImageId $BootImageID -DistributionPointGroupName $DpGroupName

            Write-Log "$OSArchitecture Boot image ($BootImageID) created and distributed to $DpGroupName successfully"             
        }
        
        Catch {
            Write-Log "Exception Type: $($_.Exception.GetType().FullName)"
            Write-Log "Exception Message: $($_.Exception.Message)"
            Write-Log "Error: Failed to distribute $OSArchitecture boot image ($BootImageID) to $DpGroupName"
        }

        # Pause script to allow boot images to finish distributing to $DpGroupName
        Write-Log "Pausing script for 60 seconds to allow boot image time to finish distributing to $DpGroupName"
        Start-Sleep -Seconds 60

    } # end section "if ($DistributeBootImage -eq $true )"

} # End of "CreateBootImage" function

Write-Log "Trying to generate $OSArchitecture Boot image"

Switch ($OSArchitecture) {
    "x64" { CreateBootImage -Architecture x64; Break }
    "x86" { CreateBootImage -Architecture x86; Break }
    "Both" {
        CreateBootImage -Architecture x64
        CreateBootImage -Architecture x86
        ; Break
    }
}