#Requires -Modules Evergreen, VcRedist
<#
    Import application packages into Intune
#>
[CmdletBinding(SupportsShouldProcess = $false)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "", Justification = "Writes status to the pipeline log.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingInvokeExpression", "", Justification = "Needed to execute Evergreen or VcRedist commands.")]
param (
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [System.String] $Application = "AdobeAcrobatReaderDCMUI",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [System.String] $Path = $PWD,

    [Parameter()]
    [System.String] $PackageFolder = "packages",

    [Parameter()]
    [System.String] $PackageManifest = "App.json",

    [Parameter()]
    [System.String] $InstallScript = "Install.ps1",

    [Parameter()]
    [ValidateSet("Apps", "Updates")]
    [System.String] $Type = "Apps"
)

try {
    # Authenticate to the Graph API
    # Expects secrets to be passed into environment variables
    Write-Host "Authenticate to the Graph API"
    $params = @{
        TenantId     = "$env:TENANT_ID"
        ClientId     = "$env:CLIENT_ID"
        ClientSecret = "$env:CLIENT_SECRET"
    }
    $script:AuthToken = Connect-MSIntuneGraph @params
}
catch {
    throw $_
}


# Convert $Application into an array because we can't pass an array via inputs into the workflow
Write-Host "Path: $Path"
Write-Host "Applications: $Application"
[System.Array] $Applications = $Application.ToString() -split ","

foreach ($App in $Applications) {
    $ApplicationName = $App.Trim()
    Write-Host "Application: $ApplicationName"

    try {
        # Read the package manifest JSON
        $Manifest = Get-Content -Path $([System.IO.Path]::Combine($Path, $PackageFolder, $Type, $ApplicationName, $PackageManifest)) -ErrorAction "SilentlyContinue" | `
            ConvertFrom-Json -ErrorAction "SilentlyContinue"
    }
    catch {
        throw $_
    }

    if ($Null -eq $Manifest.Application.Filter) {
        Write-Host "Application not supported by this workflow: $ApplicationName"
    }
    else {
        if ($Manifest.Application.Filter -match "Get-VcList") {

            # Handle the Visual C++ Redistributables via VcRedist
            $result = Invoke-Expression -Command $Manifest.Application.Filter
            $Filename = $(Split-Path -Path $result.Download -Leaf)
            Write-Host "Package: $($result.Name); $Filename."
            $params = @{
                Path     = $([System.IO.Path]::Combine($Path, $PackageFolder, $Type, $ApplicationName, $Manifest.PackageInformation.SourceFolder))
                ItemType = "Directory"
                Force    = $True
            }
            New-Item @params | Out-Null
            $params = @{
                Uri             = $result.Download
                OutFile         = $([System.IO.Path]::Combine($Path, $PackageFolder, $Type, $ApplicationName, $Manifest.PackageInformation.SourceFolder, $Filename))
                UseBasicParsing = $True
            }
            Invoke-WebRequest @params
        }
        else {

            # Get the application installer via Evergreen and download
            $result = Invoke-Expression -Command $Manifest.Application.Filter | Save-EvergreenApp -CustomPath $([System.IO.Path]::Combine($Path, $PackageFolder, $Type, $ApplicationName, $Manifest.PackageInformation.SourceFolder))

            # Unpack the installer file if its a zip file
            Write-Host "Downloaded: $($result.FullName)"
            if ($result.FullName -match "\.zip$") {
                $params = @{
                    Path            = $result.FullName
                    DestinationPath = $([System.IO.Path]::Combine($Path, $PackageFolder, $Type, $ApplicationName, $Manifest.PackageInformation.SourceFolder))
                }
                Write-Host "Expand: $($result.FullName)"
                Expand-Archive @params
                Remove-Item -Path $result.FullName -Force
            }

            # Run the command defined in PrePackageCmd
            if ($Manifest.Application.PrePackageCmd.Length -gt 0) {
                $params = @{
                    FilePath     = $result.FullName
                    ArgumentList = $($Manifest.Application.PrePackageCmd -replace "#Path", $([System.IO.Path]::Combine($Path, $PackageFolder, $Type, $ApplicationName, $Manifest.PackageInformation.SourceFolder)))
                    NoNewWindow  = $True
                    Wait         = $True
                }
                Write-Host "Start: $($result.FullName) $($Manifest.Application.PrePackageCmd -replace "#Path", $([System.IO.Path]::Combine($Path, $PackageFolder, $Type, $ApplicationName, $Manifest.PackageInformation.SourceFolder)))"
                Start-Process @params
                Remove-Item -Path $result.FullName -Force
            }
        }

        # Copy Install.ps1 into the source folder
        if (Test-Path -Path $([System.IO.Path]::Combine($Path, $PackageFolder, $Type, $ApplicationName, $Manifest.PackageInformation.SourceFolder, "Install.json"))) {
            $params = @{
                Path        = $([System.IO.Path]::Combine($Path, $InstallScript))
                Destination = $([System.IO.Path]::Combine($Path, $PackageFolder, $Type, $ApplicationName, $Manifest.PackageInformation.SourceFolder, $InstallScript))
                ErrorAction = "SilentlyContinue"
            }
            Write-Host "Copy: $([System.IO.Path]::Combine($Path, $PackageFolder, $Type, $ApplicationName, $Manifest.PackageInformation.SourceFolder, $InstallScript))"
            Copy-Item @params
        }
        else {
            Write-Host "Install.json does not exist."
        }

        # Import the application into Intune
        $params = @{
            Application       = $ApplicationName
            Path              = $([System.IO.Path]::Combine($Path, $PackageFolder))
            Type              = $Type
            DisplayNameSuffix = "(Package Factory)"
        }
        $params
        Write-Host "Run: Create-Win32App.ps1"
        . $([System.IO.Path]::Combine($Path, "Create-Win32App.ps1")) @params
    }
}
