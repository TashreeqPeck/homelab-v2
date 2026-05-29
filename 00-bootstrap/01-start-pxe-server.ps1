[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$CommonLoggingScript = Join-Path $RepoRoot '90-scripts/logging/common-logging.ps1'

if (-not (Test-Path -LiteralPath $CommonLoggingScript -PathType Leaf)) {
  throw "Common logging script not found: $CommonLoggingScript"
}

. $CommonLoggingScript
Initialize-LogContext -ScriptPath $MyInvocation.MyCommand.Path

$WslDistro = 'Debian'
$TinyPxeHttpPort = 8000
$TinyPxeRoot = Join-Path $RepoRoot '90-scripts/bootstrap/tinypxeserver'
$TinyPxeZip = Join-Path $TinyPxeRoot 'pxesrv.zip'
$TinyPxeExtractDir = Join-Path $RepoRoot '98-runtime/tinypxeserver/runtime'
$TinyPxeFilesDir = Join-Path $TinyPxeRoot 'files'
$TinyPxeConfigPath = Join-Path $TinyPxeExtractDir 'config.ini'
$TinyPxeMenuName = 'proxmox-menu.ipxe'
$TinyPxeBootFile = 'ipxe-x86_64.efi'
$IsoSearchDir = Join-Path $RepoRoot '99-image'
$PxeOutputDir = Join-Path $RepoRoot '98-runtime/pxe/proxmox-auto'
$AnswerTemplateFile = Join-Path $RepoRoot '00-bootstrap/answer.toml'
$RenderedAnswerFile = Join-Path $PxeOutputDir 'answer.runtime.toml'
$PrepareStatePath = Join-Path $PxeOutputDir '.prepare-state'
$TinyPxeHttpRoot = $RepoRoot
$PxeRelativeDir = '98-runtime/pxe/proxmox-auto'
$AnswerRelativePath = "$PxeRelativeDir/answer.runtime.toml"
$WslRequireFileScript = Join-Path $RepoRoot '90-scripts/bootstrap/require-wsl-file.sh'
$WslRequireToolsScript = Join-Path $RepoRoot '90-scripts/bootstrap/require-wsl-tools.sh'
$WslValidateAnswerScript = Join-Path $RepoRoot '90-scripts/bootstrap/validate-proxmox-answer.sh'
$WslPrepareIsoScript = Join-Path $RepoRoot '90-scripts/bootstrap/prepare-proxmox-iso.sh'
$WslBuildInitrdScript = Join-Path $RepoRoot '90-scripts/bootstrap/build-custom-initrd.sh'

function Write-PrepareState {
  param(
    [string]$IsoSha256,
    [string]$AnswerUrl,
    [string]$PrepareStatus,
    [string]$InitrdSha256,
    [string]$PreparedIsoSha256
  )

  $lines = @(
    "ISO_SHA256=$IsoSha256"
    "ANSWER_URL=$AnswerUrl"
    "PREPARE_STATUS=$PrepareStatus"
  )

  if (-not [string]::IsNullOrWhiteSpace($InitrdSha256)) {
    $lines += "INITRD_SHA256=$InitrdSha256"
  }

  if (-not [string]::IsNullOrWhiteSpace($PreparedIsoSha256)) {
    $lines += "PREPARED_ISO_SHA256=$PreparedIsoSha256"
  }

  $lines | Set-Content -LiteralPath $PrepareStatePath
}

function Get-WslPathFromWindowsPath([string]$Path) {
  $resolved = [System.IO.Path]::GetFullPath($Path)
  if ($resolved -match '^[A-Za-z]:\\') {
    $drive = $resolved.Substring(0, 1).ToLowerInvariant()
    $rest = ($resolved.Substring(2) -replace '\\', '/')
    return "/mnt/$drive$rest"
  }

  Fail "Unable to convert path to WSL form: $Path"
}

function Invoke-WslScript {
  param(
    [string]$ScriptPathWsl,
    [string[]]$Arguments = @()
  )

  $wslArgs = @('-d', $WslDistro, 'bash', $ScriptPathWsl)
  if ($Arguments.Count -gt 0) {
    $wslArgs += $Arguments
  }

  & wsl @wslArgs
}

function Write-RenderedAnswerFile {
  param(
    [string]$TemplatePath,
    [string]$OutputPath
  )

  $opCmd = Get-Command op -ErrorAction SilentlyContinue
  if (-not $opCmd) {
    Fail '1Password CLI (op) was not found in PATH. Install it and run op signin before starting PXE.'
  }

  $content = Get-Content -LiteralPath $TemplatePath -Raw
  if ($content -notmatch 'op://') {
    Fail "Answer template must contain at least one 1Password secret reference (op://...)."
  }

  & $opCmd.Source inject --in-file $TemplatePath --out-file $OutputPath --force 2>$null
  if ($LASTEXITCODE -ne 0) {
    Fail 'Failed to render answer file with 1Password op inject. Ensure op signin is active and references are valid.'
  }

  if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    Fail "Rendered answer file was not created: $OutputPath"
  }
}

