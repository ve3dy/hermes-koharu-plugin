<#
Install the Hermes Koharu plugin on Windows and build its headless runner,
koharu-batch, from Koharu source (Koharu releases ship no headless mode).

  1. Clone the latest Koharu release and verify the commit.
  2. Copy runner\ into the Koharu workspace as crates\koharu-batch and build it
     with cargo (skipped when the source stamp is unchanged).
  3. Copy the plugin into Hermes and configure it through the Hermes CLI.

Hermes config is changed only through the Hermes CLI. This script never
rewrites config.yaml. Runs on Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSNativeCommandUseErrorActionPreference = $false

$Usage = @'
Usage: powershell -ExecutionPolicy Bypass -File scripts\install.ps1 [-DryRun] [-Help]

Builds the koharu-batch runner from Koharu source and installs the Koharu
plugin into Hermes. Idempotent: reruns reuse the source checkout and skip the
build when nothing changed.

Needs: Git, Visual Studio Build Tools with the C++ workload, and LLVM (libclang).
  winget install Git.Git
  winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --quiet"
  winget install LLVM.LLVM
Rust is installed with rustup (%USERPROFILE%\.cargo) when cargo is missing.

Options:
  -DryRun   Print every action without changing anything.
  -Help     Show this help.

Environment (defaults in brackets):
  HERMES_HOME        Hermes home                          [%USERPROFILE%\.hermes]
  HERMES_BIN         hermes CLI                           [hermes on PATH]
  KOHARU_HOME        Source checkout + runner binary      [%LOCALAPPDATA%\hermes-koharu]
  KOHARU_EXPORT_DIR  Where translated pages are written   [%USERPROFILE%\Koharu\exports]
  RESTART_GATEWAY    1 = run `hermes gateway restart`     [1]
  LIBCLANG_PATH      Folder holding libclang.dll          [found automatically]
'@

if ($Help) { Write-Host $Usage; exit 0 }

$KoharuRepo = 'https://github.com/koharu-rs/koharu.git'
# The runner uses Koharu's internal crates, which can change between releases.
# The installer builds the latest release. If that fails to build, it falls back
# to this last release known to work.
$KnownGoodTag = '0.83.5'
$KnownGoodCommit = '52bb4f55e2266f72c1523562a583c827ec191ceb'
$RustupUrl = 'https://win.rustup.rs/x86_64'

# ------------------------------------------------------------------- helpers
function Write-Step([string]$Message) { Write-Host "==> $Message" }

function Fail([string]$Message) {
  [Console]::Error.WriteLine("error: $Message")
  exit 1
}

function Join([string[]]$Parts) {
  $path = $Parts[0]
  for ($i = 1; $i -lt $Parts.Count; $i++) { $path = [IO.Path]::Combine($path, $Parts[$i]) }
  $path
}

function Get-EnvOr([string]$Name, [string]$Default) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrEmpty($value)) { $Default } else { $value }
}

function Format-Command([string]$Exe, [string[]]$Arguments) {
  $quoted = foreach ($a in @($Arguments)) {
    if ($a -eq '' -or $a -match '[\s"]') { '"' + $a + '"' } else { $a }
  }
  (@($Exe) + @($quoted)) -join ' '
}

# Run a native command and stop on a non-zero exit, or only print it under -DryRun.
function Invoke-Native([string]$Exe, [string[]]$Arguments = @()) {
  if ($DryRun) { Write-Host "[dry-run] $(Format-Command $Exe $Arguments)"; return }
  # Native stderr (git, cargo progress) must never turn into a terminating error.
  $ErrorActionPreference = 'Continue'
  & $Exe @Arguments | Out-Host
  if ($LASTEXITCODE -ne 0) { Fail "command failed (exit $LASTEXITCODE): $(Format-Command $Exe $Arguments)" }
}

# Run a PowerShell action, or only print its description under -DryRun.
function Invoke-Action([string]$Description, [scriptblock]$Action) {
  if ($DryRun) { Write-Host "[dry-run] $Description"; return }
  & $Action | Out-Null
}

