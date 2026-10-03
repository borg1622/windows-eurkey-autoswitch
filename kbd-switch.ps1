<#
.SYNOPSIS
    Switches the user input method to EurKey when a specific USB keyboard is connected.

.DESCRIPTION
    Intended to run at workstation unlock (via a scheduled task). Reads its settings
    from a JSON configuration file. When the configured USB keyboard is present, the
    script activates the layout identified by KLID. When the keyboard is absent, an
    optional DefaultKLID is applied instead. Layouts are resolved by KLID in the
    registry, not by display name.

.PARAMETER ConfigPath
    Path to the JSON configuration file. Defaults to kbd-switch.json next to this
    script. Change the default below or pass -ConfigPath when running the script.

.AUTHOR
    Dirk Osburg

.YEAR
    2026

.LICENSE
    GPL-3.0-only
#>

param (
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'kbd-switch.json')
)

# --- Functions ---------------------------------------------------------------

<#
.SYNOPSIS
    Loads and validates the JSON configuration file for this script.

.PARAMETER Path
    Path to kbd-switch.json.

.OUTPUTS
    PSCustomObject with VendorId, ProductId, LanguageTag, KLID, and optional DefaultKLID.
#>
function Normalize-KlidConfigValue {
    param (
        [string]$Value,
        [string]$ConfigKey,
        [string]$ConfigPath
    )

    $trimmed = "$Value".Trim()
    if ($trimmed -notmatch '^[0-9a-fA-F]{8}$') {
        throw "Invalid $ConfigKey '$trimmed' in '$ConfigPath': expected 8 hexadecimal characters."
    }

    return $trimmed.ToLowerInvariant()
}

function Import-KbdSwitchConfig {
    param (
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }

    try {
        $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse configuration file '$Path': $($_.Exception.Message)"
    }

    $requiredKeys = @('VendorId', 'ProductId', 'LanguageTag', 'KLID')
    $missingKeys = $requiredKeys | Where-Object {
        -not $config.$_ -or "$($config.$_)".Trim().Length -eq 0
    }

    if ($missingKeys) {
        throw "Missing required configuration key(s) in '$Path': $($missingKeys -join ', ')"
    }

    $defaultKlid = $null
    if ($config.PSObject.Properties.Name -contains 'DefaultKLID' -and "$($config.DefaultKLID)".Trim()) {
        $defaultKlid = Normalize-KlidConfigValue -Value $config.DefaultKLID -ConfigKey 'DefaultKLID' -ConfigPath $Path
    }

    return [pscustomobject]@{
        VendorId     = "$($config.VendorId)".Trim()
        ProductId    = "$($config.ProductId)".Trim()
        LanguageTag  = "$($config.LanguageTag)".Trim()
        KLID         = Normalize-KlidConfigValue -Value $config.KLID -ConfigKey 'KLID' -ConfigPath $Path
        DefaultKLID  = $defaultKlid
    }
}

<#
.SYNOPSIS
    Checks whether a USB device with the given vendor and product ID is connected.

.DESCRIPTION
    Queries present PnP devices and matches their InstanceId against a pattern built
    from the supplied VID and PID strings. Returns true as soon as at least one
    matching device is found.

.PARAMETER VendorId
    USB vendor ID prefix, e.g. "VID_29EA".

.PARAMETER ProductId
    USB product ID prefix, e.g. "PID_0102".

.OUTPUTS
    System.Boolean
#>
function Test-UsbKeyboardPresent {
    param (
        [string]$VendorId,
        [string]$ProductId
    )

    $pattern = "$([regex]::Escape($VendorId)).*$([regex]::Escape($ProductId))"

    $devices = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InstanceId -match $pattern
        }

    return [bool]$devices
}

<#
.SYNOPSIS
    Finds an installed keyboard layout by its KLID.

.DESCRIPTION
    Looks up HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\<KLID> and returns
    the layout metadata if the layout is installed.

.PARAMETER KLID
    Eight-character keyboard layout identifier, e.g. "a0010409".

.OUTPUTS
    PSCustomObject with KLID, LayoutText, and LayoutFile properties, or $null.
#>
function Get-KeyboardLayoutByKLID {
    param (
        [string]$KLID
    )

    $lookupKlid = $KLID.ToLowerInvariant()
    $layoutRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\$lookupKlid"

    if (-not (Test-Path -LiteralPath $layoutRegPath)) {
        return $null
    }

    $props = Get-ItemProperty -LiteralPath $layoutRegPath

    return [pscustomobject]@{
        KLID       = $lookupKlid
        LayoutText = $props."Layout Text"
        LayoutFile = $props."Layout File"
    }
}

