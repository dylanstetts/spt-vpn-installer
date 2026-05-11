<#
.SYNOPSIS
    Build SptVpnSetup.exe with Inno Setup.

.PARAMETER EnrollUrl
    Public HTTPS base URL of the enrollment service, e.g.
    https://20.115.55.17

.PARAMETER EnrollFingerprint
    SHA256 (hex, 64 chars, no colons) of the enrollment server's TLS
    cert. Printed at the end of server/install-server.sh.

.PARAMETER SptHostVpnIp
    Your PC's VPN IP. Default 10.8.0.2.

.PARAMETER IsccPath
    Override the path to ISCC.exe.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnrollUrl,
    [Parameter(Mandatory)] [string] $EnrollFingerprint,
    [string] $SptHostVpnIp = '10.8.0.2',
    [string] $IsccPath
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
Push-Location $here
try {
    # Locate ISCC.exe
    if (-not $IsccPath) {
        $candidates = @(
            'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
            'C:\Program Files\Inno Setup 6\ISCC.exe'
        )
        $IsccPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $IsccPath -or -not (Test-Path $IsccPath)) {
        throw "ISCC.exe not found. Install Inno Setup 6 from https://jrsoftware.org/isdl.php or pass -IsccPath."
    }

    # Optionally bundle 7zr.exe so the client can handle .7z mod archives.
    $sevenZip = Join-Path $here '7zr.exe'
    if (-not (Test-Path $sevenZip)) {
        Write-Host "Fetching 7zr.exe (sfx 7-Zip CLI, ~600 KB)..."
        $progress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri 'https://www.7-zip.org/a/7zr.exe' `
                -OutFile $sevenZip -UseBasicParsing
        } finally { $ProgressPreference = $progress }
    }

    # Validate fingerprint shape early.
    $fp = ($EnrollFingerprint -replace '[: ]', '').ToLowerInvariant()
    if ($fp.Length -ne 64 -or $fp -notmatch '^[0-9a-f]{64}$') {
        throw "EnrollFingerprint must be 64 hex chars (got '$EnrollFingerprint')."
    }

    Write-Host "Building SptVpnSetup.exe ..."
    & $IsccPath `
        "/DEnrollUrl=$EnrollUrl" `
        "/DEnrollFingerprint=$fp" `
        "/DSptHostVpnIp=$SptHostVpnIp" `
        (Join-Path $here 'SptVpnSetup.iss')
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE." }

    $exe = Join-Path $here 'dist\SptVpnSetup.exe'
    if (Test-Path $exe) {
        $size = '{0:N1} MB' -f ((Get-Item $exe).Length / 1MB)
        Write-Host ""
        Write-Host "Build complete: $exe ($size)"
    }
} finally {
    Pop-Location
}
