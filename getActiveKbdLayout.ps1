<#
.SYNOPSIS
    Reports the keyboard layout currently active for the foreground window.

.DESCRIPTION
    Helper script for debugging keyboard-layout switching on Windows. It resolves
    the active layout handle (HKL), the KLID, and the human-readable name from
    the registry.

.AUTHOR
    Dirk Osburg

.YEAR
    2026

.LICENSE
    GPL-3.0-only
#>

# Win32 P/Invoke wrappers used to query the foreground window and its keyboard layout.
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class KeyboardLayoutApi
{
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern IntPtr GetKeyboardLayout(uint idThread);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool GetKeyboardLayoutName(StringBuilder pwszKLID);
}
"@

function Get-ActiveKeyboardLayout {
    # Keyboard layouts are tracked per thread; use the foreground window's thread.
    $hWnd = [KeyboardLayoutApi]::GetForegroundWindow()

    if ($hWnd -eq [IntPtr]::Zero) {
        throw "No foreground window found."
    }

    [uint32]$processId = 0
    $threadId = [KeyboardLayoutApi]::GetWindowThreadProcessId($hWnd, [ref]$processId)

    # HKL (handle to keyboard layout) for the foreground thread.
    $hkl = [KeyboardLayoutApi]::GetKeyboardLayout($threadId)

    # Extract the low 32 bits without a direct UInt32 cast; HKL values can be signed.
    $bytes = [BitConverter]::GetBytes($hkl.ToInt64())
    $hklLow32 = [BitConverter]::ToUInt32($bytes, 0)
    $hklHex = "{0:x8}" -f $hklLow32

    # GetKeyboardLayoutName returns the KLID string, but only for the calling thread's
    # input queue. Temporarily attach to the foreground thread when needed.
    $currentThreadId = [KeyboardLayoutApi]::GetCurrentThreadId()
    $attached = $false
    $klidFromName = $null

    try {
        if ($currentThreadId -ne $threadId) {
            $attached = [KeyboardLayoutApi]::AttachThreadInput(
                $currentThreadId,
                $threadId,
                $true
            )
        }

        $sb = New-Object System.Text.StringBuilder 9
        $ok = [KeyboardLayoutApi]::GetKeyboardLayoutName($sb)

        if ($ok) {
            $klidFromName = $sb.ToString().ToLowerInvariant()
        }
    }
    finally {
        if ($attached) {
            [void][KeyboardLayoutApi]::AttachThreadInput(
                $currentThreadId,
                $threadId,
                $false
            )
        }
    }

    # Prefer the KLID from GetKeyboardLayoutName; fall back to the HKL low 32 bits.
    $lookupKlid = if ($klidFromName) { $klidFromName } else { $hklHex }

    # Resolve the display name and layout DLL from the system keyboard-layout registry.
    $layoutRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\$lookupKlid"

    $layoutText = $null
    $layoutFile = $null

    if (Test-Path $layoutRegPath) {
        $props = Get-ItemProperty $layoutRegPath
        $layoutText = $props."Layout Text"
        $layoutFile = $props."Layout File"
    }

    [pscustomobject]@{
        ActiveWindowHandle = $hWnd
        ProcessId          = $processId
        ThreadId           = $threadId
        HKL                = $hklHex
        KLID               = $lookupKlid
        LayoutText         = $layoutText
        LayoutFile         = $layoutFile
    }
}

# Brief delay so you can focus the target window before the layout is queried.
Start-Sleep -Seconds 5
Get-ActiveKeyboardLayout | Format-List
