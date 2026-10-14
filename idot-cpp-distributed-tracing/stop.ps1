#Requires -Version 5.1
<#
.SYNOPSIS
    Stops all services started by run.ps1.
    Windows equivalent of stop.sh.

.DESCRIPTION
    Reads the PID file written by run.ps1 and terminates each recorded process.
    Then force-frees ports 8080, 8081, and 8082 in case any process survived.

.EXAMPLE
    .\stop.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'   # allow "process not found" without throwing

$ScriptDir = $PSScriptRoot
$PidsFile  = Join-Path $ScriptDir ".pids.json"

Write-Host "Stopping services..."

# ── 1. Stop by recorded PIDs (written by run.ps1) ────────────────────────────
if (Test-Path $PidsFile) {
    $pids = Get-Content $PidsFile -Raw | ConvertFrom-Json

    foreach ($entry in $pids.PSObject.Properties) {
        $name = $entry.Name
        $pid  = [int]$entry.Value

        $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host "  Stopping $name (PID $pid)..."
            Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "  $name (PID $pid) is already stopped."
        }
    }

    Remove-Item $PidsFile -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "  No PID file found ($PidsFile). Falling back to port scan."
}

# ── 2. Force-free the ports in case any process survived ─────────────────────
# Equivalent of: fuser -k <port>/tcp  (Linux/AIX stop.sh)
foreach ($port in @(8080, 8081, 8082)) {
    $connections = netstat -ano 2>$null |
        Select-String -Pattern "^\s+TCP\s+\S+:$port\s" |
        ForEach-Object { ($_ -split '\s+')[-1] } |
        Select-Object -Unique

    foreach ($stalePid in $connections) {
        $stalePid = $stalePid.Trim()
        if ($stalePid -match '^\d+$' -and [int]$stalePid -gt 0) {
            $proc = Get-Process -Id $stalePid -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Host "  Killing stale process on port $port (PID $stalePid, $($proc.Name))..."
                Stop-Process -Id $stalePid -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Write-Host "Done."