# Mirror a directory with robocopy. Exit codes below 8 mean success.
function Sync-Directory([string]$Source, [string]$Destination, [string[]]$ExcludeDirs = @(), [string[]]$ExcludeFiles = @()) {
  $robocopyArgs = @($Source, $Destination, '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:2', '/W:1')
  if ($ExcludeDirs.Count -gt 0) { $robocopyArgs += @('/XD') + $ExcludeDirs }
  if ($ExcludeFiles.Count -gt 0) { $robocopyArgs += @('/XF') + $ExcludeFiles }
  if ($DryRun) { Write-Host "[dry-run] $(Format-Command 'robocopy' $robocopyArgs)"; return }
  $ErrorActionPreference = 'Continue'
  & robocopy @robocopyArgs | Out-Host
  if ($LASTEXITCODE -ge 8) { Fail "robocopy failed (exit $LASTEXITCODE): $Source -> $Destination" }
}

function Find-Application([string]$Name) {
  $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd) { $cmd.Path } else { $null }
}

# ------------------------------------------------------------------- settings
$OnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if (-not $OnWindows -and -not $DryRun) { Fail 'install.ps1 is for Windows. On macOS and Linux run scripts/install.sh' }
$ExeSuffix = if ($OnWindows) { '.exe' } else { '' }

$UserProfileDir = [Environment]::GetFolderPath('UserProfile')
$LocalAppDataDir = [Environment]::GetFolderPath('LocalApplicationData')

$HermesHome = [IO.Path]::GetFullPath((Get-EnvOr 'HERMES_HOME' (Join $UserProfileDir, '.hermes')))
$env:HERMES_HOME = $HermesHome
$KoharuHome = [IO.Path]::GetFullPath((Get-EnvOr 'KOHARU_HOME' (Join $LocalAppDataDir, 'hermes-koharu')))
$ExportDir = Get-EnvOr 'KOHARU_EXPORT_DIR' (Join $UserProfileDir, 'Koharu', 'exports')
if ($ExportDir -match '^~[\\/]') { $ExportDir = Join $UserProfileDir, $ExportDir.Substring(2) }
$ExportDir = [IO.Path]::GetFullPath($ExportDir)
$RestartGateway = Get-EnvOr 'RESTART_GATEWAY' '1'

$PluginSrc = Split-Path -Parent $PSScriptRoot
$PluginDest = Join $HermesHome, 'plugins', 'koharu'
$SettingsKey = 'plugins.entries.koharu.settings'
$KoharuConfig = Join $UserProfileDir, '.koharu', 'config.toml'
$SrcRoot = Join $KoharuHome, 'src'
$BinDir = Join $KoharuHome, 'bin'
$Runner = Join $BinDir, "koharu-batch$ExeSuffix"
$StampFile = Join $BinDir, '.koharu-batch.stamp'

$KoharuTag = ''
$KoharuCommit = ''
$SrcDir = ''
$Cargo = ''

# ----------------------------------------------------------------- validation
if ($RestartGateway -ne '0' -and $RestartGateway -ne '1') { Fail 'RESTART_GATEWAY must be 0 or 1' }
if (-not (Test-Path -LiteralPath (Join $PluginSrc, 'plugin.yaml'))) { Fail "plugin.yaml not found in $PluginSrc" }
if (-not (Test-Path -LiteralPath (Join $PluginSrc, 'runner', 'Cargo.toml'))) { Fail "runner\Cargo.toml not found in $PluginSrc" }
if (-not (Find-Application 'git')) { Fail 'Git is required. Install it with: winget install Git.Git (then open a new terminal)' }

if ($OnWindows) {
  if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    Write-Warning "Koharu ships GPU runtimes for Windows x86_64 only (this machine is $($env:PROCESSOR_ARCHITECTURE))"
  }

  $vswhere = Join ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')), 'Microsoft Visual Studio', 'Installer', 'vswhere.exe'
  $vsPath = $null
  if (Test-Path -LiteralPath $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
  }
  if (-not $vsPath) {
    Fail ('MSVC C++ build tools not found. Install them, then rerun this script:' + [Environment]::NewLine +
      '  winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --quiet"')
  }
  Write-Step "Using MSVC from $vsPath"

  # bindgen needs libclang.dll at build time.
  if (-not (Get-EnvOr 'LIBCLANG_PATH' '')) {
    $llvmBin = Join ([Environment]::GetEnvironmentVariable('ProgramFiles')), 'LLVM', 'bin'
    $clang = Find-Application 'clang.exe'
    if (Test-Path -LiteralPath (Join $llvmBin, 'libclang.dll')) {
      $env:LIBCLANG_PATH = $llvmBin
    } elseif ($clang -and (Test-Path -LiteralPath (Join (Split-Path -Parent $clang), 'libclang.dll'))) {
      $env:LIBCLANG_PATH = Split-Path -Parent $clang
    } else {
      Fail ('libclang not found. Install LLVM, then rerun this script (or set LIBCLANG_PATH to the folder holding libclang.dll):' +
        [Environment]::NewLine + '  winget install LLVM.LLVM')
    }
  }
  Write-Step "Using libclang from $env:LIBCLANG_PATH"
} else {
  Write-Step 'Dry run on a non-Windows host, the MSVC and libclang checks are skipped'
}

