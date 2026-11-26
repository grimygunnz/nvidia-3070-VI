# Scores runs of scripts\play-guarded.ps1 from their logs: every frame line of the host
# (`<fps> fps, <ms> ms/frame (<ms> preparing ... <ms> on the GPU ...)`) from -From
# seconds into the run on (gameplay starts some 150-200 s in with -SkipMenus).
#   mean_ms   1000 x lines / sum of their fps: every frame weighted alike
#   prep      the submitting thread's preparing, gpu its waiting for the card
#   heapwait  the wait for the heaps' records at a submission's end (last 10 lines)
#   lost      whether the device went
#   scripts\score.ps1 %TEMP%\victory-coolfox-<tag>-*.log.err [...] [-From 200]
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)][string[]]$Logs,
    [int]$From = 200
)
foreach ($pattern in $Logs) {
    foreach ($f in (Get-ChildItem $pattern | Sort-Object LastWriteTime)) {
        $start = $null; $fps = @(); $prep = @(); $gpu = @()
        foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
            if ($line -notmatch '^(\S+)Z') { continue }
            $t = [datetime]::Parse($Matches[1])
            if (-not $start) { $start = $t }
            if (($t - $start).TotalSeconds -lt $From) { continue }
            if ($line -match '([\d.]+) fps, ([\d.]+) ms/frame \(([\d.]+) preparing.*?; ([\d.]+) on the GPU') {
                $fps += [double]$Matches[1]; $prep += [double]$Matches[3]; $gpu += [double]$Matches[4]
            }
        }
        $n = $fps.Count
        $wait = (Select-String -Path $f.FullName -Pattern 'ms \(([\d.]+) ms waited for\)' | Select-Object -Last 10 |
            ForEach-Object { [double]$_.Matches[0].Groups[1].Value } | Measure-Object -Average).Average
        [pscustomobject]@{
            log      = $f.Name
            lines    = $n
            mean_ms  = if ($n) { [math]::Round(1000 * $n / ($fps | Measure-Object -Sum).Sum, 1) } else { $null }
            fps      = if ($n) { [math]::Round(($fps | Measure-Object -Average).Average, 1) } else { $null }
            prep     = if ($n) { [math]::Round(($prep | Measure-Object -Average).Average, 1) } else { $null }
            gpu      = if ($n) { [math]::Round(($gpu | Measure-Object -Average).Average, 1) } else { $null }
            heapwait = [math]::Round([double]$wait, 2)
            lost     = [bool](Select-String -Path $f.FullName -Pattern 'host GPU failure' -Quiet)
        }
    }
}