function Get-InputTipKlid {
    param (
        [string]$InputMethodTip
    )

    if ($InputMethodTip -match ':([0-9a-fA-F]{8})$') {
        return $matches[1].ToLowerInvariant()
    }

    return $null
}

<#
.SYNOPSIS
    Keeps keyboard layouts under one language and removes managed layouts elsewhere.

.DESCRIPTION
    Removes the configured layouts, and all layouts sharing their layout DLL (e.g. the
    US variant of EurKey), from non-target languages such as en-US. Limits the target
    language to AllowedKlids only and moves it to the front of the user language list.
#>
function Sync-UserInputLanguages {
    param (
        [string]$LanguageTag,
        [string[]]$AllowedKlids
    )

    $culture = [System.Globalization.CultureInfo]::GetCultureInfo($LanguageTag)
    $languageId = "{0:x4}" -f $culture.LCID

    $managedKlids = @{}
    foreach ($klid in $AllowedKlids) {
        $managedKlids[$klid.ToLowerInvariant()] = $true
    }

    $layoutFiles = $AllowedKlids |
        ForEach-Object { (Get-KeyboardLayoutByKLID -KLID $_).LayoutFile } |
        Where-Object { $_ }

    Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts" | ForEach-Object {
        $layoutFile = (Get-ItemProperty $_.PSPath)."Layout File"
        if ($layoutFile -and $layoutFiles -contains $layoutFile) {
            $managedKlids[$_.PSChildName.ToLowerInvariant()] = $true
        }
    }

    $allowedTips = $AllowedKlids |
        ForEach-Object { "$languageId`:$($_.ToLowerInvariant())" } |
        Select-Object -Unique

    $languageList = Get-WinUserLanguageList
    $languageChanged = $false

    $targetLanguage = $languageList |
        Where-Object { $_.LanguageTag -eq $LanguageTag } |
        Select-Object -First 1

    if (-not $targetLanguage) {
        Write-Host "Language $LanguageTag is not in the user language list yet. Adding it."
        $newLanguage = (New-WinUserLanguageList $LanguageTag)[0]
        $languageList.Add($newLanguage)
        $targetLanguage = $newLanguage
        $languageChanged = $true
    }

    foreach ($language in $languageList) {
        foreach ($tip in @($language.InputMethodTips)) {
            $tipKlid = Get-InputTipKlid -InputMethodTip $tip

            if (-not $tipKlid) {
                continue
            }

            if ($language.LanguageTag -ne $LanguageTag) {
                if ($managedKlids.ContainsKey($tipKlid)) {
                    Write-Host "Removing input method $tip from $($language.LanguageTag)."
                    [void]$language.InputMethodTips.Remove($tip)
                    $languageChanged = $true
                }

                continue
            }

            if ($allowedTips -notcontains $tip) {
                Write-Host "Removing input method $tip from $LanguageTag."
                [void]$language.InputMethodTips.Remove($tip)
                $languageChanged = $true
            }
        }
    }

    foreach ($tip in $allowedTips) {
        if ($targetLanguage.InputMethodTips -notcontains $tip) {
            Write-Host "Adding input method $tip to $LanguageTag."
            [void]$targetLanguage.InputMethodTips.Add($tip)
            $languageChanged = $true
        }
    }

    $targetEntry = $languageList |
        Where-Object { $_.LanguageTag -eq $LanguageTag } |
        Select-Object -First 1

    $otherEntries = $languageList |
        Where-Object { $_.LanguageTag -ne $LanguageTag }

    $reorderedList = @()
    if ($targetEntry) {
        $reorderedList += $targetEntry
    }
    $reorderedList += $otherEntries

    if ($languageChanged -or ($languageList[0].LanguageTag -ne $LanguageTag)) {
        Set-WinUserLanguageList $reorderedList -Force
    }
}

Add-Type -ErrorAction SilentlyContinue -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class KeyboardLayoutNative {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr LoadKeyboardLayout(string pwszKLID, uint Flags);

    [DllImport("user32.dll")]
    public static extern bool UnloadKeyboardLayout(IntPtr hkl);

    [DllImport("user32.dll")]
    public static extern int GetKeyboardLayoutList(int nBuff, [Out] IntPtr[] lpList);

    [DllImport("user32.dll")]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, ref IntPtr pvParam, uint fWinIni);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint Msg,
        UIntPtr wParam,
        IntPtr lParam,
        uint fuFlags,
        uint uTimeout,
        out UIntPtr lpdwResult
    );
}
"@

<#
.SYNOPSIS
    Lists the keyboard layouts (HKLs) currently loaded in the session.

