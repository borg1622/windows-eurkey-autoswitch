<#
.SYNOPSIS
    Switches the user input method to EurKey when a specific USB keyboard is connected.

.DESCRIPTION
    Intended to run at workstation unlock (via a scheduled task). Reads its settings
    from a JSON configuration file. When the configured USB keyboard is present, the
    script locates the installed EurKey layout in the registry, registers it under the
    user's language list if needed, and activates it for the current session without
    changing the Windows display language.

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
    PSCustomObject with VendorId, ProductId, LanguageTag, and LayoutNameRegex.
#>
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

    $requiredKeys = @('VendorId', 'ProductId', 'LanguageTag', 'LayoutNameRegex')
    $missingKeys = $requiredKeys | Where-Object {
        -not $config.$_ -or "$($config.$_)".Trim().Length -eq 0
    }

    if ($missingKeys) {
        throw "Missing required configuration key(s) in '$Path': $($missingKeys -join ', ')"
    }

    return [pscustomobject]@{
        VendorId        = "$($config.VendorId)".Trim()
        ProductId       = "$($config.ProductId)".Trim()
        LanguageTag     = "$($config.LanguageTag)".Trim()
        LayoutNameRegex = "$($config.LayoutNameRegex)".Trim()
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
    Finds an installed keyboard layout by its display name.

.DESCRIPTION
    Enumerates all layouts under HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts
    and returns the first entry whose "Layout Text" matches the given regex. The result
    includes the KLID (registry key name), human-readable name, and layout DLL file name.

.PARAMETER NameRegex
    Regular expression applied to the layout's "Layout Text" value.

.OUTPUTS
    PSCustomObject with KLID, LayoutText, and LayoutFile properties, or $null.
#>
function Get-KeyboardLayoutByName {
    param (
        [string]$NameRegex
    )

    $keyboardLayoutsPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts"

    $layouts = Get-ChildItem $keyboardLayoutsPath | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath

        [pscustomobject]@{
            KLID       = $_.PSChildName
            LayoutText = $props."Layout Text"
            LayoutFile = $props."Layout File"
        }
    }

    $layout = $layouts |
        Where-Object { $_.LayoutText -match $NameRegex } |
        Select-Object -First 1

    return $layout
}

<#
.SYNOPSIS
    Registers and activates a keyboard layout for the current user.

.DESCRIPTION
    Performs three steps to make the layout available and active:

    1. Language list  – Ensures the target language (e.g. de-DE) exists in the user's
       language list and adds the keyboard layout as an InputMethodTip if missing.
       An InputMethodTip has the form "<LCID>:<KLID>", e.g. "0407:a0000407".

    2. Default override – Calls Set-WinDefaultInputMethodOverride so the chosen layout
       becomes the default input method for that language. This does not change the
       Windows display language or system locale.

    3. Session activation – Uses Win32 APIs to load the layout immediately in the
       current session: LoadKeyboardLayout loads the HKL, SystemParametersInfo sets
       the default input language, and a broadcast WM_INPUTLANGCHANGEREQUEST notifies
       all top-level windows to switch.

.PARAMETER LanguageTag
    BCP 47 language tag, e.g. "de-DE".

.PARAMETER KLID
    Eight-character keyboard layout identifier from the registry, e.g. "00000407".
#>
function Set-InputMethod {
    param (
        [string]$LanguageTag,
        [string]$KLID
    )

    $culture = [System.Globalization.CultureInfo]::GetCultureInfo($LanguageTag)

    # LCID as four-digit hex, e.g. 1031 (de-DE) -> "0407".
    $languageId = "{0:x4}" -f $culture.LCID

    # InputMethodTip format: <language LCID>:<layout KLID>
    $inputTip = "$languageId`:$KLID"

    Write-Host "Setting input method to: $inputTip"

    $languageList = Get-WinUserLanguageList

    $language = $languageList |
        Where-Object { $_.LanguageTag -eq $LanguageTag } |
        Select-Object -First 1

    if (-not $language) {
        Write-Host "Language $LanguageTag is not in the user language list yet. Adding it."
        $newList = New-WinUserLanguageList $LanguageTag
        $languageList.Add($newList[0])
        $language = $languageList |
            Where-Object { $_.LanguageTag -eq $LanguageTag } |
            Select-Object -First 1
    }

    if ($language.InputMethodTips -notcontains $inputTip) {
        Write-Host "Adding input method $inputTip to the language list."
        [void]$language.InputMethodTips.Add($inputTip)
        Set-WinUserLanguageList $languageList -Force
    }

    Set-WinDefaultInputMethodOverride -InputTip $inputTip

    # Win32 P/Invoke to activate the layout in the current session immediately.
    Add-Type -ErrorAction SilentlyContinue -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class KeyboardLayoutNative {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr LoadKeyboardLayout(string pwszKLID, uint Flags);

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

    $KLF_ACTIVATE = 0x00000001
    $SPI_SETDEFAULTINPUTLANG = 0x005A
    $WM_INPUTLANGCHANGEREQUEST = 0x0050
    $HWND_BROADCAST = [IntPtr]0xffff
    $SMTO_ABORTIFHUNG = 0x0002

    [IntPtr]$hkl = [KeyboardLayoutNative]::LoadKeyboardLayout($KLID, $KLF_ACTIVATE)

    if ($hkl -ne [IntPtr]::Zero) {
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
    }
}

# --- Main --------------------------------------------------------------------

$config = Import-KbdSwitchConfig -Path $ConfigPath

$VendorId = $config.VendorId
$ProductId = $config.ProductId
$LanguageTag = $config.LanguageTag
$LayoutNameRegex = $config.LayoutNameRegex

Write-Host "Checking for keyboard $VendorId / $ProductId ..."

if (-not (Test-UsbKeyboardPresent -VendorId $VendorId -ProductId $ProductId)) {
    Write-Host "Target keyboard is not connected. No changes made."
    exit 0
}

Write-Host "Keyboard found."

$layout = Get-KeyboardLayoutByName -NameRegex $LayoutNameRegex

if (-not $layout) {
    Write-Error "No installed keyboard layout matching '$LayoutNameRegex' was found. Is EurKey installed?"
    exit 1
}

Write-Host "Found layout:"
Write-Host "  Name: $($layout.LayoutText)"
Write-Host "  KLID: $($layout.KLID)"
Write-Host "  File: $($layout.LayoutFile)"

Set-InputMethod -LanguageTag $LanguageTag -KLID $layout.KLID

Write-Host "Done."
