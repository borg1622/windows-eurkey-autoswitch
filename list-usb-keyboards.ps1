<#
.SYNOPSIS
    Lists Vendor ID and Product ID of all connected USB keyboards.

.DESCRIPTION
    Helper script for configuring kbd-switch.ps1. Queries present PnP devices in
    the Keyboard class, extracts VID/PID from each device's InstanceId, and resolves
    manufacturer and product names from Windows device properties. When Windows does
    not report a manufacturer, the bundled resources/usb.ids file is used as a fallback.

    Note: Bluetooth and built-in (ACPI) keyboards are not listed because they do
    not expose a USB VID/PID in their device instance ID.

.AUTHOR
    Dirk Osburg

.YEAR
    2026

.LICENSE
    GPL-3.0-only
#>

# --- Functions ---------------------------------------------------------------

function Test-GenericDeviceLabel {
    param (
        [string]$Value
    )

    if (-not $Value) {
        return $true
    }

    return $Value -match '^\(Standard|\(Standardsystemger|Standard-USB|Standardtastatur|^Standard |^Microsoft\b|^@'
}

function Get-PnpPropertyData {
    param (
        [string]$InstanceId,
        [string]$KeyName,
        [hashtable]$PropertyCache
    )

    $cacheKey = "$InstanceId|$KeyName"
    if ($PropertyCache.ContainsKey($cacheKey)) {
        return $PropertyCache[$cacheKey]
    }

    $property = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction SilentlyContinue
    $value = $null

    if ($property -and $null -ne $property.Data -and "$($property.Data)".Trim()) {
        $value = "$($property.Data)".Trim()
    }

    $PropertyCache[$cacheKey] = $value
    return $value
}

function Get-FirstMeaningfulLabel {
    param (
        [string[]]$Candidates,
        [bool]$AllowGenericFallback = $true
    )

    foreach ($candidate in $Candidates) {
        if ($candidate -and -not (Test-GenericDeviceLabel -Value $candidate)) {
            return $candidate
        }
    }

    if ($AllowGenericFallback) {
        foreach ($candidate in $Candidates) {
            if ($candidate) {
                return $candidate
            }
        }
    }

    return $null
}

<#
.SYNOPSIS
    Loads vendor and product names from a usb.ids file.

.DESCRIPTION
    Parses the standard usb.ids format from The USB ID Repository. Returns hashtables
    keyed by lowercase VID and "vid:pid" respectively.
#>
function Import-UsbIdsDatabase {
    param (
        [string]$Path
    )

    $vendors = @{}
    $products = @{}
    $currentVendor = $null

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "usb.ids not found at $Path. Manufacturer fallback is unavailable."
        return @{
            Vendors  = $vendors
            Products = $products
        }
    }

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') {
            continue
        }

        if ($line -match '^([0-9a-fA-F]{4})\s+(.+)$') {
            $currentVendor = $matches[1].ToLowerInvariant()
            $vendors[$currentVendor] = $matches[2].Trim()
            continue
        }

        if ($line -match '^\t([0-9a-fA-F]{4})\s+(.+)$' -and $currentVendor) {
            $productId = $matches[1].ToLowerInvariant()
            $products["$currentVendor`:$productId"] = $matches[2].Trim()
        }
    }

    return @{
        Vendors  = $vendors
        Products = $products
    }
}

function Get-UsbIdsManufacturer {
    param (
        [string]$LookupKey,
        [hashtable]$UsbIdsDatabase
    )

    if (-not $LookupKey -or -not $UsbIdsDatabase) {
        return $null
    }

    $vidHex = $LookupKey.Split(':')[0].ToLowerInvariant()
    if ($UsbIdsDatabase.Vendors.ContainsKey($vidHex)) {
        return $UsbIdsDatabase.Vendors[$vidHex]
    }

    return $null
}

function Get-VidPidFromInstanceId {
    param (
        [string]$InstanceId
    )

    if ($InstanceId -match 'VID_([0-9A-F]{4}).*PID_([0-9A-F]{4})') {
        return [pscustomobject]@{
            VendorId  = "VID_$($matches[1])"
            ProductId = "PID_$($matches[2])"
            LookupKey = "$($matches[1]):$($matches[2])"
        }
    }

    return $null
}

<#
.SYNOPSIS
    Reads manufacturer and product labels from the device enumeration registry.
#>
function Get-DeviceNamesFromRegistry {
    param (
        [string]$InstanceId,
        [hashtable]$RegistryCache
    )

    if ($RegistryCache.ContainsKey($InstanceId)) {
        return $RegistryCache[$InstanceId]
    }

    $result = [pscustomobject]@{
        Manufacturer = $null
        ProductName  = $null
    }

    $enumPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$InstanceId"
    if (Test-Path -LiteralPath $enumPath) {
        $props = Get-ItemProperty -LiteralPath $enumPath -ErrorAction SilentlyContinue

        $manufacturer = $props.Mfg
        $productName = $props.FriendlyName

        if (-not $productName) {
            $productName = $props.DeviceDesc
        }

        if ($manufacturer -match '^@') { $manufacturer = $null }
        if ($productName -match '^@') { $productName = $null }

        $result.Manufacturer = $manufacturer
        $result.ProductName = $productName
    }

    $RegistryCache[$InstanceId] = $result
    return $result
}

<#
.SYNOPSIS
    Resolves human-readable manufacturer and product names for a VID/PID group.

