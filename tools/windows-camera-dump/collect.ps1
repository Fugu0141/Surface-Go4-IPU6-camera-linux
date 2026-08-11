#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [switch]$CopyInfFiles,
    [switch]$IncludeRegistry,
    [switch]$VerbosePnPProperties
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path (Get-Location) "camera-dump-windows-$timestamp"
}
$root = [IO.Path]::GetFullPath($OutputDirectory)
$directories = @('system', 'pnp', 'drivers', 'registry', 'files', 'inf')
New-Item -ItemType Directory -Path $root -Force | Out-Null
foreach ($directory in $directories) {
    New-Item -ItemType Directory -Path (Join-Path $root $directory) -Force | Out-Null
}

$relevantPattern = '(?i)camera|image|ipu6|intel.*ipu|ov8865|ov5693|int347a|int33be|dw9714|dw9719|ad5820|lc898|vcm|lens|csi|mipi|int3472|firmware'
$errors = [Collections.Generic.List[object]]::new()

function Add-CollectionError {
    param([string]$Name, [Management.Automation.ErrorRecord]$Record)
    $errors.Add([pscustomobject]@{
        name = $Name
        message = $Record.Exception.Message
        category = $Record.CategoryInfo.Category.ToString()
    })
}

function Save-Text {
    param([string]$RelativePath, [scriptblock]$Action)
    $path = Join-Path $root $RelativePath
    try {
        $value = & $Action 2>&1 | Out-String -Width 4096
        [IO.File]::WriteAllText($path, $value, [Text.UTF8Encoding]::new($false))
    } catch {
        Add-CollectionError -Name $RelativePath -Record $_
        [IO.File]::WriteAllText($path, "ERROR: $($_.Exception.Message)`r`n", [Text.UTF8Encoding]::new($false))
    }
}

