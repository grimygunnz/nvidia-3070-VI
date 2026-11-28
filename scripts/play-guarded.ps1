# Starts this fork with the settings of its own Play-VIctory.cmd, guarded for this PC:
#  - a Windows job object caps the game's committed memory (-MaxGB, 46 by default);
#  - a watchdog ends the game below -MinFreeGB of free physical memory (3);
#  - every 5 s the game's private memory, free memory and card memory go to <log>.mem.csv.
#   scripts\play-guarded.ps1 -Game <exe> -SkipMenus -Seconds 330 -Tag x [-Console series-s] [-Affinity 0xFFF]
#   -Profile fox (default Play-VIctory) | br (VI-BR-PORT measured set, cool_fox-compatible)
param(
    [Parameter(Mandatory)][string]$Game,
    [string]$Exe = (Join-Path $PSScriptRoot "..\target\diag\victory.exe"),
    [string]$Cache = "$env:LOCALAPPDATA\victory-coolfox\cache",
    [string]$Data = "$env:LOCALAPPDATA\victory-coolfox\data",
    [string]$Console = 'series-s',
    [ValidateSet('fox', 'br')][string]$Profile = 'fox',
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
# Shared submission / copy machinery (both profiles).
$settings = @{
    VICTORY_TEXTURE_NO_WAIT = '1'; VICTORY_RELAY = '2'; VICTORY_WIDE_BACK = '1'
    VICTORY_CARD_REHASH_RUNS = '1'; VICTORY_JOIN_COPIES = '1'; VICTORY_INDIRECT_WINDOW = '1'; VICTORY_RELAY_COPY = '1'
    VICTORY_CARD_STEPS = '2'; VICTORY_INDIRECT_BATCH = '2'; VICTORY_MAP_THREADS = '1'
    VICTORY_SHOW_AFTER = '1'; VICTORY_THIN = '1'; VICTORY_JOIN_PARTS = '8'
    VICTORY_UPLOAD_AHEAD = '1'; VICTORY_LEVELS_ON_DEMAND = '0'; VICTORY_TEXTURE_MAX_SIDE = '1024'
    VICTORY_CARD_BUFFERS_MIN_KB = '64'; VICTORY_LOG = 'info'
}
if ($Profile -eq 'br') {
    # VI-BR-PORT play.ps1 measured set (edsuuu) + Mandy/VIctory-NVIDIA wait cuts.
    # PORT_GUARD / PORT_JOURNAL / CARD_TOUCHED / UPSCALER / AMBIENT_OUTSIDE not in cool_fox yet.
    $settings.VICTORY_MEMORY_CARD_MB = '1024'
    $settings.VICTORY_DISPLAY_MODE = '1920x1080'
    $settings.VICTORY_PIPELINE_BOOK = '1'
    $settings.VICTORY_PIPELINE_WAIT_MS = '10000'
    # Drain early pipeline queue on splash/load presents (cutscene hitch cut).
    $settings.VICTORY_PIPELINE_SPLASH = '1'
    $settings.VICTORY_PIPELINE_SPLASH_MS = '750'
    $settings.VICTORY_CARD_AWAKE = '0'
    $settings.VICTORY_TITLE_PRIORITIES = '0'
    $settings.VICTORY_RT_MISS = '1'
    $settings.VICTORY_AMBIENT = 'constant:0.1:0.5'
    $settings.VICTORY_AMBIENT_AIR = '0.8'
    $settings.VICTORY_FILL_TITLE = '1'
    $settings.VICTORY_PLACED_TITLE = '1'
    $settings.VICTORY_WC_NO_BACK = '1'
    # Keep 1024: br-wc64 (MIN=64) left copy-back ~21 MB and median ~17.8 fps.
    $settings.VICTORY_WC_NO_BACK_MIN_KB = '1024'
    # XEN/NVIDIA texture pacing + late PSO wait (dynamic targets room is default in code).
    $settings.VICTORY_TEXTURE_STAGE_MS = '16'
    $settings.VICTORY_TEXTURE_CATCHUP = '0'
    $settings.VICTORY_COMPUTE_LATE_WAIT_MS = '400'
    # NVIDIA foxhound: skip heat-haze / decal-heap defrag (~12 ms GPU/frame there).
    $settings.VICTORY_LEAVE_OUT = '02384a60fda6f2d0,731a39171b568298'
    # TRIDENT (ECHOZwei): more flights in flight + parallel merge (cool_fox already has the knobs).
    $settings.VICTORY_LATE_WAIT_LISTS = '1024'
    $settings.VICTORY_WIDE_MERGE = '1'
    $settings.VICTORY_WIDE_REFRESH = '1'
    # Cut prepare copies / GetWriteWatch: only differing bytes go up; quiet 1 MiB
    # blocks asked once a frame; copy-back writes forgotten for the source copy
    # (TRIDENT play.ps1 ASK_QUIET=3 / COPY_CHANGED=1 / QUIET_BACK=1).
    $settings.VICTORY_COPY_CHANGED = '1'
    $settings.VICTORY_ASK_QUIET = '3'
    $settings.VICTORY_ASK_QUIET_GAP_MB = '8'
    # Batched ResetWriteWatch (QUIET_BACK_TOGETHER, default on): re-try watched quiet.
    $settings.VICTORY_QUIET_BACK = '1'
    $settings.VICTORY_QUIET_BACK_WATCHED = '1'
    $settings.VICTORY_QUIET_BACK_TOGETHER = '1'
    # On-picture stats (F3 toggles): RAM/VRAM/commit, res, RT, lighting, shaders/textures.
    $settings.VICTORY_PANEL = '1'
    # CARD_COMPARE_EVERY lean compares measured no FPS win (and sometimes worse).
    # SOFT_VIEWS=copies ported but off here: br-soft (2026-11-27) never left menus
    # (~8 draws/frame, ~8 GB private). Opt in with -Set SOFT_VIEWS=copies after fix.
    # HELPER_PRIORITY + FAST_COPY on by default (=0 to disable). TEARING left opt-in (smeared here).
    # Residency batched before each submit (own fix: was ~11 ms/frame of MakeResident waits).
    # Bus path (discrete/non-unified): PLACED_TITLE skips PCIe land waits when the title
    # wrote the page; WINDOWS_BAR auto (ReBAR) keeps shader window reads in card memory;
    # HIGH_NO_BACK leaves large >2^40 fetch-only copies on the card (~21 MB/frame).
    $settings.VICTORY_HIGH_NO_BACK = '1'
    # Empty-refresh looks batched (LOOKS_APART default on; FRONT_FEW=64 in code).
    # Prepare CPU: range-limited title_written flush (WRITE_FLUSH=all to disable);
    # heap sync kicked before flight settle.
    Write-Host "Profile: br (+ ASK_QUIET/COPY_CHANGED/QUIET_BACK; FAST_COPY; HELPER_PRIORITY; batched resident; PANEL; LATE_WAIT/WIDE; splash; bus BAR/placed/HIGH_NO_BACK; LOOKS_APART; write-flush; early heap-sync; no PAGE_TABLE)"
} else {
    # Play-VIctory.cmd's settings (legacy fox path: keep ray resolve/activate compiling).
    $settings.VICTORY_CARD_AWAKE = '1'
    $settings.VICTORY_AMBIENT_AIR = '1.5'
    $settings.VICTORY_AMBIENT = '0'
    $settings.VICTORY_RT_RESOLVE = '1'
    $settings.VICTORY_ACTIVATE_RAYS = '1'
    $settings.VICTORY_BVH_MISS = '1'
    Write-Host "Profile: fox (Play-VIctory defaults)"
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
        # WMI can throw "Out of memory" under load; do not end the run for that.
        $free = $null
        try {
            $free = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory * 1KB / 1GB
        } catch {}
        $card = 0
        try {
            $card = ((Get-Counter "\GPU Process Memory(pid_$($p.Id)*)\Dedicated Usage" -ErrorAction Stop).CounterSamples |
                Measure-Object CookedValue -Sum).Sum / 1GB
        } catch {}
        $t = ((Get-Date) - $start).TotalSeconds
        $freeCsv = if ($null -ne $free) { $free } else { -1 }
        [string]::Format([cultureinfo]::InvariantCulture, '{0:F0},{1:F2},{2:F2},{3:F2}',
            $t, ($p.PrivateMemorySize64 / 1GB), $freeCsv, $card) | Add-Content $csv
        if ($null -ne $free -and $free -lt $MinFreeGB) { $why = "free memory under $MinFreeGB GB"; break }
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
