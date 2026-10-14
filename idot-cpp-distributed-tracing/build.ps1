#Requires -Version 5.1
<#
.SYNOPSIS
    Builds all three services of the distributed tracing sample.
    Windows equivalent of build.sh.

.DESCRIPTION
    Builds java-caller and java-receiver with Maven, then builds cpp-service
    with CMake using the IDOT OpenTelemetry C++ SDK at IDOT_OTEL_CPP_INSTALL.

    On Windows, libcurl is not bundled with the SDK. You must supply the curl
    headers and import library via CurlIncludeDir and CurlLibrary:

      CurlIncludeDir — directory containing curl\curl.h
                       e.g. C:\curl-8.22.0_3-win64-mingw\include
      CurlLibrary    — full path to the import library
                       MSVC build:  ...\lib\libcurl.lib  (or libcurl_imp.lib)
                       MinGW build: ...\lib\libcurl.dll.a  (or libcurl.a)

    If your curl package ships libcurl.dll.a (MinGW) instead of libcurl.lib
    (MSVC), generate a .lib file with:
      lib /def:libcurl.def /out:libcurl.lib /machine:x64
    or use the vcpkg curl port for a native MSVC build:
      vcpkg install curl:x64-windows

.PARAMETER IdotOtelCppInstall
    Root directory of the IDOT OpenTelemetry C++ SDK install.
    Can also be set via the environment variable IDOT_OTEL_CPP_INSTALL.

.PARAMETER CurlIncludeDir
    Directory containing curl\curl.h (the curl include directory).
    Can also be set via the environment variable CURL_INCLUDE_DIR.

.PARAMETER CurlLibrary
    Full path to the curl import library (libcurl.lib, libcurl_imp.lib, or libcurl.dll.a).
    Can also be set via the environment variable CURL_LIBRARY.

.EXAMPLE
    $env:IDOT_OTEL_CPP_INSTALL = "<path-to-opentelemetry-cpp>"
    $env:CURL_INCLUDE_DIR       = "<path-to-curl>\include"
    $env:CURL_LIBRARY           = "<path-to-curl>\lib\libcurl.lib"
    .\build.ps1

.EXAMPLE
    .\build.ps1 -IdotOtelCppInstall "<path-to-opentelemetry-cpp>" `
                -CurlIncludeDir     "<path-to-curl>\include" `
                -CurlLibrary        "<path-to-curl>\lib\libcurl.lib"

.NOTES
    Requirements:
      - CMake 3.16 or later on PATH
      - A C++17-capable compiler (MSVC via Developer PowerShell, or MinGW/MSYS2)
      - Java 8 or later on PATH
      - Maven 3.6 or later on PATH
      - libcurl headers + import library — https://curl.se/windows/ or vcpkg
#>

[CmdletBinding()]
param(
    [string]$IdotOtelCppInstall = $env:IDOT_OTEL_CPP_INSTALL,
    [string]$CurlIncludeDir     = $env:CURL_INCLUDE_DIR,
    [string]$CurlLibrary        = $env:CURL_LIBRARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve script directory ──────────────────────────────────────────────────
$ScriptDir = $PSScriptRoot

# ── Validate required parameters ─────────────────────────────────────────────
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

if ([string]::IsNullOrEmpty($CurlIncludeDir)) {
    Write-Error @"
CURL_INCLUDE_DIR is not set.
Set it to the directory containing curl\curl.h, e.g.:
  `$env:CURL_INCLUDE_DIR = '<path-to-curl>\include'
  .\build.ps1
Download curl from: https://curl.se/windows/
"@
    exit 1
}

if ([string]::IsNullOrEmpty($CurlLibrary)) {
    Write-Error @"
CURL_LIBRARY is not set.
Set it to the full path of the curl import library, e.g.:
  `$env:CURL_LIBRARY = '<path-to-curl>\lib\libcurl.lib'
  .\build.ps1
"@
    exit 1
}

if (-not (Test-Path $CurlIncludeDir)) {
    Write-Error "CURL_INCLUDE_DIR path not found: $CurlIncludeDir"
    exit 1
}

if (-not (Test-Path $CurlLibrary)) {
    Write-Error "CURL_LIBRARY file not found: $CurlLibrary"
    exit 1
}

Write-Host "==========================================="
Write-Host " OTel C++ Distributed Tracing -- Build"
Write-Host "==========================================="
Write-Host "OTel C++ install : $IdotOtelCppInstall"
Write-Host "curl include     : $CurlIncludeDir"
Write-Host "curl library     : $CurlLibrary"
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
# CURL_INCLUDE_DIR and CURL_LIBRARY are passed directly to CMake so FindCURL
# uses the exact files the user specifies rather than scanning for a package.
Write-Host ""
Write-Host "[3/3] Building cpp-service..."
Push-Location (Join-Path $ScriptDir "cpp-service")
try {
    Invoke-Step "  cmake configure" {
        cmake -B build `
              -DCMAKE_BUILD_TYPE=Release `
              "-DCMAKE_PREFIX_PATH=$IdotOtelCppInstall" `
              "-DCURL_INCLUDE_DIR=$CurlIncludeDir" `
              "-DCURL_LIBRARY=$CurlLibrary" `
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