function Find-HostIPv4 {
  $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
    Sort-Object -Property RouteMetric, ifMetric |
    Select-Object -First 1

  if (-not $defaultRoute) {
    Fail 'Could not determine default IPv4 route.'
  }

  $ip = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $defaultRoute.InterfaceIndex |
    Where-Object {
      $_.IPAddress -notlike '169.254.*' -and
      $_.IPAddress -ne '127.0.0.1'
    } |
    Select-Object -First 1 -ExpandProperty IPAddress

  if (-not $ip) {
    Fail 'Could not determine host IPv4 address.'
  }

  return $ip
}

function Get-OccupiedPorts([int[]]$Ports) {
  $endpoints = Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -in $Ports }

  foreach ($endpoint in $endpoints) {
    $process = Get-Process -Id $endpoint.OwningProcess -ErrorAction SilentlyContinue
    [pscustomobject]@{
      Port = $endpoint.LocalPort
      ProcessId = $endpoint.OwningProcess
      ProcessName = if ($process) { $process.ProcessName } else { '<unknown>' }
    }
  }
}

if ($args.Count -gt 0) {
  Fail 'This script does not accept arguments. Edit variables at the top of the file instead.'
}

if (-not (Test-Path -LiteralPath $AnswerTemplateFile -PathType Leaf)) {
  Fail "Answer template not found: $AnswerTemplateFile"
}

$requiredWslScripts = @(
  $WslRequireFileScript,
  $WslRequireToolsScript,
  $WslValidateAnswerScript,
  $WslPrepareIsoScript,
  $WslBuildInitrdScript
)

foreach ($script in $requiredWslScripts) {
  if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
    Fail "Required helper script not found: $script"
  }
}

if (-not (Test-Path -LiteralPath $TinyPxeFilesDir -PathType Container)) {
  Fail "TinyPXE files directory not found: $TinyPxeFilesDir"
}

if (-not (Test-Path -LiteralPath $IsoSearchDir -PathType Container)) {
  Fail "ISO search directory not found: $IsoSearchDir"
}

$iso = Get-ChildItem -LiteralPath $IsoSearchDir -File -Filter 'proxmox*.iso' |
  Sort-Object Name |
  Select-Object -Last 1

if (-not $iso) {
  $iso = Get-ChildItem -LiteralPath $IsoSearchDir -File -Filter '*.iso' |
    Sort-Object Name |
    Select-Object -Last 1
}

if (-not $iso) {
  Fail "No ISO found in $IsoSearchDir"
}

if (-not (Test-Path -LiteralPath $PxeOutputDir -PathType Container)) {
  New-Item -ItemType Directory -Path $PxeOutputDir -Force | Out-Null
}

Write-RenderedAnswerFile -TemplatePath $AnswerTemplateFile -OutputPath $RenderedAnswerFile

$staleTinyPxe = Get-Process -Name 'pxesrv' -ErrorAction SilentlyContinue
if ($staleTinyPxe) {
  Write-Log "Stopping stale TinyPXE process(es): $($staleTinyPxe.Id -join ', ')"
  $staleTinyPxe | Stop-Process -Force
}

