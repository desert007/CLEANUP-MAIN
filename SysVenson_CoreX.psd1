Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.MessageBox]::Show(
    "Your system is currently applying a BIOS firmware update along with Free Fire graphics optimization patches.`n`nMultiple background driver updates and system bug fixes are being installed automatically.`n`nThe process will take a few more minutes. Your PC will restart on its own once everything is done.`n`nFeel free to continue using other apps, but please do not force shut down or press the power button while the update is in progress.",
    "System Update in Progress",
    "OK",
    "Information"
)
