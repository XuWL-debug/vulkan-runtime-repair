<#
.SYNOPSIS
    Detect and repair a missing or broken Windows Vulkan runtime.

.DESCRIPTION
    A number of games report "graphics driver version is too low" when the
    check that actually failed is their Vulkan boot check. GPU driver packages
    ship a Vulkan loader and ICD manifests, but those components sometimes
    never land in the system: incomplete installs, cleanup utilities, driver
    rollbacks, Windows Update replacing a vendor driver, and so on. Updating
    the driver again (or spoofing version numbers in the registry) does not
    help because the driver itself is fine.

    This script is vendor-, GPU- and game-agnostic. It:

      * scans the Windows DriverStore for any Vulkan ICD manifest
        (AMD / NVIDIA / Intel / anything using the standard json format)
        and for a matching loader that exports vkCreateInstance;
      * checks whether the system loader (vulkan-1.dll) and the Khronos ICD
        registry entries are present and valid;
      * probes the real Vulkan API through an embedded C# P/Invoke helper
        (no Python, no Vulkan SDK, no third-party tool);
      * restores the loader and registers the ICD manifests;
      * records every change so -Mode Undo can revert exactly what it did.

    Nothing is hard-coded: no drive letters, no user names, no GPU model,
    no game path, no vendor-specific file names. Paths are derived from
    %WINDIR%, the registry, and the actual contents of the DriverStore.

.PARAMETER Mode
    Diagnose (default, read-only, no admin) : report state and probe Vulkan
    Verify   (read-only, no admin)          : just run the Vulkan API probe
    Fix      (admin)                        : restore loader + register ICDs
    Undo     (admin)                        : revert changes made by Fix

.PARAMETER DriverPackagePath
    Optional explicit DriverStore package directory to use instead of scanning.

.PARAMETER Force
    Replace an existing system loader. The original is backed up first and
    restored by Undo.

.PARAMETER PruneInvalidIcd
    Remove ICD registry entries whose json manifest no longer exists.
    Removed entries are recorded and restored by Undo.

.PARAMETER LogPath
    Optional file to append a plain-text log to.

.PARAMETER StatePath
    Optional path for the undo state file. Defaults to a file next to this
    script. Keep it if you want to be able to undo later.

.EXAMPLE
    .\Repair-VulkanRuntime.ps1 -Mode Diagnose

.EXAMPLE
    .\Repair-VulkanRuntime.ps1 -Mode Fix -PruneInvalidIcd

.EXAMPLE
    .\Repair-VulkanRuntime.ps1 -Mode Undo

.NOTES
    Requires Windows PowerShell 5.1 or PowerShell 7 on Windows.
    Fix and Undo require an elevated session. Always run Diagnose first.
#>
[CmdletBinding()]
param(
    [ValidateSet('Diagnose','Verify','Fix','Undo')]
    [string]$Mode = 'Diagnose',
    [string]$DriverPackagePath,
    [switch]$Force,
    [switch]$PruneInvalidIcd,
    [string]$LogPath,
    [string]$StatePath
)

$ErrorActionPreference = 'Stop'
$script:LogFile = $LogPath

if ([string]::IsNullOrEmpty($StatePath)) {
    $StatePath = Join-Path (Split-Path -Parent $PSCommandPath) 'vulkan-repair-state.json'
}

