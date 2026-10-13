#Requires -Version 5.1
<#
.SYNOPSIS
    Starts all three services of the distributed tracing sample.
    Windows equivalent of run.sh.

.DESCRIPTION
    Starts java-receiver, cpp-service, and java-caller as background jobs,
    redirecting each service's output to a log file under the logs\ directory.
    Use .\stop.ps1 to stop all services cleanly.

.PARAMETER IdotOtelCppInstall
    Root directory of the IDOT OpenTelemetry C++ SDK install.
    Can also be set via the environment variable IDOT_OTEL_CPP_INSTALL.

.PARAMETER OtelAgent
    Path to the OpenTelemetry Java Agent JAR.
    Can also be set via the environment variable OTEL_AGENT.

.PARAMETER CppOtlpEndpoint
    OTLP/gRPC endpoint for cpp-service. Format: bare host:port — no URL scheme.
    Can also be set via the environment variable CPP_OTLP_ENDPOINT.
    Default: localhost:4317

.PARAMETER JavaOtlpEndpoint
    OTLP endpoint for the Java services. Format: full http://host:port URL.
    Can also be set via the environment variable JAVA_OTLP_ENDPOINT.
    Default: http://localhost:4317

.PARAMETER ScheduleEnabled
    When $true, java-caller automatically sends one GET /order every 5 seconds.
    When $false, trigger traces manually with: curl http://<host>:8082/order
    Can also be set via the environment variable SCHEDULE_ENABLED.
    Default: $true

.EXAMPLE
    $env:IDOT_OTEL_CPP_INSTALL = "<path-to-opentelemetry-cpp>"
    $env:OTEL_AGENT             = "<path-to-opentelemetry-javaagent.jar>"
    .\run.ps1

.EXAMPLE
    .\run.ps1 `
        -IdotOtelCppInstall "<path-to-opentelemetry-cpp>" `
        -OtelAgent          "<path-to-opentelemetry-javaagent.jar>" `
        -CppOtlpEndpoint    "<collector-host>:<grpc-port>" `
        -JavaOtlpEndpoint   "http://<collector-host>:<grpc-port>" `
        -ScheduleEnabled    $true
#>

[CmdletBinding()]
param(
    [string]$IdotOtelCppInstall = $env:IDOT_OTEL_CPP_INSTALL,
    [string]$OtelAgent          = $env:OTEL_AGENT,
    [string]$CppOtlpEndpoint    = $(if ($env:CPP_OTLP_ENDPOINT)  { $env:CPP_OTLP_ENDPOINT }  else { 'localhost:4317' }),
    [string]$JavaOtlpEndpoint   = $(if ($env:JAVA_OTLP_ENDPOINT) { $env:JAVA_OTLP_ENDPOINT } else { 'http://localhost:4317' }),
    [bool]  $ScheduleEnabled    = $(if ($env:SCHEDULE_ENABLED)   { [System.Convert]::ToBoolean($env:SCHEDULE_ENABLED) } else { $false })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$LogsDir   = Join-Path $ScriptDir "logs"
$PidsFile  = Join-Path $ScriptDir ".pids.json"

# ── Validate required parameters ─────────────────────────────────────────────
if ([string]::IsNullOrEmpty($IdotOtelCppInstall)) {
    Write-Error @"
IDOT_OTEL_CPP_INSTALL is not set.
Set it to the root directory of the IDOT OpenTelemetry C++ SDK install, e.g.:
  `$env:IDOT_OTEL_CPP_INSTALL = '<path-to-opentelemetry-cpp>'
  .\run.ps1
"@
    exit 1
}

if ([string]::IsNullOrEmpty($OtelAgent)) {
    Write-Error @"
OTEL_AGENT is not set.
Set it to the path of opentelemetry-javaagent.jar, e.g.:
  `$env:OTEL_AGENT = '<path-to-opentelemetry-javaagent.jar>'
Download from:
  https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases
"@
    exit 1
}

if (-not (Test-Path $OtelAgent)) {
    Write-Error "OTEL_AGENT file not found: $OtelAgent"
    exit 1
}

# ── Validate build artifacts ─────────────────────────────────────────────────
$CallerJar   = Join-Path $ScriptDir "java-caller\target\java-caller-1.0.0.jar"
$ReceiverJar = Join-Path $ScriptDir "java-receiver\target\java-receiver-1.0.0.jar"
$CppExe      = Join-Path $ScriptDir "cpp-service\build\Release\cpp-service.exe"

foreach ($artifact in @($CallerJar, $ReceiverJar, $CppExe)) {
    if (-not (Test-Path $artifact)) {
        Write-Error "Artifact missing: $artifact`nRun .\build.ps1 first."
        exit 1
    }
}

# ── Add SDK bin\ to PATH so cpp-service.exe finds the OTel DLLs ──────────────
# This is the Windows equivalent of LD_LIBRARY_PATH (Linux) / LIBPATH (AIX).
$SdkBin = Join-Path $IdotOtelCppInstall "bin"
$env:PATH = "$SdkBin;$env:PATH"

# ── Prepare logs directory ────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null