$HermesBin = Get-EnvOr 'HERMES_BIN' ''
if (-not $HermesBin) {
  $HermesBin = Find-Application 'hermes'
  $localHermes = Join $UserProfileDir, '.local', 'bin', "hermes$ExeSuffix"
  if (-not $HermesBin -and (Test-Path -LiteralPath $localHermes)) { $HermesBin = $localHermes }
}
if (-not $HermesBin) {
  if (-not $DryRun) { Fail 'hermes CLI not found, set HERMES_BIN' }
  $HermesBin = 'hermes'
}

# ----------------------------------------------------------------------- Rust
function Initialize-Rust {
  $cargoBinDir = Join (Get-EnvOr 'CARGO_HOME' (Join $UserProfileDir, '.cargo')), 'bin'
  $fallback = Join $cargoBinDir, "cargo$ExeSuffix"
  $found = Find-Application 'cargo'
  if ($found) {
    $script:Cargo = $found
  } elseif (Test-Path -LiteralPath $fallback) {
    $script:Cargo = $fallback
  } else {
    Write-Step 'Installing Rust with rustup (minimal profile)'
    $init = Join ([IO.Path]::GetTempPath()), 'rustup-init.exe'
    if ($DryRun) {
      Write-Host "[dry-run] download $RustupUrl -> $init"
    } else {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
      Invoke-WebRequest -Uri $RustupUrl -OutFile $init -UseBasicParsing
    }
    Invoke-Native $init @('-y', '--profile', 'minimal')
    Invoke-Action "remove $init" { Remove-Item -LiteralPath $init -Force }
    $script:Cargo = $fallback
  }
  # rustup proxies and build scripts expect the toolchain dir on PATH.
  $env:PATH = (Split-Path -Parent $script:Cargo) + [IO.Path]::PathSeparator + $env:PATH
  Write-Step "Using cargo: $script:Cargo"
}

# --------------------------------------------------------------------- source
# Sets KoharuTag/KoharuCommit to the newest x.y.z release tag upstream.
# Annotated tags list a `^{}` line with the commit, which wins over the tag object.
function Resolve-LatestRelease {
  $ErrorActionPreference = 'Continue'
  $lines = @(& git ls-remote --tags $KoharuRepo)
  if ($LASTEXITCODE -ne 0) { $lines = @() }
  $commits = @{}
  foreach ($line in $lines) {
    $parts = "$line" -split "`t"
    if ($parts.Count -ne 2 -or $parts[1] -notmatch '^refs/tags/(\d+\.\d+\.\d+)(\^\{\})?$') { continue }
    $tag = $Matches[1]
    if ($Matches[2] -or -not $commits.ContainsKey($tag)) { $commits[$tag] = $parts[0].Trim() }
  }
  if ($commits.Count -eq 0) {
    Write-Warning "could not list Koharu releases, using $KnownGoodTag"
    $script:KoharuTag = $KnownGoodTag
    $script:KoharuCommit = $KnownGoodCommit
    return
  }
  $script:KoharuTag = $commits.Keys | Sort-Object { [version]$_ } | Select-Object -Last 1
  $script:KoharuCommit = $commits[$script:KoharuTag]
}