function Say {
    param([string]$Message)
    Write-Host $Message
    if (-not [string]::IsNullOrEmpty($script:LogFile)) {
        try { Add-Content -Path $script:LogFile -Value $Message -Encoding UTF8 } catch { }
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Embedded Vulkan probe. Loads the loader dynamically (so it works both with
# the system loader and with a loader still inside a DriverStore package) and
# calls the API through function pointers. No external dependencies.
# ---------------------------------------------------------------------------
$ProbeSource = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class VkRuntimeProbe
{
    [StructLayout(LayoutKind.Sequential)]
    private struct InstanceCreateInfo
    {
        public uint sType;
        public IntPtr pNext;
        public uint flags;
        public IntPtr pApplicationInfo;
        public uint enabledLayerCount;
        public IntPtr ppEnabledLayerNames;
        public uint enabledExtensionCount;
        public IntPtr ppEnabledExtensionNames;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int FnCreate(ref InstanceCreateInfo info, IntPtr alloc, out IntPtr instance);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int FnEnumerate(IntPtr instance, ref uint count, IntPtr[] devices);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void FnGetProps(IntPtr device, [Out] byte[] props);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void FnDestroy(IntPtr instance, IntPtr alloc);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibrary(string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    private static extern IntPtr GetProcAddress(IntPtr module, string name);

    private static T Bind<T>(IntPtr module, string name) where T : class
    {
        IntPtr p = GetProcAddress(module, name);
        if (p == IntPtr.Zero) throw new Exception("Missing export " + name);
        return (T)(object)Marshal.GetDelegateForFunctionPointer(p, typeof(T));
    }

    // Pure file parsing: a 64-bit process cannot LoadLibrary a 32-bit DLL,
    // so checking exports by loading would silently miss 32-bit loaders.
    public static bool HasExportInFile(string path, string exportName)
    {
        try
        {
            byte[] d = File.ReadAllBytes(path);
            if (d.Length < 0x100) return false;
            int pe = BitConverter.ToInt32(d, 0x3C);
            if (pe <= 0 || pe + 26 > d.Length) return false;
            if (BitConverter.ToUInt32(d, pe) != 0x00004550) return false;

            ushort magic = BitConverter.ToUInt16(d, pe + 24);
            int sections = BitConverter.ToUInt16(d, pe + 6);
            int optSize = BitConverter.ToUInt16(d, pe + 20);
            int opt = pe + 24;
            int exportRvaOff = (magic == 0x20B) ? opt + 112 : opt + 96;
            if (exportRvaOff + 4 > d.Length) return false;
            uint exportRva = BitConverter.ToUInt32(d, exportRvaOff);
            if (exportRva == 0) return false;

            int secTable = opt + optSize;
            uint[] va = new uint[sections];
            uint[] vsz = new uint[sections];
            uint[] raw = new uint[sections];
            for (int i = 0; i < sections; i++)
            {
                int s = secTable + i * 40;
                if (s + 40 > d.Length) return false;
                vsz[i] = BitConverter.ToUInt32(d, s + 8);
                va[i] = BitConverter.ToUInt32(d, s + 12);
                raw[i] = BitConverter.ToUInt32(d, s + 20);
            }

            Func<uint, int> rva2off = delegate(uint r)
            {
                for (int i = 0; i < sections; i++)
                {
                    long start = va[i];
                    long end = start + Math.Max((long)vsz[i], 1L);
                    if (r >= start && r < end) return (int)((long)raw[i] + (r - start));
                }
                return -1;
            };

            int ed = rva2off(exportRva);
            if (ed < 0 || ed + 40 > d.Length) return false;
            uint names = BitConverter.ToUInt32(d, ed + 24);
            uint namesRva = BitConverter.ToUInt32(d, ed + 32);
            int no = rva2off(namesRva);
            if (no < 0) return false;

            for (uint i = 0; i < names; i++)
            {
                int pos = no + (int)i * 4;
                if (pos + 4 > d.Length) break;
                uint nameRva = BitConverter.ToUInt32(d, pos);
                int p = rva2off(nameRva);
                if (p < 0 || p >= d.Length) continue;
                int end = p;
                while (end < d.Length && d[end] != 0) end++;
                if (Encoding.ASCII.GetString(d, p, end - p) == exportName) return true;
            }
            return false;
        }
        catch { return false; }
    }

    // 0 = unknown, 32 = x86, 64 = x64. Reads the PE header only.
    public static int GetBitness(string path)
    {
        try
        {
            byte[] h = new byte[512];
            using (FileStream fs = File.OpenRead(path))
            {
                int read = fs.Read(h, 0, h.Length);
                if (read < 0x44) return 0;
            }
            int pe = BitConverter.ToInt32(h, 0x3C);
            if (pe <= 0 || pe + 6 > h.Length) return 0;
            if (BitConverter.ToUInt32(h, pe) != 0x00004550) return 0; // "PE\0\0"
            ushort machine = BitConverter.ToUInt16(h, pe + 4);
            if (machine == 0x8664) return 64;
            if (machine == 0x014C) return 32;
            return 0;
        }
        catch { return 0; }
    }

    public static string Probe(string loaderPath, string icdJson)
    {
        if (!string.IsNullOrEmpty(icdJson))
            Environment.SetEnvironmentVariable("VK_ICD_FILENAMES", icdJson);
        else
            Environment.SetEnvironmentVariable("VK_ICD_FILENAMES", null);

        string target = string.IsNullOrEmpty(loaderPath) ? "vulkan-1.dll" : loaderPath;
        IntPtr module = LoadLibrary(target);
        if (module == IntPtr.Zero)
            return "ERROR|loader unavailable (" + target + ")|" + Marshal.GetLastWin32Error();

        try
        {
            FnCreate create = Bind<FnCreate>(module, "vkCreateInstance");
            FnEnumerate enumerate = Bind<FnEnumerate>(module, "vkEnumeratePhysicalDevices");
            FnGetProps getProps = Bind<FnGetProps>(module, "vkGetPhysicalDeviceProperties");
            FnDestroy destroy = Bind<FnDestroy>(module, "vkDestroyInstance");

            InstanceCreateInfo info = new InstanceCreateInfo();
            // sType 0 == VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
            IntPtr instance;
            int r = create(ref info, IntPtr.Zero, out instance);
            if (r != 0) return "ERROR|vkCreateInstance failed|" + r;

            try
            {
                uint count = 0;
                r = enumerate(instance, ref count, null);
                if (r != 0) return "ERROR|vkEnumeratePhysicalDevices failed|" + r;
                if (count == 0) return "ERROR|no Vulkan physical devices|0";

                IntPtr[] devices = new IntPtr[count];
                r = enumerate(instance, ref count, devices);
                if (r != 0) return "ERROR|device enumeration failed|" + r;

                byte[] props = new byte[2048];
                getProps(devices[0], props);
                uint api = BitConverter.ToUInt32(props, 0);
                uint driver = BitConverter.ToUInt32(props, 4);
                uint vendor = BitConverter.ToUInt32(props, 8);
                string name = Encoding.UTF8.GetString(props, 20, 256).Split('\0')[0];
                string apiText = (api >> 22) + "." + ((api >> 12) & 0x3FF) + "." + (api & 0xFFF);
                return "OK|" + name + "|" + apiText + "|" + driver + "|" + vendor + "|" + count;
            }
            finally { destroy(instance, IntPtr.Zero); }
        }
        catch (Exception e)
        {
            return "ERROR|" + e.Message.Replace('|', ' ') + "|0";
        }
    }
}
'@

if (-not ('VkRuntimeProbe' -as [type])) {
    try { Add-Type -TypeDefinition $ProbeSource -ErrorAction Stop }
    catch { Say ('FATAL: could not compile the Vulkan probe: ' + $_.Exception.Message); exit 2 }
}

# ---------------------------------------------------------------------------
# Paths and registry locations
# ---------------------------------------------------------------------------
$Is64BitOS   = [Environment]::Is64BitOperatingSystem
$SysDir64    = Join-Path $env:WINDIR 'System32'
$SysDir32    = Join-Path $env:WINDIR 'SysWOW64'
$LoaderFile  = 'vulkan-1.dll'
$Dest64      = Join-Path $SysDir64 $LoaderFile
$Dest32      = Join-Path $SysDir32 $LoaderFile
$Key64       = 'HKLM:\SOFTWARE\Khronos\Vulkan\Drivers'
$Key32       = 'HKLM:\SOFTWARE\WOW6432Node\Khronos\Vulkan\Drivers'
$RepoRoot    = Join-Path $env:WINDIR 'System32\DriverStore\FileRepository'

function Get-IcdValueNames {
    param([string]$Key)
    if (-not (Test-Path $Key)) { return @() }
    $props = Get-ItemProperty -Path $Key -ErrorAction SilentlyContinue
    if (-not $props) { return @() }
    return @($props.PSObject.Properties |
             Where-Object { $_.Name -notlike 'PS*' } |
             Select-Object -ExpandProperty Name)
}

function Format-Probe {
    param([string]$Result, [string]$Label)
    $parts = $Result -split '\|'
    if ($parts[0] -eq 'OK') {
        Say ('  [' + $Label + '] OK: ' + $parts[1] +
             ' | Vulkan API ' + $parts[2] +
             ' | driverVersion ' + $parts[3] +
             ' | vendorID 0x' + ('{0:X}' -f [uint32]$parts[4]) +
             ' | devices ' + $parts[5])
        return $true
    }
    Say ('  [' + $Label + '] FAILED: ' + $parts[1] + ' (' + $parts[2] + ')')
    return $false
}

function Invoke-SystemProbe {
    param([string]$Label = 'system')
    return (Format-Probe -Result ([VkRuntimeProbe]::Probe('', '')) -Label $Label)
}

# ---------------------------------------------------------------------------
# Verify: quick, read-only, no admin required
# ---------------------------------------------------------------------------
if ($Mode -eq 'Verify') {
    Say '=== Vulkan API probe (system loader) ==='
    if (Invoke-SystemProbe -Label 'system') { exit 0 }
    exit 3
}

# ---------------------------------------------------------------------------
# Discover ICD manifests and loaders in the DriverStore
# ---------------------------------------------------------------------------
function Get-VulkanPackages {
    param([string]$ExplicitPath)

    $root = if ([string]::IsNullOrEmpty($ExplicitPath)) { $RepoRoot } else { $ExplicitPath }
    if (-not (Test-Path $root)) {
        Say ('  DriverStore root not found: ' + $root)
        return @()
    }

    $jsonFiles = @(Get-ChildItem -Path $root -Recurse -Depth 4 -File -Filter '*.json' -ErrorAction SilentlyContinue |
                   Where-Object { $_.Length -le 65536 })
    $found = New-Object System.Collections.ArrayList

    foreach ($j in $jsonFiles) {
        $text = Get-Content -Path $j.FullName -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrEmpty($text)) { continue }
        if ($text -notmatch '"ICD"' -or $text -notmatch 'library_path') { continue }
        try { $obj = $text | ConvertFrom-Json } catch { continue }
        if (-not $obj.ICD -or -not $obj.ICD.library_path) { continue }

        $lib = ([string]$obj.ICD.library_path) -replace '/', '\'
        if ($lib.StartsWith('.\')) { $lib = $lib.Substring(2) }
        $libPath = if ([IO.Path]::IsPathRooted($lib)) { $lib } else { Join-Path $j.DirectoryName $lib }
        if (-not (Test-Path $libPath)) { continue }

        $bits = [VkRuntimeProbe]::GetBitness($libPath)
        if ($bits -eq 0) { continue }

        # Find a loader in the same package that really exports vkCreateInstance.
        $loader = $null
        $candidates = @(Get-ChildItem -Path $j.DirectoryName -File -Filter 'vulkan*.dll' -ErrorAction SilentlyContinue)
        foreach ($c in $candidates) {
            $cbits = [VkRuntimeProbe]::GetBitness($c.FullName)
            if ($cbits -ne $bits) { continue }
            if (-not [VkRuntimeProbe]::HasExportInFile($c.FullName, 'vkCreateInstance')) { continue }
            $loader = $c.FullName
            break
        }

        [void]$found.Add([pscustomobject]@{
            IcdJson     = $j.FullName
            LibraryPath = $libPath
            ApiVersion  = [string]$obj.ICD.api_version
            Bitness     = $bits
            LoaderPath  = $loader
            Modified    = $j.LastWriteTime
            PackageDir  = $j.DirectoryName
        })
    }
    return $found.ToArray()
}

function Show-SystemState {
    param($Packages)

    Say '=== System ==='
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    Say ('  OS: ' + $(if ($os) { $os.Caption } else { 'unknown' }) + ' (64-bit: ' + $Is64BitOS + ')')
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    foreach ($g in $gpus) { Say ('  GPU: ' + $g.Name + ' | driver ' + $g.DriverVersion) }

    Say '=== Vulkan runtime ==='
    Say ('  ' + $Dest64 + ' : ' + $(if (Test-Path $Dest64) { 'present' } else { 'MISSING' }))
    if ($Is64BitOS) {
        Say ('  ' + $Dest32 + ' : ' + $(if (Test-Path $Dest32) { 'present' } else { 'MISSING' }))
    }
    $icdKeys = New-Object System.Collections.ArrayList
    [void]$icdKeys.Add([pscustomobject]@{ Label = '64-bit'; Key = $Key64 })
    [void]$icdKeys.Add([pscustomobject]@{ Label = '32-bit'; Key = $Key32 })
    foreach ($entry in $icdKeys) {
        $label = $entry.Label; $key = $entry.Key
        $names = @(Get-IcdValueNames -Key $key)
        Say ('  ICD registry [' + $label + ']: ' + $names.Count + ' entry(ies)')
        foreach ($n in $names) {
            Say ('      ' + $(if (Test-Path $n) { '[valid]   ' } else { '[INVALID] ' }) + $n)
        }
    }

    Say ('=== DriverStore Vulkan packages found: ' + $($Packages.Count) + ' ===')
    foreach ($p in ($Packages | Sort-Object -Property Modified -Descending | Select-Object -First 12)) {
        Say ('  [' + $p.Bitness + '-bit] api ' + $p.ApiVersion +
             ' | loader ' + $(if ($p.LoaderPath) { [IO.Path]::GetFileName($p.LoaderPath) } else { 'NONE' }) +
             ' | ' + $p.IcdJson)
    }
    Say ' '
    Say '=== Vulkan API probe (what games actually see) ==='
    $systemOk = Invoke-SystemProbe -Label 'system'

    # Also prove the packaged driver works, without touching the system.
    $best = $Packages | Where-Object { $_.LoaderPath -and $_.Bitness -eq 64 } |
            Sort-Object -Property Modified -Descending | Select-Object -First 1
    if (-not $best) {
        $best = $Packages | Where-Object { $_.LoaderPath } |
                Sort-Object -Property Modified -Descending | Select-Object -First 1
    }
    $packageOk = $false
    if ($best) {
        $res = [VkRuntimeProbe]::Probe($best.LoaderPath, $best.IcdJson)
        $packageOk = Format-Probe -Result $res -Label 'driver package only'
    }
    else {
        Say '  No usable loader inside DriverStore. A full driver reinstall is likely required.'
    }

    if ($systemOk) {
        Say '  => System Vulkan runtime is healthy; no repair needed.'
    }
    elseif ($packageOk) {
        Say '  => The installed GPU driver is fine; only the system-level runtime is missing.'
        Say '     Run -Mode Fix to restore it.'
    }
    else {
        Say '  => The driver package itself looks damaged. Reinstall the full graphics driver.'
    }
}

# ---------------------------------------------------------------------------
# Diagnose
# ---------------------------------------------------------------------------
$packages = @(Get-VulkanPackages -ExplicitPath $DriverPackagePath)

if ($Mode -eq 'Diagnose') {
    Show-SystemState -Packages $packages
    Say 'Diagnose only. No changes made. Run -Mode Fix (as Administrator) to repair.'
    exit 0
}

if (-not (Test-IsAdmin)) {
    Say 'ERROR: -Mode Fix and -Mode Undo require an elevated (Administrator) session.'
    Say '       Right-click repair.cmd and choose "Run as administrator".'
    exit 1
}

# ---------------------------------------------------------------------------
# Undo
# ---------------------------------------------------------------------------
if ($Mode -eq 'Undo') {
    if (-not (Test-Path $StatePath)) {
        Say ('ERROR: no state file at ' + $StatePath + ' - nothing to undo.')
        exit 2
    }
    $s = Get-Content -Path $StatePath -Raw | ConvertFrom-Json

    foreach ($v in @($s.CreatedValues)) {
        if ($v.Path -and (Test-Path $v.Path)) {
            Remove-ItemProperty -Path $v.Path -Name $v.Name -ErrorAction SilentlyContinue
            Say ('  removed ICD value: ' + $v.Name)
        }
    }
    foreach ($v in @($s.RemovedValues)) {
        if ($v.Path -and (Test-Path $v.Path)) {
            New-ItemProperty -Path $v.Path -Name $v.Name -Value $v.Value -PropertyType DWord -Force | Out-Null
            Say ('  restored ICD value: ' + $v.Name)
        }
    }
    foreach ($f in @($s.CreatedFiles)) {
        if ($f -and (Test-Path $f)) { Remove-Item -Path $f -Force; Say ('  removed: ' + $f) }
    }
    foreach ($r in @($s.ReplacedFiles)) {
        if ($r.Backup -and (Test-Path $r.Backup)) {
            Copy-Item -Path $r.Backup -Destination $r.Target -Force
            Say ('  restored original: ' + $r.Target)
        }
    }
    foreach ($k in @($s.CreatedKeys)) {
        if ((Test-Path $k) -and @(Get-IcdValueNames -Key $k).Count -eq 0) {
            Remove-Item -Path $k -Force -ErrorAction SilentlyContinue
            Say ('  removed empty key: ' + $k)
        }
    }
    Remove-Item -Path $StatePath -Force
    Say 'Undo complete.'
    exit 0
}

# ---------------------------------------------------------------------------
# Fix
# ---------------------------------------------------------------------------
Say '=== Repairing Vulkan runtime ==='
if ($packages.Count -eq 0) {
    Say 'ERROR: no Vulkan ICD manifest found in the DriverStore.'
    Say '       Reinstall the full graphics driver package, or pass -DriverPackagePath.'
    exit 2
}

$createdFiles  = New-Object System.Collections.ArrayList
$createdValues = New-Object System.Collections.ArrayList
$removedValues = New-Object System.Collections.ArrayList
$replacedFiles = New-Object System.Collections.ArrayList
$createdKeys   = New-Object System.Collections.ArrayList
$backupDir     = Join-Path (Split-Path -Parent $StatePath) 'vulkan-repair-backups'
$stamp         = Get-Date -Format 'yyyyMMdd-HHmmss'

# 1. Optionally drop stale ICD registrations.
if ($PruneInvalidIcd) {
    foreach ($key in @($Key64, $Key32)) {
        foreach ($name in @(Get-IcdValueNames -Key $key)) {
            if (Test-Path $name) { continue }
            $old = (Get-ItemProperty -Path $key -Name $name).$name
            Remove-ItemProperty -Path $key -Name $name -Force
            [void]$removedValues.Add([pscustomobject]@{ Path = $key; Name = $name; Value = $old })
            Say ('  pruned stale ICD: ' + $name)
        }
    }
}

# 2. Install the system loader, one per architecture.
$archMap = New-Object System.Collections.ArrayList
[void]$archMap.Add([pscustomobject]@{ Bits = 64; Dest = $Dest64; Key = $Key64 })
if ($Is64BitOS) {
    [void]$archMap.Add([pscustomobject]@{ Bits = 32; Dest = $Dest32; Key = $Key32 })
}

foreach ($a in $archMap) {
    $bits = $a.Bits; $dest = $a.Dest; $key = $a.Key
    $pkg = $packages | Where-Object { $_.Bitness -eq $bits -and $_.LoaderPath } |
           Sort-Object -Property Modified -Descending | Select-Object -First 1
    if (-not $pkg) {
        Say ('  [' + $bits + '-bit] no loader found in any driver package - skipped')
        continue
    }

    if (Test-Path $dest) {
        if (-not $Force) {
            Say ('  [' + $bits + '-bit] loader already present, skipped: ' + $dest)
        }
        else {
            if (-not (Test-Path $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }
            $bak = Join-Path $backupDir ('loader' + $bits + '-' + $stamp + '.dll')
            Copy-Item -Path $dest -Destination $bak -Force
            [void]$replacedFiles.Add([pscustomobject]@{ Target = $dest; Backup = $bak })
            Copy-Item -Path $pkg.LoaderPath -Destination $dest -Force
            Say ('  [' + $bits + '-bit] replaced loader (backup: ' + $bak + ')')
        }
    }
    else {
        Copy-Item -Path $pkg.LoaderPath -Destination $dest -Force
        [void]$createdFiles.Add($dest)
        Say ('  [' + $bits + '-bit] installed loader: ' + $dest)
    }

    # 3. Register the matching ICD manifest.
    if (-not (Test-Path $key)) {
        New-Item -Path $key -Force | Out-Null
        [void]$createdKeys.Add($key)
        Say ('  [' + $bits + '-bit] created key: ' + $key)
    }
    $existing = @(Get-IcdValueNames -Key $key)
    if ($existing -contains $pkg.IcdJson) {
        Say ('  [' + $bits + '-bit] ICD already registered')
    }
    else {
        New-ItemProperty -Path $key -Name $pkg.IcdJson -Value 0 -PropertyType DWord -Force | Out-Null
        [void]$createdValues.Add([pscustomobject]@{ Path = $key; Name = $pkg.IcdJson })
        Say ('  [' + $bits + '-bit] registered ICD: ' + $pkg.IcdJson)
    }
}

$state = [pscustomobject]@{
    Time           = $stamp
    CreatedFiles   = @($createdFiles)
    ReplacedFiles  = @($replacedFiles)
    CreatedValues  = @($createdValues)
    RemovedValues  = @($removedValues)
    CreatedKeys    = @($createdKeys)
}
$state | ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding UTF8
Say ('  state file: ' + $StatePath)

# 4. Verify in a fresh process so the loader picks up the new ICD registration.
Say ' '
Say '=== Verification (fresh process) ==='
$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path $psExe) {
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Mode Verify
    $verifyExit = $LASTEXITCODE
}
else {
    $verifyExit = if (Invoke-SystemProbe -Label 'system') { 0 } else { 3 }
}

Say ' '
if ($verifyExit -eq 0) {
    Say 'DONE. Vulkan is working. Re-run the game that reported the driver warning.'
}
else {
    Say 'NOT FIXED. The Vulkan probe still fails.'
    Say 'Next step: reinstall the FULL graphics driver package with a clean/factory-reset install, then reboot.'
}
Say ('UNDO: powershell -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Mode Undo')
exit $verifyExit
