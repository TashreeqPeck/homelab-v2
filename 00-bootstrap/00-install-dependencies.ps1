[CmdletBinding()]
param(
	[string]$WslDistro = 'Debian'
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$InstallScript = Join-Path $RepoRoot '90-bootstrap-scripts/bootstrap/install-dependencies.sh'
$CommonLoggingScript = Join-Path $RepoRoot '90-bootstrap-scripts/logging/common-logging.ps1'

if (-not (Test-Path -LiteralPath $CommonLoggingScript -PathType Leaf)) {
	throw "Common logging script not found: $CommonLoggingScript"
}

. $CommonLoggingScript
Initialize-LogContext -ScriptPath $MyInvocation.MyCommand.Path

function Install-Python3 {
	$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
	if (-not $pythonCmd) {
		$pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue
	}

	if ($pythonCmd) {
		Write-Log "Python already installed: $($pythonCmd.Source)"
		return
	}

	Fail 'Python is required for the bootstrap server. Install Python from https://www.python.org/downloads/ and ensure it is in PATH.'
}

function Install-1PasswordCli {
	$opCmd = Get-Command op -ErrorAction SilentlyContinue
	if ($opCmd) {
		Write-Log "1Password CLI already installed: $($opCmd.Source)"
		return
	}

	$wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
	if (-not $wingetCmd) {
		Fail "1Password CLI is not installed and winget was not found. Install 1Password CLI manually from https://developer.1password.com/docs/cli/get-started/."
	}

	Write-Log 'Installing 1Password CLI with winget...'
	& $wingetCmd.Source install --id AgileBits.1Password.CLI --exact --source winget --accept-source-agreements --accept-package-agreements
	if ($LASTEXITCODE -ne 0) {
		Fail 'Failed to install 1Password CLI via winget.'
	}

	$opCmd = Get-Command op -ErrorAction SilentlyContinue
	if (-not $opCmd) {
		Fail '1Password CLI installation completed, but op is not available in PATH yet. Open a new terminal and run the script again.'
	}

	Write-Log "1Password CLI installed: $($opCmd.Source)"
}

if (-not (Test-Path -LiteralPath $InstallScript -PathType Leaf)) {
	Fail "Dependency installer not found: $InstallScript"
}

$installScriptWsl = '/mnt/' + $InstallScript.Substring(0,1).ToLowerInvariant() + $InstallScript.Substring(2).Replace('\','/')

Write-Log "Running dependency bootstrap in WSL distro '$WslDistro'..."
Write-Log "Script: $InstallScript"

wsl -d $WslDistro bash -lc "bash '$installScriptWsl'"
if ($LASTEXITCODE -ne 0) {
	Fail 'Dependency installation failed in WSL.'
}

Install-Python3
Install-1PasswordCli

Write-Log 'Dependencies installed successfully.'