function Save-Json {
    param([string]$RelativePath, [scriptblock]$Action, [int]$Depth = 8)
    $path = Join-Path $root $RelativePath
    try {
        $value = & $Action
        $json = $value | ConvertTo-Json -Depth $Depth
        [IO.File]::WriteAllText($path, "$json`r`n", [Text.UTF8Encoding]::new($false))
    } catch {
        Add-CollectionError -Name $RelativePath -Record $_
        [IO.File]::WriteAllText($path, "{`"error`":$((ConvertTo-Json $_.Exception.Message))}`r`n", [Text.UTF8Encoding]::new($false))
    }
}

function Get-FileMetadata {
    param([string]$LiteralPath)
    if ([string]::IsNullOrWhiteSpace($LiteralPath) -or -not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        return $null
    }
    try {
        $item = Get-Item -LiteralPath $LiteralPath
        $version = $item.VersionInfo
        [pscustomobject]@{
            path = $item.FullName
            name = $item.Name
            length = $item.Length
            lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
            fileVersion = $version.FileVersion
            productVersion = $version.ProductVersion
            companyName = $version.CompanyName
            sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        }
    } catch {
        Add-CollectionError -Name "metadata:$LiteralPath" -Record $_
        $null
    }
}

Write-Host "Collecting Surface Go 4 camera reference data in: $root"

Save-Json 'system/os.json' { Get-CimInstance Win32_OperatingSystem | Select-Object * }
Save-Json 'system/computer-system.json' { Get-CimInstance Win32_ComputerSystem | Select-Object * }
Save-Json 'system/computer-system-product.json' { Get-CimInstance Win32_ComputerSystemProduct | Select-Object * }
Save-Json 'system/bios.json' { Get-CimInstance Win32_BIOS | Select-Object * }
Save-Json 'system/baseboard.json' { Get-CimInstance Win32_BaseBoard | Select-Object * }
Save-Text 'system/systeminfo.txt' { systeminfo.exe }
Save-Text 'system/msinfo-camera-summary.txt' {
    Get-ComputerInfo | Format-List WindowsProductName, WindowsVersion, OsBuildNumber, CsManufacturer, CsModel, BiosFirmwareType, BiosVersion, BiosReleaseDate
}

$allDevices = @()
try {
    $allDevices = @(Get-PnpDevice -PresentOnly:$false)
} catch {
    Add-CollectionError -Name 'Get-PnpDevice' -Record $_
}
$cameraClasses = @('Camera', 'Image')
$relevantDevices = @($allDevices | Where-Object {
    $_.Class -in $cameraClasses -or
    $_.FriendlyName -match $relevantPattern -or
    $_.InstanceId -match $relevantPattern
})

Save-Json 'pnp/all-devices.json' { $allDevices | Select-Object Status, Class, FriendlyName, InstanceId, Problem, ConfigManagerErrorCode }
Save-Json 'pnp/relevant-devices.json' { $relevantDevices | Select-Object Status, Class, FriendlyName, InstanceId, Problem, ConfigManagerErrorCode }
Save-Text 'pnp/relevant-devices.txt' { $relevantDevices | Format-List * }

$deviceProperties = [Collections.Generic.List[object]]::new()
foreach ($device in $relevantDevices) {
    try {
        $properties = @(Get-PnpDeviceProperty -InstanceId $device.InstanceId)
        if (-not $VerbosePnPProperties) {
            $properties = @($properties | Where-Object {
                $_.KeyName -match '(?i)HardwareIds|CompatibleIds|Driver|Service|Class|ClassGuid|Bus|Location|ContainerId|Firmware|DeviceDesc|FriendlyName|Parent'
            })
        }
        $deviceProperties.Add([pscustomobject]@{
            instanceId = $device.InstanceId
            friendlyName = $device.FriendlyName
            class = $device.Class
            properties = @($properties | Select-Object KeyName, Type, Data)
        })
    } catch {
        Add-CollectionError -Name "properties:$($device.InstanceId)" -Record $_
    }
}
Save-Json 'pnp/relevant-device-properties.json' { $deviceProperties } 12

Save-Text 'pnp/pnputil-enum-devices.txt' { pnputil.exe /enum-devices /connected /properties /drivers }
Save-Text 'pnp/pnputil-enum-drivers.txt' { pnputil.exe /enum-drivers /files }
Save-Text 'pnp/pnputil-camera-class.txt' { pnputil.exe /enum-devices /class Camera /properties /drivers }
Save-Text 'pnp/pnputil-image-class.txt' { pnputil.exe /enum-devices /class Image /properties /drivers }

$signedDrivers = @(Get-CimInstance Win32_PnPSignedDriver)
$relevantDrivers = @($signedDrivers | Where-Object {
    $_.DeviceClass -in $cameraClasses -or
    $_.DeviceName -match $relevantPattern -or
    $_.DeviceID -match $relevantPattern -or
    $_.InfName -match $relevantPattern
})
Save-Json 'drivers/relevant-signed-drivers.json' {
    $relevantDrivers | Select-Object DeviceName, DeviceID, HardwareID, DeviceClass, ClassGuid,
        DriverProviderName, DriverVersion, DriverDate, InfName, IsSigned, Manufacturer, FriendlyName
}
Save-Text 'drivers/relevant-signed-drivers.txt' { $relevantDrivers | Format-List * }

$services = @(Get-CimInstance Win32_SystemDriver | Where-Object {
    $_.Name -match $relevantPattern -or $_.DisplayName -match $relevantPattern -or $_.PathName -match $relevantPattern
})
Save-Json 'drivers/relevant-services.json' { $services | Select-Object Name, DisplayName, State, StartMode, PathName, ServiceType }

$binaryMetadata = [Collections.Generic.List[object]]::new()
foreach ($service in $services) {
    $candidate = [Environment]::ExpandEnvironmentVariables([string]$service.PathName).Trim('"')
    $candidate = ($candidate -split '\s+')[0].Trim('"')
    if ($candidate -match '^\\SystemRoot\\') {
        $candidate = Join-Path $env:SystemRoot $candidate.Substring(12)
    }
    $metadata = Get-FileMetadata -LiteralPath $candidate
    if ($null -ne $metadata) { $binaryMetadata.Add($metadata) }
}

$driverStore = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
if (Test-Path -LiteralPath $driverStore) {
    Get-ChildItem -LiteralPath $driverStore -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $relevantPattern } |
        ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match '^(?i)\.(sys|dll|bin|dat|fw|inf)$' } |
                ForEach-Object {
                    $metadata = Get-FileMetadata -LiteralPath $_.FullName
                    if ($null -ne $metadata) { $binaryMetadata.Add($metadata) }
                }
        }
}
Save-Json 'files/vendor-binary-metadata.json' { $binaryMetadata } 6

$infNames = @($relevantDrivers.InfName | Where-Object { $_ } | Sort-Object -Unique)
Save-Json 'drivers/relevant-inf-names.json' { $infNames }
if ($CopyInfFiles) {
    foreach ($infName in $infNames) {
        $source = Join-Path $env:SystemRoot "INF\$infName"
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $root "inf\$infName")
        }
    }
}

if ($IncludeRegistry) {
    foreach ($term in @('OV8865', 'OV5693', 'INT347A', 'INT33BE', 'DW9714', 'IPU6')) {
        Save-Text "registry/enum-$term.txt" { reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Enum' /s /f $term }
    }
    Save-Text 'registry/camera-class.txt' { reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Control\Class\{ca3e7ab9-b4c3-4ae6-8251-579ef933890f}' /s }
    Save-Text 'registry/image-class.txt' { reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Control\Class\{6bdd1fc6-810f-11d0-bec7-08002be2092f}' /s }
}

$manifest = [ordered]@{
    schemaVersion = 1
    collectedAt = (Get-Date).ToUniversalTime().ToString('o')
    collector = $PSCommandPath
    computerName = $env:COMPUTERNAME
    outputDirectory = $root
    options = [ordered]@{
        copyInfFiles = [bool]$CopyInfFiles
        includeRegistry = [bool]$IncludeRegistry
        verbosePnPProperties = [bool]$VerbosePnPProperties
    }
    relevantDeviceCount = $relevantDevices.Count
    relevantDriverCount = $relevantDrivers.Count
    errors = $errors
    notice = 'No SYS, DLL, or firmware binary is copied. files/vendor-binary-metadata.json contains metadata and SHA256 only.'
}
[IO.File]::WriteAllText((Join-Path $root 'manifest.json'), ($manifest | ConvertTo-Json -Depth 8) + "`r`n", [Text.UTF8Encoding]::new($false))

Write-Host "Collection complete. Review and redact the dump before sharing: $root"
