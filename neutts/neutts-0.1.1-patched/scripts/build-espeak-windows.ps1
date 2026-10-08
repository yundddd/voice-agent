# scripts/build-espeak-windows.ps1
#
# Build a static espeak-ng library for Windows (MSVC) and cache it under
#   <repo-root>/espeak-static/lib/espeak-ng-merged.lib
#
# The script merges the three CMake-produced archives
#   (espeak-ng.lib  speechPlayer.lib  ucd.lib)
# into a single fat lib so callers link with one flag and have no link-order
# concerns.
#
# ── Requirements ─────────────────────────────────────────────────────────────
#   Visual Studio 2019 / 2022 (or Build Tools) with the C++ workload
#   CMake  (winget install Kitware.CMake)
#   Git    (winget install Git.Git)
#   Ninja  — optional but strongly recommended (winget install Ninja-build.Ninja)
#            If absent the script falls back to MSBuild via the VS generator.
#
# ── Usage ────────────────────────────────────────────────────────────────────
#   # From a Visual Studio Developer PowerShell or after running vcvarsall.bat:
#   .\scripts\build-espeak-windows.ps1
#
#   # Override the build root if OUT_DIR depth causes path-length issues:
#   .\scripts\build-espeak-windows.ps1 -BuildRoot C:\es
#
# ── Output ───────────────────────────────────────────────────────────────────
#   espeak-static\lib\espeak-ng-merged.lib  (fat static library)
#   espeak-static\include\espeak-ng\        (headers)
#   espeak-static\share\espeak-ng-data\     (phoneme data)
#
# After running, cargo build finds the library automatically:
#   ESPEAK_LIB_DIR=espeak-static\lib cargo build --features espeak
# ─────────────────────────────────────────────────────────────────────────────

