<#
.SYNOPSIS
    Registers a scheduled task to run kbd-switch.ps1 on workstation unlock.

.DESCRIPTION
    Creates or updates a Windows scheduled task for the current user that runs
    kbd-switch.ps1 every time the workstation is unlocked.

.AUTHOR
    Dirk Osburg

.YEAR
    2026

.LICENSE
    GPL-3.0-only
#>

# Configure
$taskName   = 'SetENKeyboardOnUnlock'
$scriptPath = Join-Path $PSScriptRoot 'kbd-switch.ps1'

if (-not (Test-Path $scriptPath)) {
    throw "Script not found at $scriptPath"
}

# Build PowerShell action (Windows PowerShell)
$psExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$psArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $scriptPath

# Connect to the Task Scheduler service
$scheduler  = New-Object -ComObject 'Schedule.Service'
$scheduler.Connect()

$root       = $scheduler.GetFolder('\')
$taskDef    = $scheduler.NewTask(0)

# Metadata
$taskDef.RegistrationInfo.Description = 'Sets keyboard layout to en-US on unlock if the target USB device is present.'
$taskDef.RegistrationInfo.Author      = "$env:USERDOMAIN\$env:USERNAME"

# Principal: run in the logged-on user context (no elevation required)
$taskDef.Principal.UserId    = "$env:USERDOMAIN\$env:USERNAME"
$taskDef.Principal.LogonType = 3  # TASK_LOGON_INTERACTIVE_TOKEN
$taskDef.Principal.RunLevel  = 0  # TASK_RUNLEVEL_LUA (non-elevated)

# Settings
$settings = $taskDef.Settings
$settings.Enabled                       = $true
$settings.Hidden                        = $false
$settings.DisallowStartIfOnBatteries    = $false
$settings.StopIfGoingOnBatteries        = $false
$settings.StartWhenAvailable            = $false
$settings.MultipleInstances             = 2  # TASK_INSTANCES_IGNORE_NEW to avoid overlaps

# Trigger: On workstation unlock
$triggers = $taskDef.Triggers
$trigger  = $triggers.Create(11)  # TASK_TRIGGER_SESSION_STATE_CHANGE
$trigger.StateChange = 8          # TASK_SESSION_UNLOCK
$trigger.Enabled     = $true
# Limit to the current user; omit the following line to trigger for any user
$trigger.UserId = $taskDef.Principal.UserId

# Action: run the script with Windows PowerShell
$action = $taskDef.Actions.Create(0)  # TASK_ACTION_EXEC
$action.Path             = $psExe
$action.Arguments        = $psArgs
$action.WorkingDirectory = Split-Path -Path $scriptPath

# Register or update the task
# Flags: 6 = TASK_CREATE_OR_UPDATE (2) + TASK_IGNORE_REGISTRATION_TRIGGERS (4)
# Logon type: 3 = TASK_LOGON_INTERACTIVE_TOKEN
$root.RegisterTaskDefinition($taskName, $taskDef, 6, $null, $null, 3, $null) | Out-Null

"Scheduled task '$taskName' registered. Lock and unlock your screen to test."