Write-Host "==========================================="
Write-Host " OTel C++ Distributed Tracing -- Start"
Write-Host "==========================================="
Write-Host "cpp OTLP  : $CppOtlpEndpoint"
Write-Host "Java OTLP : $JavaOtlpEndpoint"
Write-Host "Scheduled : $ScheduleEnabled"
Write-Host "Logs      : $LogsDir\"
Write-Host ""

# ── Helper: start a process, redirect output to a log file, record PID ───────
$pids = @{}

function Start-Service {
    param(
        [string]   $Name,
        [string]   $Executable,
        [string[]] $Arguments,
        [hashtable]$ExtraEnv = @{}
    )

    $logFile = Join-Path $LogsDir "$Name.log"
    Write-Host "  Starting $Name..."

    # Build a ProcessStartInfo so we can inject extra env vars cleanly
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $Executable
    $psi.Arguments              = $Arguments -join ' '
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    # Copy current environment then add any service-specific overrides
    foreach ($kv in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $psi.EnvironmentVariables[$kv.Key] = $kv.Value
    }
    foreach ($kv in $ExtraEnv.GetEnumerator()) {
        $psi.EnvironmentVariables[$kv.Key] = $kv.Value
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    # Async stdout/stderr → log file
    $logStream = [System.IO.StreamWriter]::new($logFile, $false, [System.Text.Encoding]::UTF8)
    $logStream.AutoFlush = $true

    $stdoutHandler = {
        if ($EventArgs.Data) { $Event.MessageData.WriteLine($EventArgs.Data) }
    }
    $stderrHandler = {
        if ($EventArgs.Data) { $Event.MessageData.WriteLine($EventArgs.Data) }
    }

    Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived `
        -Action $stdoutHandler -MessageData $logStream | Out-Null
    Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  `
        -Action $stderrHandler -MessageData $logStream | Out-Null

    $proc.Start() | Out-Null
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    $script:pids[$Name] = $proc.Id
    Write-Host "    PID=$($proc.Id)  log=$logFile"
}

# ── 1. java-receiver (port 8081) ─────────────────────────────────────────────
# The OTel Java Agent reads the W3C traceparent header injected by cpp-service
# and automatically creates a SERVER child span.
Start-Service -Name "java-receiver" `
    -Executable "java" `
    -Arguments @(
        "-javaagent:$OtelAgent",
        "-DOTEL_SERVICE_NAME=java-receiver",
        "-DOTEL_EXPORTER_OTLP_ENDPOINT=$JavaOtlpEndpoint",
        "-jar", $ReceiverJar,
        "--server.port=8081"
    )

# Give java-receiver time to bind its port before cpp-service tries to call it.
Write-Host "  Waiting for java-receiver to start (8 s)..."
Start-Sleep -Seconds 8

# ── 2. cpp-service (port 8080) ───────────────────────────────────────────────
# Instrumented by the IDOT OpenTelemetry C++ SDK. Exports spans via OTLP/gRPC.
# PATH already includes the SDK bin\ directory (set above).
Start-Service -Name "cpp-service" `
    -Executable $CppExe `
    -Arguments @() `
    -ExtraEnv @{
        OTEL_SERVICE_NAME             = 'cpp-service'
        OTEL_EXPORTER_OTLP_ENDPOINT   = $CppOtlpEndpoint
        SERVER_PORT                   = '8080'
        JAVA_RECEIVER_URL             = 'http://localhost:8081'
    }

Start-Sleep -Seconds 3

# ── 3. java-caller (port 8082) ───────────────────────────────────────────────
# The OTel Java Agent creates a CLIENT span for each outbound RestTemplate call
# and injects W3C traceparent automatically.
Start-Service -Name "java-caller" `
    -Executable "java" `
    -Arguments @(
        "-javaagent:$OtelAgent",
        "-DOTEL_SERVICE_NAME=java-caller",
        "-DOTEL_EXPORTER_OTLP_ENDPOINT=$JavaOtlpEndpoint",
        "-DCPP_SERVICE_URL=http://localhost:8080",
        "-DSCHEDULE_ENABLED=$($ScheduleEnabled.ToString().ToLower())",
        "-jar", $CallerJar,
        "--server.port=8082"
    )

# ── Persist PIDs for stop.ps1 ─────────────────────────────────────────────────
$pids | ConvertTo-Json | Set-Content -Path $PidsFile -Encoding UTF8

Write-Host ""
Write-Host "==========================================="
Write-Host " All services started."
Write-Host ""
Write-Host "  java-caller   :8082  (log: $LogsDir\java-caller.log)"
Write-Host "  cpp-service   :8080  (log: $LogsDir\cpp-service.log)"
Write-Host "  java-receiver :8081  (log: $LogsDir\java-receiver.log)"
Write-Host ""
Write-Host "  Trigger a trace:"
Write-Host "    curl http://$([System.Net.Dns]::GetHostEntry('').HostName):8082/order"
Write-Host ""
Write-Host "  cpp-service spans -> OTLP/gRPC -> $CppOtlpEndpoint"
Write-Host "  Run .\stop.ps1 to stop all services."
Write-Host "==========================================="