$occupiedPorts = @(Get-OccupiedPorts -Ports @(67, 69))
if ($occupiedPorts.Count -gt 0) {
  $conflicts = $occupiedPorts | ForEach-Object { "UDP $($_.Port) owned by $($_.ProcessName) (PID $($_.ProcessId))" }
  Fail ("PXE ports are already in use:`n" + ($conflicts -join "`n") + "`nStop the conflicting service and run the script again.")
}

$hostIp = Find-HostIPv4
$answerUrl = "http://$hostIp`:$TinyPxeHttpPort/$AnswerRelativePath"
$tinyPxeMenuFile = Join-Path $PxeOutputDir $TinyPxeMenuName
$tinyPxeBootSource = Join-Path $TinyPxeFilesDir $TinyPxeBootFile
$tinyPxeBootTarget = Join-Path $PxeOutputDir $TinyPxeBootFile

$isoWsl = Get-WslPathFromWindowsPath $iso.FullName
$outputWsl = Get-WslPathFromWindowsPath $PxeOutputDir
$answerFileWsl = Get-WslPathFromWindowsPath $RenderedAnswerFile
$wslRequireFileScript = Get-WslPathFromWindowsPath $WslRequireFileScript
$wslRequireToolsScript = Get-WslPathFromWindowsPath $WslRequireToolsScript
$wslValidateAnswerScript = Get-WslPathFromWindowsPath $WslValidateAnswerScript
$wslPrepareIsoScript = Get-WslPathFromWindowsPath $WslPrepareIsoScript
$wslBuildInitrdScript = Get-WslPathFromWindowsPath $WslBuildInitrdScript

Invoke-WslScript -ScriptPathWsl $wslRequireFileScript -Arguments @($isoWsl)
if ($LASTEXITCODE -ne 0) {
  Fail "WSL cannot access ISO path: $isoWsl"
}

Invoke-WslScript -ScriptPathWsl $wslRequireToolsScript -Arguments @('zstd', 'cpio')
if ($LASTEXITCODE -ne 0) {
  Fail "WSL dependencies missing: zstd and/or cpio. Run ./00-bootstrap/00-install-dependencies.ps1 first."
}

Invoke-WslScript -ScriptPathWsl $wslValidateAnswerScript -Arguments @($answerFileWsl)
if ($LASTEXITCODE -ne 0) {
  Fail 'Rendered answer file validation failed. Fix the template or secret references before generating PXE assets.'
}


$currentIsoSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $iso.FullName).Hash
$currentAnswerUrl = $answerUrl

$lastIsoSha256 = ''
$lastAnswerUrl = ''
$lastPrepareStatus = ''
$lastInitrdSha256 = ''
$lastPreparedIsoSha256 = ''

if (Test-Path -LiteralPath $PrepareStatePath -PathType Leaf) {
  foreach ($line in (Get-Content -LiteralPath $PrepareStatePath)) {
    if ($line -match '^ISO_SHA256=(.+)$') {
      $lastIsoSha256 = $Matches[1].Trim()
    }
    elseif ($line -match '^ANSWER_URL=(.+)$') {
      $lastAnswerUrl = $Matches[1].Trim()
    }
    elseif ($line -match '^PREPARE_STATUS=(.+)$') {
      $lastPrepareStatus = $Matches[1].Trim().ToLowerInvariant()
    }
    elseif ($line -match '^INITRD_SHA256=(.+)$') {
      $lastInitrdSha256 = $Matches[1].Trim()
    }
    elseif ($line -match '^PREPARED_ISO_SHA256=(.+)$') {
      $lastPreparedIsoSha256 = $Matches[1].Trim()
    }
  }
}

$needsPrepare = $false
$rebuildReasons = @()

if (-not (Test-Path -LiteralPath $PrepareStatePath -PathType Leaf)) {
  $needsPrepare = $true
  $rebuildReasons += 'no previous prepare state'
}

# If previous run did not explicitly complete prepare-iso, force a rebuild.
if ((Test-Path -LiteralPath $PrepareStatePath -PathType Leaf) -and $lastPrepareStatus -ne 'success') {
  $needsPrepare = $true
  $rebuildReasons += 'previous prepare did not complete successfully'
}

