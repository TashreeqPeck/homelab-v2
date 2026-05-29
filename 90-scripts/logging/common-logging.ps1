Set-StrictMode -Version Latest

$script:LogScriptName = 'bootstrap'

function Initialize-LogContext {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptPath
  )

  $script:LogScriptName = Split-Path -Leaf $ScriptPath
}

function Write-Log {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Message,
    [string]$Level = 'INFO'
  )

  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Write-Host "[$ts] [$Level] [$script:LogScriptName] $Message"
}

function Fail {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  throw "[$ts] [ERROR] [$script:LogScriptName] $Message"
}
