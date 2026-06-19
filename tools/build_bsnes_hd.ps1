<#
.SYNOPSIS
  One-step rebuild of the bundled ZAMN-DX bsnes-hd libretro core.

.DESCRIPTION
  Automates the repetitive core rebuild:
    1. Ensures the ZAMN-DX C++ changes (tools\bsnes_hd_libretro_wram.patch) are
       applied to the bsnes-hd source tree (.tools\bsnes-hd-src by default).
    2. Compiles the libretro target with MinGW make
       (mingw32-make -j N -C bsnes target=libretro) -> bsnes\out\bsnes_hd_beta_libretro.dll.
    3. Bakes the ZAMN-DX core-option defaults into the DLL with
       tools\build_bsnes_hd_core.py -> mod\bsnes_hd_beta_zamndx_libretro.dll.
    4. (Default) Deploys the result into any staged test runtime under
       dist\release\*\runtime\BizHawk\Libretro\Cores so you can launch and test
       immediately. The launcher regenerates the 16:10 variant from this core on
       each run, so replacing the bundled core is all that is needed.

  Requires a MinGW-w64 toolchain (mingw32-make + g++) and Python 3. Run it from a
  shell where those are on PATH, or pass -MingwBin / -Make / -Compiler.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\build_bsnes_hd.ps1

.EXAMPLE
  # Force a full rebuild and point at a specific MinGW bin directory:
  powershell -ExecutionPolicy Bypass -File tools\build_bsnes_hd.ps1 -Clean -MingwBin "C:\msys64\mingw64\bin"
#>
[CmdletBinding()]
param(
    [string]   $Source,
    [string]   $Output,
    [string]   $Make,
    [string]   $Compiler,
    [string]   $MingwBin,
    [int]      $Jobs = 0,
    [switch]   $Clean,
    [switch]   $SkipPatchSync,
    [switch]   $NoDeploy,
    [string[]] $DeployTo
)

$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host $m -ForegroundColor Cyan }
function Ok($m)   { Write-Host $m -ForegroundColor Green }
function Fail($m) { Write-Host $m -ForegroundColor Red; exit 1 }

function Find-Tool([string[]] $names) {
    foreach ($n in $names) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    return $null
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Source) { $Source = Join-Path $repoRoot '.tools\bsnes-hd-src' }
if (-not $Output) { $Output = Join-Path $repoRoot 'mod\bsnes_hd_beta_zamndx_libretro.dll' }
$patch      = Join-Path $repoRoot 'tools\bsnes_hd_libretro_wram.patch'
$coreScript = Join-Path $repoRoot 'tools\build_bsnes_hd_core.py'

$resolvedSource = Resolve-Path -LiteralPath $Source -ErrorAction SilentlyContinue
if ($resolvedSource) { $Source = $resolvedSource.Path }
if (-not (Test-Path (Join-Path $Source 'bsnes\GNUmakefile'))) {
    Fail "bsnes-hd source not found at: $Source`n(expected bsnes\GNUmakefile). Pass -Source <path-to-bsnes-hd-src>."
}
$builtDll = Join-Path $Source 'bsnes\out\bsnes_hd_beta_libretro.dll'

# --- toolchain -----------------------------------------------------------------
if ($MingwBin) {
    if (-not (Test-Path $MingwBin)) { Fail "-MingwBin directory not found: $MingwBin" }
    $env:PATH = (Resolve-Path -LiteralPath $MingwBin).Path + ';' + $env:PATH
}

if (-not $Make) {
    $Make = Find-Tool @('mingw32-make', 'make')
    if (-not $Make) {
        Fail "No 'mingw32-make' or 'make' on PATH.`nInstall MinGW-w64 (or run from your MinGW/MSYS2 shell), or pass -Make / -MingwBin."
    }
} else {
    $resolvedMake = Find-Tool @($Make)
    if ($resolvedMake) { $Make = $resolvedMake }
    elseif (-not (Test-Path $Make)) { Fail "-Make not found: $Make" }
}

if (-not $Compiler -and -not (Find-Tool @('g++'))) {
    Fail "No 'g++' on PATH (the bsnes-hd makefile invokes it directly).`nRun from your MinGW-w64 environment, or pass -MingwBin <dir-with-g++> or -Compiler <path-to-g++>."
}

