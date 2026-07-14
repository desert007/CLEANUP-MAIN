Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.MessageBox]::Show(
    "A critical BIOS update is currently being installed on your system. Please do not turn off or restart your computer manually. The system will automatically restart and continue the update shortly. Several background updates and bug fixes are actively being applied. Please wait patiently until the process is complete. Your data is safe.",
    "System Update in Progress",
    "OK",
    "Information"
)