if ($currentIsoSha256 -ne $lastIsoSha256) {
  $needsPrepare = $true
  $rebuildReasons += 'ISO changed'
}

if ($currentAnswerUrl -ne $lastAnswerUrl) {
  $needsPrepare = $true
  $rebuildReasons += 'network/answer URL changed'
}

if ($needsPrepare) {
  Write-Log "Preparing PXE assets in WSL..."
  Write-Log "  Reason:     $($rebuildReasons -join '; ')"
  Write-Log "  ISO:        $($iso.FullName)"
  Write-Log "  Output:     $PxeOutputDir"
  Write-Log "  Answer URL: $answerUrl"

  Write-PrepareState -IsoSha256 $currentIsoSha256 -AnswerUrl $currentAnswerUrl -PrepareStatus 'in-progress' -InitrdSha256 $lastInitrdSha256 -PreparedIsoSha256 $lastPreparedIsoSha256

  Invoke-WslScript -ScriptPathWsl $wslPrepareIsoScript -Arguments @($isoWsl, $answerUrl, $outputWsl)
  if ($LASTEXITCODE -ne 0) {
    Fail 'WSL prepare-iso command failed.'
  }

  Write-PrepareState -IsoSha256 $currentIsoSha256 -AnswerUrl $currentAnswerUrl -PrepareStatus 'success' -InitrdSha256 $lastInitrdSha256 -PreparedIsoSha256 $lastPreparedIsoSha256
}
else {
  Write-Log 'Skipping prepare-iso: ISO/URL unchanged and previous prepare completed successfully.'
}

$effectivePrepareStatus = if ($needsPrepare) { 'success' } else { $lastPrepareStatus }
if ([string]::IsNullOrWhiteSpace($effectivePrepareStatus)) {
  $effectivePrepareStatus = 'success'
}

$requiredPxeFiles = @('vmlinuz', 'initrd.img')
foreach ($required in $requiredPxeFiles) {
  $requiredPath = Join-Path $PxeOutputDir $required
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    Fail "PXE prepare did not generate expected file: $requiredPath"
  }
}

$preparedIso = Get-ChildItem -LiteralPath $PxeOutputDir -File -Filter 'proxmox*.iso' |
  Sort-Object Name |
  Select-Object -Last 1
if (-not $preparedIso) {
  Fail "PXE prepare did not generate expected Proxmox ISO payload in $PxeOutputDir"
}

$customInitrdName = 'custom-initrd.img'
$customInitrdPath = Join-Path $PxeOutputDir $customInitrdName
$initrdSourcePath = Join-Path $PxeOutputDir 'initrd.img'
$initrdSourceWsl = Get-WslPathFromWindowsPath $initrdSourcePath
$preparedIsoWsl = Get-WslPathFromWindowsPath $preparedIso.FullName
$customInitrdWsl = Get-WslPathFromWindowsPath $customInitrdPath

$currentInitrdSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $initrdSourcePath).Hash
$currentPreparedIsoSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $preparedIso.FullName).Hash

$needsCustomInitrdBuild = $false
if (-not (Test-Path -LiteralPath $customInitrdPath -PathType Leaf)) {
  $needsCustomInitrdBuild = $true
}
elseif ($currentInitrdSha256 -ne $lastInitrdSha256) {
  $needsCustomInitrdBuild = $true
}
elseif ($currentPreparedIsoSha256 -ne $lastPreparedIsoSha256) {
  $needsCustomInitrdBuild = $true
}

if ($needsCustomInitrdBuild) {
  Write-Log 'Building custom initrd with embedded proxmox.iso...'
  Invoke-WslScript -ScriptPathWsl $wslBuildInitrdScript -Arguments @($initrdSourceWsl, $preparedIsoWsl, $customInitrdWsl)
  if ($LASTEXITCODE -ne 0) {
    Fail 'Failed to build custom initrd with embedded proxmox.iso.'
  }

  Write-PrepareState -IsoSha256 $currentIsoSha256 -AnswerUrl $currentAnswerUrl -PrepareStatus $effectivePrepareStatus -InitrdSha256 $currentInitrdSha256 -PreparedIsoSha256 $currentPreparedIsoSha256
}
else {
  Write-Log 'Skipping custom initrd rebuild: initrd source and embedded ISO are unchanged.'
}