$python = Find-Tool @('python', 'py')
if (-not $python) { Fail "No 'python' on PATH (needed for tools\build_bsnes_hd_core.py)." }

# --- keep the source tree in sync with the canonical patch ---------------------
if (-not $SkipPatchSync) {
    if (-not (Test-Path $patch)) { Fail "Patch file not found: $patch" }
    $git = Find-Tool @('git')
    if ((Test-Path (Join-Path $Source '.git')) -and $git) {
        Push-Location $Source
        try {
            git --no-pager apply --reverse --check --whitespace=nowarn -- "$patch" 2>$null
            if ($LASTEXITCODE -eq 0) {
                Info "Source tree already has the ZAMN-DX changes applied."
            } else {
                git --no-pager apply --check --whitespace=nowarn -- "$patch" 2>$null
                if ($LASTEXITCODE -eq 0) {
                    git --no-pager apply --whitespace=nowarn -- "$patch"
                    if ($LASTEXITCODE -ne 0) { Fail "git apply failed for $patch" }
                    Ok "Applied ZAMN-DX changes to the source tree."
                } else {
                    Fail "Source tree is not in a clean state for the ZAMN-DX patch (neither already-applied nor cleanly applicable).`nResolve the tree manually, or pass -SkipPatchSync to build it as-is."
                }
            }
        } finally { Pop-Location }
    } else {
        Write-Warning "Source is not a git checkout (or git is missing); cannot verify the patch. Ensure tools\bsnes_hd_libretro_wram.patch is applied, or pass -SkipPatchSync."
    }
}

# --- compile -------------------------------------------------------------------
if ($Jobs -le 0) {
    $Jobs = [int]$env:NUMBER_OF_PROCESSORS
    if ($Jobs -le 0) { $Jobs = 4 }
}
$makeArgs = @('-C', 'bsnes', 'target=libretro')
if ($Compiler) { $makeArgs += "compiler=$Compiler" }

Push-Location $Source
try {
    if ($Clean) {
        Info "make clean ..."
        & $Make @makeArgs clean
    }
    Info "Compiling libretro core: $Make -j$Jobs $($makeArgs -join ' ')"
    & $Make "-j$Jobs" @makeArgs
    if ($LASTEXITCODE -ne 0) { Fail "bsnes-hd libretro build failed (exit $LASTEXITCODE)." }
} finally { Pop-Location }

if (-not (Test-Path $builtDll)) {
    Fail "Build reported success but the core is missing: $builtDll"
}

# --- bake ZAMN-DX option defaults ---------------------------------------------
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Output) | Out-Null
Info "Baking ZAMN-DX core-option defaults ..."
& $python $coreScript --source $builtDll --output $Output
if ($LASTEXITCODE -ne 0) { Fail "build_bsnes_hd_core.py failed (exit $LASTEXITCODE)." }

# --- deploy into staged test runtime(s) ---------------------------------------
$targets = @()
if ($DeployTo) {
    $targets += $DeployTo
} elseif (-not $NoDeploy) {
    $staged = Resolve-Path -Path (Join-Path $repoRoot 'dist\release\*\runtime\BizHawk\Libretro\Cores') -ErrorAction SilentlyContinue
    foreach ($r in $staged) { $targets += $r.Path }
}
foreach ($t in $targets) {
    if (-not (Test-Path $t)) { New-Item -ItemType Directory -Force -Path $t | Out-Null }
    Copy-Item -LiteralPath $Output -Destination (Join-Path $t 'bsnes_hd_beta_zamndx_libretro.dll') -Force
    Ok "Deployed -> $t"
}

# --- report --------------------------------------------------------------------
$hash = (Get-FileHash -LiteralPath $Output -Algorithm SHA256).Hash
Write-Host ''
Ok 'Done.'
Write-Host "  built core  : $builtDll"
Write-Host "  bundled dll : $Output"
Write-Host "  sha-256     : $hash"
if ($targets.Count -gt 0) {
    Write-Host "  deployed to : $($targets.Count) staged runtime(s) - launch and test."
} else {
    Write-Host "  (not deployed; pass -DeployTo <...\BizHawk\Libretro\Cores> or run a release build to stage it)"
}
