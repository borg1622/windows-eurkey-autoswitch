Keyboard Layout Switch
======================

Synopsis
--------

This repository contains PowerShell scripts for Windows users who want to use an
external USB keyboard with the EurKey layout while keeping a different input
layout on the built-in keyboard (for example, German on a laptop keyboard and
EurKey on an external English keyboard).

Unlike some other operating systems, Windows does not assign a separate input
layout to each physical keyboard. When multiple keyboards are connected, all of
them share the same active layout. You can switch layouts manually (for example
with Win+Space), but Windows resets the input layout to the default after every
lock/unlock or sign-in. That makes manual switching tedious for users who only
want EurKey when their external keyboard is plugged in.

These scripts automate that step: after each workstation unlock, Windows switches
to EurKey if the configured USB keyboard is connected. If it is not connected,
the system default layout remains unchanged.


Prerequisites
-------------

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (included with Windows)
- The EurKey keyboard layout installed on your system
  (https://eurkey.steffen.net/)
- An external USB keyboard you want to use with EurKey
- Permission to create a scheduled task for your user account (no admin rights
  required for the scripts themselves)


Setup Guide
-----------

1. Install EurKey

   Download and install the EurKey layout if it is not already available in
   Windows. After installation, add it to your input languages in Settings and
   confirm that you can select it manually.

2. Verify that EurKey is available

   Run getActiveKbdLayout.ps1, switch to EurKey with Win+Space within the
   5-second delay, and check that the output shows a layout name containing
   "EurKey".

   If EurKey is missing, kbd-switch.ps1 will fail with an error when it runs.

3. Find the Vendor ID and Product ID of your external keyboard

   Connect the external USB keyboard and run:

     .\list-usb-keyboards.ps1

   Note the VendorId and ProductId of the keyboard you want to target, for
   example VID_29EA and PID_0102. The script also shows manufacturer and product
   names when Windows or the bundled usb.ids database can resolve them.

4. Configure kbd-switch.json

   Copy kbd-switch.json.example to kbd-switch.json if the file does not exist yet,
   then edit kbd-switch.json:

     VendorId        USB vendor ID from step 3, e.g. "VID_05AC"
     ProductId       USB product ID from step 3, e.g. "PID_020B"
     LanguageTag     Language under which EurKey is registered, default "de-DE"
     LayoutNameRegex Regex matched against the installed layout name, default "EurKey"

   If you have several EurKey variants installed (for example US EurKey and
   DEU EurKey), tighten LayoutNameRegex to match the one you want, e.g.:

     "LayoutNameRegex": "^DEU EurKey$"

   Save the file. To use a different file path, change the ConfigPath default at the
   top of kbd-switch.ps1 or pass -ConfigPath when running the script.

5. Test kbd-switch.ps1 manually

   With the external keyboard connected, run:

     .\kbd-switch.ps1

   The script should report that the keyboard was found, show the matched EurKey
   layout, and finish without errors. Use getActiveKbdLayout.ps1 to confirm that
   EurKey is now active.

   Disconnect the external keyboard and run kbd-switch.ps1 again. It should exit
   without making changes.

6. Register the unlock trigger

   Run once to create or update a scheduled task for the current user:

     .\register-unlock-trigger.ps1

   This registers a task that runs kbd-switch.ps1 every time you unlock the
   workstation. The script resolves paths relative to its own location, so keep
   all repository files together.

7. Verify automatic switching

   Lock Windows (Win+L), unlock again, and check the active layout with
   getActiveKbdLayout.ps1 or by typing a few test characters.

   To remove the scheduled task later, open Task Scheduler and delete the task
   named "SetENKeyboardOnUnlock", or run:

     schtasks /Delete /TN "SetENKeyboardOnUnlock" /F


Troubleshooting
---------------

- Wrong layout activated
  Check LayoutNameRegex in kbd-switch.json. A broad pattern such as "EurKey" may
  match the wrong variant if several EurKey layouts are installed.

- Script runs but layout does not change
  Confirm that $LanguageTag matches a language in your Windows language list and
  that EurKey is installed under that language. The active input language must be
  the one configured in the script for the override to apply visibly.

- Keyboard not detected
  Re-run list-usb-keyboards.ps1 and verify VendorId and ProductId. Wireless
  receivers and Bluetooth keyboards may appear with different IDs than expected.

- Task does not run on unlock
  Open Task Scheduler, find "SetENKeyboardOnUnlock", and check the last run
  result. Re-run register-unlock-trigger.ps1 after moving the repository to a
  different folder.


Repository Files
----------------

README.txt
  This documentation file. Describes the problem, setup steps, and the purpose of
  each file in the repository.

kbd-switch.ps1
  Main script. When the configured USB keyboard is present, it locates the EurKey
  layout, registers it for the current user if needed, and activates it for the
  session without changing the Windows display language.

kbd-switch.json
  Configuration file read by kbd-switch.ps1. Defines the target USB keyboard
  (VendorId, ProductId), language tag, and EurKey layout name regex.

kbd-switch.json.example
  Example configuration file. Copy to kbd-switch.json and adjust for your setup.

register-unlock-trigger.ps1
  One-time setup script that creates a Windows scheduled task to run
  kbd-switch.ps1 automatically whenever the workstation is unlocked.

list-usb-keyboards.ps1
  Helper script that lists connected USB keyboards with Vendor ID, Product ID,
  and human-readable names. Use it to find the values for kbd-switch.json.

getActiveKbdLayout.ps1
  Debugging helper that reports the keyboard layout currently active for the
  foreground window, including KLID and layout name from the registry.

resources/usb.ids
  Vendor and product name database from The USB ID Repository, used as a fallback
  when Windows does not report a manufacturer name. Distributed under GPL-3.0:
  https://github.com/usbids/usbids


License
-------

The PowerShell scripts in this repository are licensed under GPL-3.0
(see the header in each script).

The file resources/usb.ids is maintained by The USB ID Repository
(https://github.com/usbids/usbids) and is distributed under GPL-3.0:
https://github.com/usbids/usbids?tab=GPL-3.0-1-ov-file