function Sync-KoharuSource {
  $script:SrcDir = Join $SrcRoot, "koharu-$script:KoharuTag"
  if (Test-Path -LiteralPath (Join $script:SrcDir, '.git')) {
    Write-Step "Reusing Koharu source $script:SrcDir"
  } else {
    Write-Step "Cloning Koharu $script:KoharuTag into $script:SrcDir"
    $part = "$script:SrcDir.part"
    Invoke-Action "create $SrcRoot" { New-Item -ItemType Directory -Force -Path $SrcRoot }
    if (Test-Path -LiteralPath $part) {
      Invoke-Action "remove $part" { Remove-Item -LiteralPath $part -Recurse -Force }
    }
    Invoke-Native 'git' @('-c', 'advice.detachedHead=false', 'clone', '--quiet', '--depth', '1',
      '--config', 'core.longpaths=true', '--branch', $script:KoharuTag, $KoharuRepo, $part)
    Invoke-Action "move $part -> $script:SrcDir" { Move-Item -LiteralPath $part -Destination $script:SrcDir }
  }
  if ($DryRun) {
    Write-Host "[dry-run] verify git HEAD == $script:KoharuCommit"
  } else {
    $ErrorActionPreference = 'Continue'
    $head = "$(& git -C $script:SrcDir rev-parse HEAD)".Trim()
    if ($head -ne $script:KoharuCommit) {
      Fail "$script:SrcDir is at $head, expected $script:KoharuCommit (tag $script:KoharuTag). Delete it and rerun"
    }
    Write-Step "Koharu source verified at $script:KoharuCommit"
  }
  Sync-Directory (Join $PluginSrc, 'runner') (Join $script:SrcDir, 'crates', 'koharu-batch')
}

