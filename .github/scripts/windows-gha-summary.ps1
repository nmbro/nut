# Network UPS Tools: GitHub Actions job summary for the NUT for Windows builds
# (see .github/workflows/09-windows-mingw32.yml), also for failed builds:
# * duration of each step (from the Actions API, so the job needs the
#   "actions: read" permission and GH_TOKEN; the runners have the gh CLI),
# * how the caches were restored, and their sizes now,
# * ccache statistics of this build (counters are zeroed in
#   .github/scripts/appveyor/03-before_build.bat),
# * the archives made by 08-after_test.bat, their sizes and artifact links.
#
# Inputs (env): CACHE_<NAME>_HIT, CACHE_<NAME>_KEY and CACHE_<NAME>_PATH for
# NAME in PACMAN, DEPS, CCACHE and AUTOCONF (outputs and paths of the cache restore
# steps); ARTIFACT_BUNDLE_URL and ARTIFACT_DEBUGINFO_URL (upload steps);
# NUT_MSYSTEM and CCACHE_DIR as for the build steps.
# Everything is best-effort: this step never fails the build.

$ErrorActionPreference = "Continue"
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$lines = New-Object System.Collections.Generic.List[string]

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return [string]::Format($inv, "{0:F2} GiB", $bytes / 1GB) }
    if ($bytes -ge 1MB) { return [string]::Format($inv, "{0:F1} MiB", $bytes / 1MB) }
    return [string]::Format($inv, "{0:F0} KiB", $bytes / 1KB)
}

function Format-Duration([TimeSpan]$t) {
    if ($t.TotalHours -ge 1) { return $t.ToString("h\:mm\:ss", $inv) }
    return $t.ToString("m\:ss", $inv)
}

function Get-DirSize([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
    $sum = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return $sum
}

$lines.Add("### NUT for Windows build ($env:NUT_MSYSTEM)")
$lines.Add("")

# Step durations, from the jobs of this run attempt (this job is the one
# which runs on this runner)
try {
    $json = & gh api "repos/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID/attempts/$env:GITHUB_RUN_ATTEMPT/jobs?per_page=100"
    if ($LASTEXITCODE -ne 0) { throw "gh api exited with code $LASTEXITCODE" }
    $job = ($json | Out-String | ConvertFrom-Json).jobs |
        Where-Object { $_.runner_name -eq $env:RUNNER_NAME } | Select-Object -First 1
    if (-not $job) { throw "no job found for runner $env:RUNNER_NAME" }

    $lines.Add("| Step | Result | Duration |")
    $lines.Add("|---|---|---:|")
    foreach ($st in $job.steps) {
        if (-not $st.started_at -or -not $st.completed_at) { continue }
        if ($st.conclusion -eq "skipped") { continue }
        $d = [datetime]::Parse($st.completed_at, $inv) - [datetime]::Parse($st.started_at, $inv)
        # Skip the trivial steps, keep the failed ones
        if ($d.TotalSeconds -lt 5 -and $st.conclusion -eq "success") { continue }
        $lines.Add("| $($st.name) | $($st.conclusion) | $(Format-Duration $d) |")
    }
    $total = [datetime]::UtcNow - [datetime]::Parse($job.started_at, $inv).ToUniversalTime()
    $lines.Add("| **Job so far** | | **$(Format-Duration $total)** |")
} catch {
    $lines.Add("Step durations are not available: $_")
}
$lines.Add("")

# Caches: how they were restored, and their sizes now (what a save would store)
$lines.Add("| Cache | Restored | Size now |")
$lines.Add("|---|---|---:|")
foreach ($name in @("PACMAN", "DEPS", "CCACHE", "AUTOCONF")) {
    $hit = [Environment]::GetEnvironmentVariable("CACHE_${name}_HIT")
    $key = [Environment]::GetEnvironmentVariable("CACHE_${name}_KEY")
    $path = [Environment]::GetEnvironmentVariable("CACHE_${name}_PATH")
    if ($hit -eq "true") { $how = "exact key" }
    elseif ($key) { $how = "partial (``$key``)" }
    else { $how = "miss" }
    $size = Get-DirSize $path
    if ($null -eq $size) { $sizeStr = "-" } else { $sizeStr = Format-Size $size }
    $lines.Add("| ``$path`` | $how | $sizeStr |")
}
$lines.Add("")

# ccache statistics: run it through MSYS2 bash like the build steps do, see
# .github/scripts/appveyor/12-on_success.ps1 (no double quotes in the command)
try {
    $env:CHERE_INVOKING = "yes"
    if ($env:NUT_MSYSTEM) { $env:MSYSTEM = $env:NUT_MSYSTEM } else { $env:MSYSTEM = "UCRT64" }
    $out = & C:\msys64\usr\bin\bash -lc 'PATH=${MINGW_PREFIX}/bin:$PATH ; export PATH ; ccache --print-stats'
    if ($LASTEXITCODE -ne 0) { throw "ccache --print-stats exited with code $LASTEXITCODE" }
    $s = @{}
    $out | ForEach-Object {
        $kv = $_ -split "`t", 2
        if ($kv.Count -eq 2) { $s[$kv[0]] = [long]$kv[1] }
    }
    if ($s.Count -eq 0) { throw "no ccache statistics" }
    $hits = $s['direct_cache_hit'] + $s['preprocessed_cache_hit']
    $total = $hits + $s['cache_miss']
    $pct = 0
    if ($total -gt 0) { $pct = [math]::Round(100.0 * $hits / $total, 1) }
    $lines.Add([string]::Format($inv,
        "**ccache:** {0} of {1} compilations were cache hits ({2}%: {3} direct, {4} preprocessed), {5} misses; cache size {6} of {7}.",
        $hits, $total, $pct, $s['direct_cache_hit'], $s['preprocessed_cache_hit'], $s['cache_miss'],
        (Format-Size ($s['cache_size_kibibyte'] * 1KB)), (Format-Size ($s['max_cache_size_kibibyte'] * 1KB))))
} catch {
    $lines.Add("ccache statistics are not available: $_")
}
$lines.Add("")

# Archives (artifacts) made by 08-after_test.bat
$archives = @(Get-ChildItem -Path "NUT-for-Windows-*.7z", "NUT-debuginfo-for-Windows-*.7z" -File -ErrorAction SilentlyContinue)
if ($archives.Count -gt 0) {
    $lines.Add("| Archive | Size |")
    $lines.Add("|---|---:|")
    foreach ($a in $archives) {
        if ($a.Name -like "NUT-debuginfo-*") { $url = $env:ARTIFACT_DEBUGINFO_URL } else { $url = $env:ARTIFACT_BUNDLE_URL }
        if ($url) { $label = "[$($a.Name)]($url)" } else { $label = $a.Name }
        $lines.Add("| $label | $(Format-Size $a.Length) |")
    }
} else {
    $lines.Add("No NUT for Windows archives were made.")
}

$text = $lines -join "`n"
echo $text
if ($env:GITHUB_STEP_SUMMARY) {
    # UTF-8 without a BOM (Windows PowerShell 5.1 Add-Content would add one)
    [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $text + "`n",
        (New-Object System.Text.UTF8Encoding $false))
}
$global:LASTEXITCODE = 0
exit 0
