<#
Remove the Hermes Koharu plugin and its koharu-batch runner on Windows
(counterpart of install.ps1). Koharu's own config and model cache are shared
with the Koharu desktop app and are never deleted.
Runs on Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$Purge,
  [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$Usage = @'
Usage: powershell -ExecutionPolicy Bypass -File scripts\uninstall.ps1 [-DryRun] [-Purge] [-Help]

Disables the koharu plugin in Hermes, removes its Hermes settings, the plugin
directory and the koharu-batch runner. Exports are kept.

Options:
  -DryRun   Print every action without changing anything.
  -Purge    Also remove KOHARU_HOME entirely (Koharu source + build cache).
  -Help     Show this help.

Environment: HERMES_HOME, HERMES_BIN, KOHARU_HOME, RESTART_GATEWAY [1]
(same meaning as in install.ps1).

Never touched (shared with the Koharu desktop app): %USERPROFILE%\.koharu and
the Koharu model cache (%LOCALAPPDATA%\koharu).
'@

if ($Help) { Write-Host $Usage; exit 0 }

function Write-Step([string]$Message) { Write-Host "==> $Message" }

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

$OnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if (-not $OnWindows -and -not $DryRun) {
  [Console]::Error.WriteLine('error: uninstall.ps1 is for Windows. On macOS and Linux run scripts/uninstall.sh')
  exit 1
}
$ExeSuffix = if ($OnWindows) { '.exe' } else { '' }

$UserProfileDir = [Environment]::GetFolderPath('UserProfile')
$LocalAppDataDir = [Environment]::GetFolderPath('LocalApplicationData')
$HermesHome = [IO.Path]::GetFullPath((Get-EnvOr 'HERMES_HOME' (Join $UserProfileDir, '.hermes')))
$env:HERMES_HOME = $HermesHome
$KoharuHome = [IO.Path]::GetFullPath((Get-EnvOr 'KOHARU_HOME' (Join $LocalAppDataDir, 'hermes-koharu')))
$RestartGateway = Get-EnvOr 'RESTART_GATEWAY' '1'
$PluginDest = Join $HermesHome, 'plugins', 'koharu'
$KoharuCache = Join $LocalAppDataDir, 'koharu'

$HermesBin = Get-EnvOr 'HERMES_BIN' ''
if (-not $HermesBin) {
  $cmd = Get-Command 'hermes' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  $localHermes = Join $UserProfileDir, '.local', 'bin', "hermes$ExeSuffix"
  if ($cmd) { $HermesBin = $cmd.Path } elseif (Test-Path -LiteralPath $localHermes) { $HermesBin = $localHermes }
}

# Run (or print under -DryRun) a hermes command. A failure is only reported.
function Invoke-Hermes([string[]]$Arguments) {
  if (-not $HermesBin) { Write-Warning "hermes CLI not found (set HERMES_BIN), skipped: hermes $($Arguments -join ' ')"; return }
  if ($DryRun) { Write-Host "[dry-run] $(Format-Command $HermesBin $Arguments)"; return }
  $ErrorActionPreference = 'Continue'
  & $HermesBin @Arguments | Out-Host
  if ($LASTEXITCODE -ne 0) { Write-Warning "ignored failure (exit $LASTEXITCODE): $(Format-Command $HermesBin $Arguments)" }
}

# Remove a directory tree (or print under -DryRun). A failure is only reported.
function Remove-Tree([string]$Path) {
  if ($DryRun) { Write-Host "[dry-run] remove $Path"; return }
  if (-not (Test-Path -LiteralPath $Path)) { return }
  try { Remove-Item -LiteralPath $Path -Recurse -Force }
  catch { Write-Warning "ignored failure: could not remove $Path ($($_.Exception.Message))" }
}

if ($DryRun) { Write-Step 'Dry run: nothing will be changed' }

Write-Step "Removing the koharu plugin from Hermes (HERMES_HOME=$HermesHome)"
Invoke-Hermes @('plugins', 'disable', 'koharu')
Invoke-Hermes @('config', 'unset', 'plugins.entries.koharu')
Remove-Tree $PluginDest

if ($Purge) {
  Write-Step "Purging $KoharuHome (runner, Koharu source and build cache)"
  Remove-Tree $KoharuHome
} else {
  Write-Step "Removing the runner $(Join $KoharuHome, 'bin')"
  Remove-Tree (Join $KoharuHome, 'bin')
}

if ($RestartGateway -eq '1') {
  Write-Step 'Restarting the Hermes gateway'
  Invoke-Hermes @('gateway', 'restart')
} else {
  $hermesName = if ($HermesBin) { $HermesBin } else { 'hermes' }
  Write-Step "Gateway not restarted (RESTART_GATEWAY=0). Run: $hermesName gateway restart"
}

Write-Host @"

Koharu plugin and runner removed.
  Kept (shared with the Koharu desktop app):
    $(Join $UserProfileDir, '.koharu')
    $KoharuCache
"@
if (-not $Purge) { Write-Host "  Kept $(Join $KoharuHome, 'src') (Koharu source + build cache, remove with -Purge)" }
exit 0