# ---------------------------------------------------------------------- build
# Stamp = Koharu commit + hash of every runner source file (name and content).
function Get-RunnerStamp {
  $root = (Resolve-Path -LiteralPath (Join $PluginSrc, 'runner')).ProviderPath
  $files = @{}
  $items = @(Get-Item -LiteralPath (Join $root, 'Cargo.toml')) + @(Get-ChildItem -LiteralPath (Join $root, 'src') -Recurse -File)
  foreach ($item in $items) { $files[$item.FullName.Substring($root.Length + 1).Replace('\', '/')] = $item.FullName }
  [string[]]$names = @($files.Keys)
  [Array]::Sort($names, [StringComparer]::Ordinal)
  $utf8 = [Text.UTF8Encoding]::new($false)
  $buffer = [IO.MemoryStream]::new()
  foreach ($name in $names) {
    $header = $utf8.GetBytes("$name`n")
    $buffer.Write($header, 0, $header.Length)
    $content = [IO.File]::ReadAllBytes($files[$name])
    $buffer.Write($content, 0, $content.Length)
  }
  $sha = [Security.Cryptography.SHA256]::Create()
  $digest = -join ($sha.ComputeHash($buffer.ToArray()) | ForEach-Object { $_.ToString('x2') })
  "$script:KoharuCommit`n$digest"
}

# Returns $false if cargo fails, so the caller can fall back.
function Build-Runner {
  $stamp = Get-RunnerStamp
  if ((Test-Path -LiteralPath $Runner) -and (Test-Path -LiteralPath $StampFile) -and
      ((Get-Content -LiteralPath $StampFile -Raw) -replace "`r", '').Trim() -eq $stamp) {
    Write-Step "koharu-batch is up to date for Koharu $script:KoharuTag, build skipped"
    return $true
  }
  Write-Step "Building koharu-batch against Koharu $script:KoharuTag (first build takes a while)"
  $targetDir = Join $script:SrcDir, 'target'
  if ($DryRun) {
    Write-Host "[dry-run] in ${script:SrcDir}: CARGO_TARGET_DIR=$targetDir $(Format-Command $script:Cargo @('build', '--release', '-p', 'koharu-batch'))"
  } else {
    $ErrorActionPreference = 'Continue'
    $previousTarget = [Environment]::GetEnvironmentVariable('CARGO_TARGET_DIR')
    $env:CARGO_TARGET_DIR = $targetDir
    Push-Location -LiteralPath $script:SrcDir
    try {
      & $script:Cargo build --release -p koharu-batch | Out-Host
      $built = $LASTEXITCODE -eq 0
    } finally {
      Pop-Location
      [Environment]::SetEnvironmentVariable('CARGO_TARGET_DIR', $previousTarget)
    }
    $ErrorActionPreference = 'Stop'
    if (-not $built) { return $false }
  }
  $artifact = Join $targetDir, 'release', "koharu-batch$ExeSuffix"
  Invoke-Action "create $BinDir" { New-Item -ItemType Directory -Force -Path $BinDir }
  Invoke-Action "copy $artifact -> $Runner" {
    Copy-Item -LiteralPath $artifact -Destination "$Runner.part" -Force
    Move-Item -LiteralPath "$Runner.part" -Destination $Runner -Force
  }
  Invoke-Action "write $StampFile" { [IO.File]::WriteAllText($StampFile, $stamp) }
  return $true
}

# Keep only the source tree that was just built (each is several GB with build cache).
function Remove-OtherSources {
  if (-not (Test-Path -LiteralPath $SrcRoot)) { return }
  foreach ($dir in @(Get-ChildItem -LiteralPath $SrcRoot -Directory -Filter 'koharu-*')) {
    if ($dir.FullName -ne $script:SrcDir) {
      $path = $dir.FullName
      Invoke-Action "remove $path" { Remove-Item -LiteralPath $path -Recurse -Force }
    }
  }
}

function Get-RunnerVersion {
  $ErrorActionPreference = 'Continue'
  $version = "$(& $Runner --version)".Trim()
  if ($LASTEXITCODE -ne 0 -or -not $version) { Fail "$Runner --version failed" }
  $version
}

# --------------------------------------------------------------------- Hermes
function Install-Plugin {
  Write-Step "Copying plugin to $PluginDest"
  Sync-Directory $PluginSrc $PluginDest `
    -ExcludeDirs @('.git', '.github', '__pycache__', '.pytest_cache', 'tests', 'scripts', 'runner', 'assets') `
    -ExcludeFiles @('.DS_Store')

  Write-Step "Configuring Hermes via $HermesBin (HERMES_HOME=$HermesHome)"
  Invoke-Native $HermesBin @('plugins', 'enable', 'koharu', '--no-allow-tool-override')
  Invoke-Native $HermesBin @('config', 'set', "$SettingsKey.runner", $Runner)
  Invoke-Native $HermesBin @('config', 'set', "$SettingsKey.export_dir", $ExportDir)
  Invoke-Native $HermesBin @('config', 'set', "$SettingsKey.timeout", '3600')
  Invoke-Native $HermesBin @('tools', 'enable', '--platform', 'cli', 'koharu')
  Invoke-Native $HermesBin @('tools', 'enable', '--platform', 'telegram', 'koharu')
  Invoke-Action "create $ExportDir" { New-Item -ItemType Directory -Force -Path $ExportDir }
}

# ----------------------------------------------------------------------- main
if ($DryRun) { Write-Step 'Dry run: nothing will be changed' }
Write-Step "Koharu runner on Windows, KOHARU_HOME=$KoharuHome"

Initialize-Rust
Resolve-LatestRelease
Write-Step "Latest Koharu release: $KoharuTag"
Sync-KoharuSource
if (-not (Build-Runner)) {
  if ($KoharuTag -eq $KnownGoodTag) { Fail "koharu-batch failed to build against Koharu $KoharuTag" }
  Write-Warning "koharu-batch does not build against Koharu $KoharuTag yet, using $KnownGoodTag"
  $KoharuTag = $KnownGoodTag
  $KoharuCommit = $KnownGoodCommit
  Sync-KoharuSource
  if (-not (Build-Runner)) { Fail "koharu-batch failed to build against Koharu $KoharuTag" }
}
Remove-OtherSources

if ($DryRun) {
  $RunnerVersion = 'dry run'
  Write-Host "[dry-run] $Runner --version"
} else {
  $RunnerVersion = Get-RunnerVersion
  Write-Step "Smoke test: $RunnerVersion"
}

Install-Plugin

if (-not (Test-Path -LiteralPath $KoharuConfig)) {
  Write-Warning "$KoharuConfig not found. The translation model, provider and target language come from it: set them in the Koharu desktop app (Settings) or create the file. Without it Koharu downloads its default local model on the first run."
}

if ($RestartGateway -eq '1') {
  Write-Step 'Restarting the Hermes gateway'
  Invoke-Native $HermesBin @('gateway', 'restart')
} else {
  Write-Step "Gateway not restarted (RESTART_GATEWAY=0). Run: $HermesBin gateway restart"
}

Write-Host @"

Koharu $KoharuTag runner installed for Hermes.
  Runner:   $Runner ($RunnerVersion)
  Exports:  $ExportDir
  Config:   $KoharuConfig (shared with the Koharu desktop app)
  Plugin:   $PluginDest
Next: ask Hermes "translate the manga pages in <folder>".
"@
exit 0