.DESCRIPTION
    These are the entries shown in the taskbar language switcher. Value holds the low
    32 bits of the HKL: low word = input language, high word = layout.
#>
function Get-LoadedKeyboardLayouts {
    $count = [KeyboardLayoutNative]::GetKeyboardLayoutList(0, $null)
    if ($count -le 0) {
        return @()
    }

    $handles = New-Object IntPtr[] $count
    [void][KeyboardLayoutNative]::GetKeyboardLayoutList($count, $handles)

    foreach ($handle in $handles) {
        [pscustomobject]@{
            Handle = $handle
            Value  = [BitConverter]::ToUInt32([BitConverter]::GetBytes($handle.ToInt64()), 0)
        }
    }
}

<#
.SYNOPSIS
    Computes the HKL value Windows uses for a KLID under a given input language.

.DESCRIPTION
    The low word is the input language (e.g. 0x0407). The high word is 0xF000 combined
    with the layout's "Layout Id" for variant layouts such as EurKey (a0010409 -> f0c1),
    otherwise the low word of the KLID (00000407 -> 0407).
#>
function Get-ExpectedHklValue {
    param (
        [string]$LanguageId,
        [string]$KLID
    )

    $props = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\$KLID"

    if ($props."Layout Id") {
        $layoutWord = 0xF000 -bor [Convert]::ToUInt32($props."Layout Id", 16)
    }
    else {
        $layoutWord = [Convert]::ToUInt32($KLID.Substring(4), 16)
    }

    return [uint32]([uint64]$layoutWord * 0x10000 + [Convert]::ToUInt32($LanguageId, 16))
}

<#
.SYNOPSIS
    Returns the name to pass to LoadKeyboardLayout so the layout loads under LanguageId.

.DESCRIPTION
    LoadKeyboardLayout derives the input language from the last four digits of the
    name, so "a0010409" would load EurKey under English. When the KLID belongs to a
    different language, Windows registers a substitute (e.g. d0010407 -> a0010409) in
    HKCU\Keyboard Layout\Substitutes; that substitute name loads it under LanguageId.
#>
function Get-KeyboardLayoutLoadName {
    param (
        [string]$LanguageId,
        [string]$KLID
    )

    if ($KLID.Substring(4) -eq $LanguageId) {
        return $KLID
    }

    $substitutes = Get-ItemProperty -LiteralPath 'HKCU:\Keyboard Layout\Substitutes' -ErrorAction SilentlyContinue
    if (-not $substitutes) {
        return $null
    }

    foreach ($property in $substitutes.PSObject.Properties) {
        if ($property.Name -match '^[0-9a-fA-F]{8}$' -and
            $property.Name.Substring(4) -eq $LanguageId -and
            "$($property.Value)" -eq $KLID) {
            return $property.Name.ToLowerInvariant()
        }
    }

    return $null
}

<#
.SYNOPSIS
    Registers and activates a keyboard layout for the current user.

.DESCRIPTION
    Performs four steps to make the layout available and active:

    1. Language list - Syncs keyboards under the configured language only (e.g. de-DE
       with German + EurKey), removes those layouts from other languages, and puts the
       target language first in the list.

    2. Default override - Calls Set-WinDefaultInputMethodOverride so the chosen layout
       becomes the default input method. This does not change the Windows display
       language or system locale.

    3. Session activation - Finds or loads the HKL for the layout under the target
       language, sets it as default input language, and broadcasts
       WM_INPUTLANGCHANGEREQUEST so all top-level windows switch.

    4. Session cleanup - Unloads HKLs whose input language is no longer in the user
       language list (e.g. leftover "ENG EurKey" entries in the taskbar).

.PARAMETER LanguageTag
    BCP 47 language tag, e.g. "de-DE".

.PARAMETER ActiveKLID
    KLID to activate for the current session.

.PARAMETER AllowedKlids
    KLIDs registered only under LanguageTag (e.g. German standard and DEU EurKey).