.DESCRIPTION
    Inspects all present PnP devices that share the same VID/PID, including the USB
    composite device and its HID interfaces. Windows often reports the real
    manufacturer on a driver-installed HID interface rather than on the USB parent.
#>
function Get-DeviceLabelInfo {
    param (
        [string]$LookupKey,
        [array]$RelatedDevices,
        [string]$FriendlyName,
        [hashtable]$PropertyCache,
        [hashtable]$RegistryCache,
        [hashtable]$UsbIdsDatabase
    )

    $productCandidates = @()
    $manufacturer = $null

    $usbDevice = $RelatedDevices |
        Where-Object { $_.Class -eq 'USB' } |
        Select-Object -First 1

    if ($usbDevice) {
        $productCandidates += Get-PnpPropertyData -InstanceId $usbDevice.InstanceId -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc' -PropertyCache $PropertyCache
        $usbRegistry = Get-DeviceNamesFromRegistry -InstanceId $usbDevice.InstanceId -RegistryCache $RegistryCache
        $productCandidates += $usbRegistry.ProductName
        $productCandidates += $usbDevice.FriendlyName
    }

    $sortedDevices = $RelatedDevices |
        Sort-Object @{
            Expression = {
                if ($_.FriendlyName -match '^(HID[- ]|USB )') { 1 } else { 0 }
            }
        }, FriendlyName

    foreach ($device in $sortedDevices) {
        $registryNames = Get-DeviceNamesFromRegistry -InstanceId $device.InstanceId -RegistryCache $RegistryCache

        if (-not $manufacturer) {
            $manufacturer = Get-FirstMeaningfulLabel -Candidates @(
                $registryNames.Manufacturer
                (Get-PnpPropertyData -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_Manufacturer' -PropertyCache $PropertyCache)
            ) -AllowGenericFallback $false
        }

        if (-not $productCandidates) {
            $productCandidates += @(
                (Get-PnpPropertyData -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc' -PropertyCache $PropertyCache)
                $registryNames.ProductName
                $device.FriendlyName
            )
        }
    }

    if ($FriendlyName -notmatch '^(HID[- ]|USB )') {
        $productCandidates += $FriendlyName
    }

    if (-not $manufacturer) {
        $manufacturer = Get-UsbIdsManufacturer -LookupKey $LookupKey -UsbIdsDatabase $UsbIdsDatabase
    }

    return [pscustomobject]@{
        Manufacturer = $manufacturer
        ProductName  = Get-FirstMeaningfulLabel -Candidates $productCandidates
    }
}

# --- Main --------------------------------------------------------------------

$usbIdsPath = Join-Path $PSScriptRoot 'resources\usb.ids'
$usbIdsDatabase = Import-UsbIdsDatabase -Path $usbIdsPath

$propertyCache = @{}
$registryCache = @{}

# One PnP scan: group all present devices by VID/PID for fast label resolution.
$devicesByVidPid = @{}
$presentDevices = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue

foreach ($device in $presentDevices) {
    $ids = Get-VidPidFromInstanceId -InstanceId $device.InstanceId
    if (-not $ids) {
        continue
    }

    if (-not $devicesByVidPid.ContainsKey($ids.LookupKey)) {
        $devicesByVidPid[$ids.LookupKey] = @()
    }

    $devicesByVidPid[$ids.LookupKey] += $device
}

$keyboardDevices = $presentDevices |
    Where-Object {
        $_.Class -eq 'Keyboard' -and $_.InstanceId -match 'VID_[0-9A-F]{4}.*PID_[0-9A-F]{4}'
    }

if (-not $keyboardDevices) {
    Write-Host "No USB keyboards with VID/PID found."
    exit 0
}

$results = $keyboardDevices |
    Group-Object {
        (Get-VidPidFromInstanceId -InstanceId $_.InstanceId).LookupKey
    } |
    ForEach-Object {
        $lookupKey = $_.Name
        $representativeKeyboard = $_.Group | Select-Object -First 1
        $ids = Get-VidPidFromInstanceId -InstanceId $representativeKeyboard.InstanceId
        $relatedDevices = $devicesByVidPid[$lookupKey]

        $labels = Get-DeviceLabelInfo `
            -LookupKey $lookupKey `
            -RelatedDevices $relatedDevices `
            -FriendlyName $representativeKeyboard.FriendlyName `
            -PropertyCache $propertyCache `
            -RegistryCache $registryCache `
            -UsbIdsDatabase $usbIdsDatabase

        [pscustomobject]@{
            Manufacturer = $labels.Manufacturer
            ProductName  = $labels.ProductName
            VendorId     = $ids.VendorId
            ProductId    = $ids.ProductId
            FriendlyName = $representativeKeyboard.FriendlyName
            Status       = $representativeKeyboard.Status
            InstanceId   = $representativeKeyboard.InstanceId
        }
    } |
    Sort-Object VendorId, ProductId, ProductName

$results | Format-Table Manufacturer, ProductName, VendorId, ProductId, Status -AutoSize

Write-Host "`nFor kbd-switch.json, set VendorId and ProductId. Use getActiveKbdLayout.ps1 to find KLID."
Write-Host "`nExample VendorId / ProductId:"
$results | ForEach-Object {
    $label = (@($_.Manufacturer, $_.ProductName) | Where-Object { $_ }) -join ' '
    if ($label) {
        Write-Host "# $label"
    }

    Write-Host ('  "VendorId":  "{0}",' -f $_.VendorId)
    Write-Host ('  "ProductId": "{0}"' -f $_.ProductId)
    Write-Host ""
}
