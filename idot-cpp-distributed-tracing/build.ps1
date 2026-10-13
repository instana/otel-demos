#Requires -Version 5.1
<#
.SYNOPSIS
    Builds all three services of the distributed tracing sample.
    Windows equivalent of build.sh.

.DESCRIPTION
    Builds java-caller and java-receiver with Maven, then builds cpp-service
    with CMake using the IDOT OpenTelemetry C++ SDK at IDOT_OTEL_CPP_INSTALL.

.PARAMETER IdotOtelCppInstall
    Root directory of the IDOT OpenTelemetry C++ SDK install.
    Can also be set via the environment variable IDOT_OTEL_CPP_INSTALL.

.EXAMPLE
    $env:IDOT_OTEL_CPP_INSTALL = "<path-to-opentelemetry-cpp>"
    .\build.ps1

.EXAMPLE
    .\build.ps1 -IdotOtelCppInstall "<path-to-opentelemetry-cpp>"

.NOTES
    Requirements:
      - CMake 3.16 or later on PATH
      - A C++17-capable compiler (MSVC via Developer PowerShell, or MinGW/MSYS2)
      - Java 8 or later on PATH
      - Maven 3.6 or later on PATH
      - libcurl available to CMake via IDOT_OTEL_CPP_INSTALL or CMAKE_PREFIX_PATH
#>

[CmdletBinding()]
param(
    [string]$IdotOtelCppInstall = $env:IDOT_OTEL_CPP_INSTALL
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve script directory ──────────────────────────────────────────────────
$ScriptDir = $PSScriptRoot

# ── Validate required parameter ──────────────────────────────────────────────
if ([string]::IsNullOrEmpty($IdotOtelCppInstall)) {
    Write-Error @"
IDOT_OTEL_CPP_INSTALL is not set.
Set it to the root directory of the IDOT OpenTelemetry C++ SDK install, e.g.:
  `$env:IDOT_OTEL_CPP_INSTALL = '<path-to-opentelemetry-cpp>'
  .\build.ps1
"@
    exit 1
}

if (-not (Test-Path $IdotOtelCppInstall)) {
    Write-Error "IDOT_OTEL_CPP_INSTALL path not found: $IdotOtelCppInstall"
    exit 1
}

Write-Host "==========================================="
Write-Host " OTel C++ Distributed Tracing -- Build"
Write-Host "==========================================="
Write-Host "OTel C++ install : $IdotOtelCppInstall"
Write-Host ""

# ── Helper: run a command and throw on non-zero exit ─────────────────────────
function Invoke-Step {
    param([string]$Description, [scriptblock]$Command)
    Write-Host $Description
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

# ── 1. Build java-caller ──────────────────────────────────────────────────────
# Plain Spring Boot JAR — instrumented at runtime by the OTel Java Agent.
Write-Host "[1/3] Building java-caller..."
Push-Location (Join-Path $ScriptDir "java-caller")
try {
    Invoke-Step "  mvn package" {
        mvn -q --no-transfer-progress clean package -DskipTests
    }
} finally {
    Pop-Location
}
Write-Host "      -> java-caller\target\java-caller-1.0.0.jar"

# ── 2. Build java-receiver ───────────────────────────────────────────────────
Write-Host ""
Write-Host "[2/3] Building java-receiver..."
Push-Location (Join-Path $ScriptDir "java-receiver")
try {
    Invoke-Step "  mvn package" {
        mvn -q --no-transfer-progress clean package -DskipTests
    }
} finally {
    Pop-Location
}
Write-Host "      -> java-receiver\target\java-receiver-1.0.0.jar"

# ── 3. Build cpp-service ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "[3/3] Building cpp-service..."
Push-Location (Join-Path $ScriptDir "cpp-service")
try {
    Invoke-Step "  cmake configure" {
        cmake -B build `
              -DCMAKE_BUILD_TYPE=Release `
              "-DCMAKE_PREFIX_PATH=$IdotOtelCppInstall" `
              -DCMAKE_VERBOSE_MAKEFILE=OFF `
              -Wno-dev
    }

    # $env:NUMBER_OF_PROCESSORS is the Windows equivalent of nproc / lsdev
    $nproc = $env:NUMBER_OF_PROCESSORS
    Invoke-Step "  cmake build" {
        cmake --build build --config Release -j $nproc
    }
} finally {
    Pop-Location
}
Write-Host "      -> cpp-service\build\Release\cpp-service.exe"

Write-Host ""
Write-Host "==========================================="
Write-Host " Build complete. Run .\run.ps1 to start."
Write-Host "==========================================="
