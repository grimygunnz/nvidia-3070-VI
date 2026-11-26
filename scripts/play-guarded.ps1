# Starts this fork with the settings of its own Play-VIctory.cmd, guarded for this PC:
#  - a Windows job object caps the game's committed memory (-MaxGB, 46 by default);
#  - a watchdog ends the game below -MinFreeGB of free physical memory (3);
#  - every 5 s the game's private memory, free memory and card memory go to <log>.mem.csv.
#   scripts\play-guarded.ps1 -Game <exe> -SkipMenus -Seconds 330 -Tag x [-Console series-s] [-Affinity 0xFFF]
param(
    [Parameter(Mandatory)][string]$Game,
    [string]$Exe = (Join-Path $PSScriptRoot "..\target\diag\victory.exe"),
    [string]$Cache = "$env:LOCALAPPDATA\victory-coolfox\cache",
    [string]$Data = "$env:LOCALAPPDATA\victory-coolfox\data",
    [string]$Console = 'series-s',
    [int]$MaxGB = 46,
    [double]$MinFreeGB = 3,
    [switch]$SkipMenus,
    [int]$Seconds = 0,
    [string]$Tag = "",
    # Logical processors the game may run on, as a bit mask (0: all). On a
    # Ryzen with two core dies, 0xFFF keeps it on the first die's 12 threads.
    [long]$Affinity = 0,
    # Settings on top of the ones below, as NAME=value (VICTORY_ is added if
    # missing): -Set VICTORY_DISPLAY_MODE=1920x1080,GPU_TIMING=1. Variables set
    # outside the script do not reach the game: every VICTORY_ one is cleared.
    [string[]]$Set = @()
)
$ErrorActionPreference = 'Stop'
# Once per PowerShell session (several runs from one window).
if (-not ('GuardJob' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GuardJob {
    [StructLayout(LayoutKind.Sequential)]
    struct BASIC { public long a, b; public uint LimitFlags; public UIntPtr c, d; public uint e; public UIntPtr f; public uint g, h; }
    [StructLayout(LayoutKind.Sequential)]
    struct IO { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)]
    struct EXT { public BASIC Basic; public IO Io; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcess, PeakJob; }
    [DllImport("kernel32", SetLastError = true)] static extern IntPtr CreateJobObjectW(IntPtr a, IntPtr n);
    [DllImport("kernel32", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr j, int c, ref EXT i, int l);
    [DllImport("kernel32", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
    public static IntPtr Cap(IntPtr process, ulong bytes) {
        IntPtr job = CreateJobObjectW(IntPtr.Zero, IntPtr.Zero);
        if (job == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        EXT info = new EXT();
        info.Basic.LimitFlags = 0x100 | 0x2000;
        info.ProcessMemoryLimit = new UIntPtr(bytes);
        if (!SetInformationJobObject(job, 9, ref info, Marshal.SizeOf(typeof(EXT)))) throw new System.ComponentModel.Win32Exception();
        if (!AssignProcessToJobObject(job, process)) throw new System.ComponentModel.Win32Exception();
        return job;
    }
}
'@
}
$Exe = (Resolve-Path $Exe).Path
$Game = (Resolve-Path $Game).Path
# Play-VIctory.cmd's settings.
$settings = @{
    VICTORY_AMBIENT_AIR = '1.5'; VICTORY_TEXTURE_NO_WAIT = '1'; VICTORY_RELAY = '2'; VICTORY_WIDE_BACK = '1'
    VICTORY_CARD_REHASH_RUNS = '1'; VICTORY_JOIN_COPIES = '1'; VICTORY_INDIRECT_WINDOW = '1'; VICTORY_RELAY_COPY = '1'
    VICTORY_CARD_STEPS = '2'; VICTORY_INDIRECT_BATCH = '2'; VICTORY_MAP_THREADS = '1'; VICTORY_CARD_AWAKE = '1'
    VICTORY_SHOW_AFTER = '1'; VICTORY_AMBIENT = '0.8'; VICTORY_THIN = '1'; VICTORY_JOIN_PARTS = '8'
    VICTORY_UPLOAD_AHEAD = '1'; VICTORY_LEVELS_ON_DEMAND = '1'; VICTORY_CARD_BUFFERS_MIN_KB = '64'
    VICTORY_LOG = 'info'
}
if ($SkipMenus) {
    $settings.VICTORY_KEYS = (15, 25, 35, 45, 55, 70, 90, 110, 130, 150, 170, 190 | ForEach-Object { "${_}:Enter" }) -join ','
}
foreach ($pair in $Set) {
    $k, $v = $pair -split '=', 2
    if ($null -eq $v) { throw "-Set wants NAME=value, not '$pair'" }
    if ($k -notlike 'VICTORY_*') { $k = "VICTORY_$k" }
    $settings[$k] = $v
    Write-Host "Set:   $k=$v"
}
Get-ChildItem Env:VICTORY_* | ForEach-Object { Remove-Item "Env:$($_.Name)" }
New-Item -ItemType Directory -Force $Cache, $Data | Out-Null
$env:VICTORY_CACHE_DIR = $Cache
$env:VICTORY_DATA_DIR = $Data
foreach ($k in $settings.Keys) { Set-Item "Env:$k" $settings[$k] }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $env:TEMP ("victory-coolfox-{0}-{1}.log" -f $Tag, $stamp)
$csv = "$log.mem.csv"
Write-Host "Log:   $log.err"
Push-Location (Join-Path $PSScriptRoot '..')
try {
    $p = Start-Process -FilePath $Exe -ArgumentList @('run', $Game, '--execute', '--console', $Console) -NoNewWindow -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    $null = [GuardJob]::Cap($p.Handle, [uint64]$MaxGB * 1GB)
    if ($Affinity -ne 0) { $p.ProcessorAffinity = [IntPtr]$Affinity; Write-Host ("Affinity: 0x{0:X}" -f $Affinity) }
    'seconds,private_gb,free_gb,card_gb' | Set-Content -Encoding utf8 $csv
    $start = Get-Date
    $why = $null
    while (-not $p.HasExited) {
        Start-Sleep -Seconds 5
        $p.Refresh()
        if ($p.HasExited) { break }
        $free = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB / 1GB
        $card = 0
        try {
            $card = ((Get-Counter "\GPU Process Memory(pid_$($p.Id)*)\Dedicated Usage" -ErrorAction Stop).CounterSamples |
                Measure-Object CookedValue -Sum).Sum / 1GB
        } catch {}
        $t = ((Get-Date) - $start).TotalSeconds
        [string]::Format([cultureinfo]::InvariantCulture, '{0:F0},{1:F2},{2:F2},{3:F2}',
            $t, ($p.PrivateMemorySize64 / 1GB), $free, $card) | Add-Content $csv
        if ($free -lt $MinFreeGB) { $why = "free memory under $MinFreeGB GB"; break }
        if ($Seconds -gt 0 -and $t -ge $Seconds) { $why = "run time of $Seconds s reached"; break }
    }
    if (-not $p.HasExited) {
        Write-Host "Ending the game: $why"
        Stop-Process -Id $p.Id -Force
        $p.WaitForExit()
    } else {
        Write-Host "The game ended by itself (exit $($p.ExitCode))."
    }
} finally {
    Pop-Location
}