param(
    [string]$BuildRoot = "$env:TEMP\espeak-build",
    [string]$EspeakVersion = "1.52.0"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Colour helpers ────────────────────────────────────────────────────────────
function Write-Step  { param([string]$Msg) Write-Host "▶ $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "  ⚠ $Msg" -ForegroundColor Yellow }
function Write-Fail  { param([string]$Msg) Write-Host "  ✗ $Msg" -ForegroundColor Red; exit 1 }

# ── Paths ─────────────────────────────────────────────────────────────────────
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $ScriptDir
$OutDir     = Join-Path $RepoRoot "espeak-static"
$LibDir     = Join-Path $OutDir "lib"
$IncDir     = Join-Path $OutDir "include"
$ShareDir   = Join-Path $OutDir "share"
$MergedLib  = Join-Path $LibDir "espeak-ng-merged.lib"
$StampFile  = Join-Path $LibDir "espeak-ng-merged.stamp"

$SrcDir  = Join-Path $BuildRoot "src"
$BldDir  = Join-Path $BuildRoot "bld"
$InstDir = Join-Path $BuildRoot "inst"

Write-Host ""
Write-Host "espeak-ng $EspeakVersion  →  Windows MSVC static library" -ForegroundColor White
Write-Host "  Build root : $BuildRoot"
Write-Host "  Output     : $OutDir"
Write-Host ""

# ── Already built? ────────────────────────────────────────────────────────────
if ((Test-Path $MergedLib) -and (Test-Path $StampFile)) {
    $stamp = Get-Content $StampFile -Raw
    if ($stamp.Trim() -eq $EspeakVersion) {
        Write-Ok "Already built: $MergedLib"
        Write-Host "  Delete espeak-static\ to force a rebuild."
        exit 0
    }
}
# Remove stale merged lib so it gets rebuilt cleanly.
if (Test-Path $MergedLib) { Remove-Item $MergedLib -Force }
if (Test-Path $StampFile) { Remove-Item $StampFile -Force }

# ── Check prerequisites ───────────────────────────────────────────────────────
Write-Step "Checking prerequisites"

foreach ($tool in @("cmake", "git")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Fail "$tool not found on PATH.  Install: winget install $(if ($tool -eq 'cmake') {'Kitware.CMake'} else {'Git.Git'})"
    }
    Write-Ok "$tool found: $(Get-Command $tool | Select-Object -ExpandProperty Source)"
}

# lib.exe (MSVC archive tool) — must be on PATH (run from Developer PowerShell
# or after invoking vcvarsall.bat).
$LibExe = Get-Command "lib" -ErrorAction SilentlyContinue
if (-not $LibExe) {
    # Try llvm-lib as an alternative (ships with LLVM).
    $LibExe = Get-Command "llvm-lib" -ErrorAction SilentlyContinue
}
if (-not $LibExe) {
    Write-Fail (
        "Neither 'lib' (MSVC) nor 'llvm-lib' (LLVM) found on PATH.`n" +
        "  Open a 'Developer PowerShell for VS' or run:`n" +
        "    & 'C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'"
    )
}
$LibExeName = $LibExe.Name
Write-Ok "$LibExeName found: $($LibExe.Source)"

# Ninja (preferred — avoids MSBuild's path-length issues with \\?\ paths).
$UseNinja = [bool](Get-Command "ninja" -ErrorAction SilentlyContinue)
if ($UseNinja) {
    Write-Ok "Ninja found — will use Ninja generator"
} else {
    Write-Warn "Ninja not found — falling back to MSBuild (winget install Ninja-build.Ninja recommended)"
}

# ── Create directories ────────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $SrcDir, $BldDir, $InstDir, $LibDir | Out-Null

# ── Clone ─────────────────────────────────────────────────────────────────────
Write-Step "Cloning espeak-ng $EspeakVersion"
if (-not (Test-Path (Join-Path $SrcDir "CMakeLists.txt"))) {
    git clone --depth=1 --branch $EspeakVersion `
        "https://github.com/espeak-ng/espeak-ng.git" $SrcDir
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "git clone failed.  Check your internet connection."
    }
    Write-Ok "Cloned to $SrcDir"
} else {
    Write-Ok "Reusing cached source in $SrcDir"
}

# ── cmake configure ───────────────────────────────────────────────────────────
Write-Step "CMake configure"
$CmakeArgs = @(
    "-S", $SrcDir,
    "-B", $BldDir,
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_INSTALL_PREFIX=$InstDir",
    "-DBUILD_SHARED_LIBS=OFF",
    "-DUSE_MBROLA=OFF",
    "-DUSE_LIBSONIC=OFF",
    "-DUSE_LIBPCAUDIO=OFF",
    "-DUSE_ASYNC=OFF"
)
if ($UseNinja) {
    $CmakeArgs += @("-GNinja")
}

cmake @CmakeArgs
if ($LASTEXITCODE -ne 0) { Write-Fail "cmake configure failed." }

# ── cmake build ───────────────────────────────────────────────────────────────
$Jobs = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
Write-Step "CMake build ($Jobs threads)"
cmake --build $BldDir --config Release --parallel $Jobs
if ($LASTEXITCODE -ne 0) { Write-Fail "cmake build failed." }

# ── cmake install (headers + data) ────────────────────────────────────────────
Write-Step "CMake install (headers + data)"
cmake --install $BldDir --config Release
# Allowed to exit non-zero if it can't install the static lib — we copy it manually.

# ── Collect static archives ───────────────────────────────────────────────────
Write-Step "Collecting static archives"
$Wanted  = @("espeak-ng.lib", "speechPlayer.lib", "ucd.lib")
$Collected = @()
foreach ($name in $Wanted) {
    $found = Get-ChildItem -Path $BldDir -Filter $name -Recurse -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found) {
        $dest = Join-Path $LibDir $name
        Copy-Item $found.FullName $dest -Force
        Write-Ok "Collected: $name  ($([math]::Round($found.Length/1KB, 1)) KB)"
        $Collected += $dest
    }
}
if ($Collected.Count -eq 0) {
    Write-Fail "No .lib files found after cmake build.  Check the build output above."
}

# ── Merge into fat library ────────────────────────────────────────────────────
Write-Step "Merging $($Collected.Count) archive(s) → espeak-ng-merged.lib"
$LibArgs = @("/OUT:$MergedLib") + $Collected
& $LibExeName @LibArgs
if ($LASTEXITCODE -ne 0) { Write-Fail "$LibExeName merge failed." }
Write-Ok "Merged: $MergedLib  ($([math]::Round((Get-Item $MergedLib).Length/1MB, 2)) MB)"

# ── Copy headers ──────────────────────────────────────────────────────────────
$InstInclude = Join-Path $InstDir "include"
if (Test-Path $InstInclude) {
    if (-not (Test-Path $IncDir)) { New-Item -ItemType Directory -Force -Path $IncDir | Out-Null }
    Copy-Item "$InstInclude\*" $IncDir -Recurse -Force
    Write-Ok "Headers copied to $IncDir"
}

# ── Copy espeak-ng-data ───────────────────────────────────────────────────────
$DataDest = Join-Path $ShareDir "espeak-ng-data"
if (-not (Test-Path $DataDest)) {
    foreach ($candidate in @(
        (Join-Path $InstDir "share\espeak-ng-data"),
        (Join-Path $SrcDir  "espeak-ng-data"),
        (Join-Path $BldDir  "espeak-ng-data")
    )) {
        if (Test-Path $candidate) {
            New-Item -ItemType Directory -Force -Path $ShareDir | Out-Null
            Copy-Item $candidate $DataDest -Recurse -Force
            Write-Ok "espeak-ng-data copied to $DataDest"
            break
        }
    }
}

# ── Stamp ─────────────────────────────────────────────────────────────────────
$EspeakVersion | Out-File -FilePath $StampFile -Encoding ascii -NoNewline

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "────────────────────────────────────────────────────" -ForegroundColor White
Write-Host "  espeak-ng $EspeakVersion for Windows MSVC ready!" -ForegroundColor Green
Write-Host ""
Write-Host "  Library : $MergedLib"
if (Test-Path $DataDest) { Write-Host "  Data    : $DataDest" }
Write-Host ""
Write-Host "  Build with:" -ForegroundColor White
Write-Host "    `$env:ESPEAK_LIB_DIR = '$LibDir'"
Write-Host "    cargo build --features espeak"
Write-Host ""
Write-Host "  Or add to .cargo\config.toml:"
Write-Host "    [env]"
Write-Host "    ESPEAK_LIB_DIR = { value = `"espeak-static/lib`", relative = true }"
Write-Host "────────────────────────────────────────────────────" -ForegroundColor White