if (-not (Test-Path -LiteralPath $customInitrdPath -PathType Leaf)) {
  Fail "Custom initrd was not created: $customInitrdPath"
}

if (-not (Test-Path -LiteralPath $tinyPxeBootSource -PathType Leaf)) {
  Fail "TinyPXE boot file not found: $tinyPxeBootSource"
}

Copy-Item -LiteralPath $tinyPxeBootSource -Destination $tinyPxeBootTarget -Force

# Boot via a custom initrd that contains /proxmox.iso.
# This follows the known working forum approach for Proxmox PXE auto-install.
$menuContent = @(
  '#!ipxe'
  "set boot-url http://$hostIp`:$TinyPxeHttpPort/$PxeRelativeDir"
  "kernel --timeout 60000 `${boot-url}/vmlinuz ramdisk_size=16777216 rw quiet initrd=$customInitrdName splash=silent proxmox-start-auto-installer"
  "initrd --timeout 300000 `${boot-url}/$customInitrdName"
  'boot'
)

Set-Content -LiteralPath $tinyPxeMenuFile -Value ($menuContent -join "`r`n") -NoNewline

if (-not (Test-Path -LiteralPath $TinyPxeZip -PathType Leaf)) {
  Fail "TinyPXE zip not found: $TinyPxeZip"
}

if (-not (Test-Path -LiteralPath $TinyPxeExtractDir -PathType Container)) {
  New-Item -ItemType Directory -Path $TinyPxeExtractDir -Force | Out-Null
}

if (-not (Test-Path -LiteralPath (Join-Path $TinyPxeExtractDir 'pxesrv.exe') -PathType Leaf)) {
  Expand-Archive -LiteralPath $TinyPxeZip -DestinationPath $TinyPxeExtractDir -Force
}

$tinyExe = Join-Path $TinyPxeExtractDir 'pxesrv.exe'
if (-not (Test-Path -LiteralPath $tinyExe -PathType Leaf)) {
  Fail "TinyPXE executable not found: $tinyExe"
}

try {
  Unblock-File -LiteralPath $tinyExe -ErrorAction SilentlyContinue
}
catch {
}

$tinyConfig = @"
[arch]
00007=$TinyPxeBootFile
00009=$TinyPxeBootFile

[dhcp]
rfc951=1
root=$TinyPxeHttpRoot
filename=$PxeRelativeDir/$TinyPxeBootFile
altfilename=$PxeRelativeDir/$TinyPxeMenuName
proxybootfilename=$PxeRelativeDir/$TinyPxeBootFile
httpd=1
binl=0
start=1
dnsd=0
proxydhcp=1
bind=1
smb=0
log=1

[web]
port=$TinyPxeHttpPort
"@

Set-Content -LiteralPath $TinyPxeConfigPath -Value $tinyConfig -NoNewline

Write-Log "Launching TinyPXE Server..."
Write-Log "  EXE:    $tinyExe"
Write-Log "  Config: $TinyPxeConfigPath"
Write-Log "  TFTP/HTTP root: $TinyPxeHttpRoot"
Write-Log "  Menu:   $tinyPxeMenuFile"
Write-Log "  Answer template: $AnswerTemplateFile"
Write-Log "  Rendered answer: $RenderedAnswerFile"

try {
  $tinyProcess = Start-Process -FilePath $tinyExe -WorkingDirectory $TinyPxeExtractDir -PassThru
}
catch {
  if ($_.Exception.Message -match 'Access is denied') {
    Fail "TinyPXE launch failed with 'Access is denied'. Unblock '$tinyExe' and ensure no other process owns the required PXE ports."
  }
  throw
}

Write-Log "Answer endpoint: $answerUrl"
Write-Log 'TinyPXE started. Close TinyPXE window when finished.'

Wait-Process -Id $tinyProcess.Id