#>
function Set-InputMethod {
    param (
        [string]$LanguageTag,
        [string]$ActiveKLID,
        [string[]]$AllowedKlids
    )

    $culture = [System.Globalization.CultureInfo]::GetCultureInfo($LanguageTag)

    # LCID as four-digit hex, e.g. 1031 (de-DE) -> "0407".
    $languageId = "{0:x4}" -f $culture.LCID
    $activeKlid = $ActiveKLID.ToLowerInvariant()

    # InputMethodTip format: <language LCID>:<layout KLID>
    $inputTip = "$languageId`:$activeKlid"

    Write-Host "Setting input method to: $inputTip"

    Sync-UserInputLanguages -LanguageTag $LanguageTag -AllowedKlids $AllowedKlids

    Set-WinDefaultInputMethodOverride -InputTip $inputTip

    $KLF_ACTIVATE = 0x00000001
    $SPI_SETDEFAULTINPUTLANG = 0x005A
    $WM_INPUTLANGCHANGEREQUEST = 0x0050
    $HWND_BROADCAST = [IntPtr]0xffff
    $SMTO_ABORTIFHUNG = 0x0002

    $expectedHkl = Get-ExpectedHklValue -LanguageId $languageId -KLID $activeKlid

    $target = Get-LoadedKeyboardLayouts |
        Where-Object { $_.Value -eq $expectedHkl } |
        Select-Object -First 1

    if (-not $target) {
        $loadName = Get-KeyboardLayoutLoadName -LanguageId $languageId -KLID $activeKlid

        if (-not $loadName) {
            Write-Warning "No substitute found to load $activeKlid under $LanguageTag. Sign out and back in once, then run the script again."
            return
        }

        [void][KeyboardLayoutNative]::LoadKeyboardLayout($loadName, $KLF_ACTIVATE)

        $target = Get-LoadedKeyboardLayouts |
            Where-Object { $_.Value -eq $expectedHkl } |
            Select-Object -First 1

        if (-not $target) {
            Write-Warning ("Could not load layout {0:x8} for {1}." -f $expectedHkl, $inputTip)
            return
        }
    }

    Write-Host ("Activating HKL {0:x8}." -f $target.Value)

    $hkl = $target.Handle

    [void][KeyboardLayoutNative]::SystemParametersInfo(
        $SPI_SETDEFAULTINPUTLANG,
        0,
        [ref]$hkl,
        0
    )

    [UIntPtr]$result = [UIntPtr]::Zero

    [void][KeyboardLayoutNative]::SendMessageTimeout(
        $HWND_BROADCAST,
        $WM_INPUTLANGCHANGEREQUEST,
        [UIntPtr]::Zero,
        $hkl,
        $SMTO_ABORTIFHUNG,
        5000,
        [ref]$result
    )

    $userLanguageIds = @{}
    foreach ($language in Get-WinUserLanguageList) {
        foreach ($tip in $language.InputMethodTips) {
            if ($tip -match '^([0-9a-fA-F]{4}):') {
                $userLanguageIds[[Convert]::ToUInt32($matches[1], 16)] = $true
            }
        }
    }

    foreach ($loaded in Get-LoadedKeyboardLayouts) {
        $loadedLanguageId = $loaded.Value -band 0xFFFF

        if (-not $userLanguageIds.ContainsKey([uint32]$loadedLanguageId)) {
            if ([KeyboardLayoutNative]::UnloadKeyboardLayout($loaded.Handle)) {
                Write-Host ("Unloaded stale layout {0:x8}." -f $loaded.Value)
            }
            else {
                Write-Warning ("Could not unload stale layout {0:x8}; it disappears after the next sign-in." -f $loaded.Value)
            }
        }
    }
}

# --- Main --------------------------------------------------------------------

$config = Import-KbdSwitchConfig -Path $ConfigPath

$VendorId = $config.VendorId
$ProductId = $config.ProductId
$LanguageTag = $config.LanguageTag

Write-Host "Checking for keyboard $VendorId / $ProductId ..."

$keyboardPresent = Test-UsbKeyboardPresent -VendorId $VendorId -ProductId $ProductId
$targetKlid = $null

if ($keyboardPresent) {
    Write-Host "Keyboard found."
    $targetKlid = $config.KLID
}
else {
    Write-Host "Target keyboard is not connected."
    if ($config.DefaultKLID) {
        Write-Host "Applying default layout KLID $($config.DefaultKLID)."
        $targetKlid = $config.DefaultKLID
    }
    else {
        Write-Host "No DefaultKLID configured. No changes made."
        exit 0
    }
}

$layout = Get-KeyboardLayoutByKLID -KLID $targetKlid

if (-not $layout) {
    Write-Error "No installed keyboard layout with KLID '$targetKlid' was found."
    exit 1
}

Write-Host "Found layout:"
Write-Host "  Name: $($layout.LayoutText)"
Write-Host "  KLID: $($layout.KLID)"
Write-Host "  File: $($layout.LayoutFile)"

$allowedKlids = @($config.KLID)
if ($config.DefaultKLID) {
    $allowedKlids += $config.DefaultKLID
}
$allowedKlids = $allowedKlids | Select-Object -Unique

Set-InputMethod -LanguageTag $LanguageTag -ActiveKLID $layout.KLID -AllowedKlids $allowedKlids

Write-Host "Done."
