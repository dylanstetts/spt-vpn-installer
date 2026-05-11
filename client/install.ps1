<#
.SYNOPSIS
    SPT-VPN client installer:
      1. Install WireGuard (if missing)
      2. Generate keypair, enroll with the server (cert-pinned HTTPS)
      3. Install + start the WG tunnel service
      4. Run Fika-Installer.exe (handles EFT clone + SPT release + Fika)
      5. Pull manifest.json from the server, download each mod from its
         public URL, extract into the right SPT subfolder.
      6. Patch the SPT launcher config to point at the VPN server.

.PARAMETER EnrollUrl
    Base URL of the enrollment service, e.g. https://20.115.55.17

.PARAMETER EnrollFingerprint
    SHA256 (hex) of the enrollment server's TLS cert. Baked in at
    installer build time.

.PARAMETER InviteToken
    Single-use bearer token issued by the server admin.

.PARAMETER InstallDir
    Where SPT should be installed (also passed to Fika-Installer).

.PARAMETER TunnelName
    WireGuard tunnel name (default: spt-vpn).

.PARAMETER SptHostVpnIp
    The VPN IP of the SPT host (your PC). Default 10.8.0.2; used to
    patch the launcher config if the manifest does not override.

.PARAMETER FikaInstallerUrl
    Override URL for Fika-Installer.exe.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnrollUrl,
    [Parameter(Mandatory)] [string] $EnrollFingerprint,
    [Parameter(Mandatory)] [string] $InviteToken,
    [Parameter(Mandatory)] [string] $InstallDir,
    [string] $TunnelName        = 'spt-vpn',
    [string] $SptHostVpnIp      = '10.8.0.2',
    [string] $FikaInstallerUrl  = 'https://github.com/project-fika/Fika-Installer/releases/latest/download/Fika-Installer.exe',
    [string] $WireGuardInstallerUrl = 'https://download.wireguard.com/windows-client/wireguard-installer.exe'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# --- Paths & logging --------------------------------------------------------
$LogDir = Join-Path $env:ProgramData 'spt-vpn'
$null   = New-Item -ItemType Directory -Force -Path $LogDir
$LogFile = Join-Path $LogDir 'install.log'
Start-Transcript -Path $LogFile -Append | Out-Null
function Log([string]$m) { Write-Host "[$(Get-Date -Format s)] $m" }

trap {
    Log "ERROR: $_"
    Log $_.ScriptStackTrace
    Stop-Transcript | Out-Null
    exit 1
}

if (-not ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw "This installer must run elevated."
}

$EnrollUrl = $EnrollUrl.TrimEnd('/')
$WorkDir   = Join-Path $env:TEMP 'spt-vpn-install'
$null      = New-Item -ItemType Directory -Force -Path $WorkDir

# --- Cert pinning (loaded from sibling _pin.ps1) ----------------------------
$pin = Join-Path $PSScriptRoot '_pin.ps1'
if (-not (Test-Path $pin)) { throw "_pin.ps1 missing alongside install.ps1." }
. $pin -Fingerprint $EnrollFingerprint
Log "Cert pinning active (SHA256 $EnrollFingerprint)."

# --- 1. WireGuard -----------------------------------------------------------
$WgExe = 'C:\Program Files\WireGuard\wireguard.exe'
$WgCli = 'C:\Program Files\WireGuard\wg.exe'
if (-not (Test-Path $WgExe)) {
    Log "WireGuard not found - downloading official installer..."
    $wgInstaller = Join-Path $WorkDir 'wireguard-installer.exe'
    # Note: WireGuard's site is well-known public infra; we do NOT pin this
    # download (the pin is for the enrollment API only). Standard system
    # CA trust is sufficient.
    [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
    Invoke-WebRequest -Uri $WireGuardInstallerUrl -OutFile $wgInstaller -UseBasicParsing
    # Restore the pin for everything that follows.
    . $pin -Fingerprint $EnrollFingerprint

    Log "Installing WireGuard silently..."
    $p = Start-Process -FilePath $wgInstaller -ArgumentList '/S' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "WireGuard installer exit $($p.ExitCode)" }
} else {
    Log "WireGuard already installed."
}
if (-not (Test-Path $WgCli)) { throw "wg.exe not found after install." }

# --- 2. Keygen + enroll -----------------------------------------------------
Log "Generating WireGuard keypair..."
$privKey = & $WgCli genkey
$pubKey  = $privKey | & $WgCli pubkey
if (-not $pubKey) { throw "Key generation failed." }
Log "Public key: $pubKey"

$hostName = ($env:COMPUTERNAME).ToLower()
$body = @{ pubkey = $pubKey; name = $hostName } | ConvertTo-Json -Compress
Log "Enrolling at $EnrollUrl/enroll as '$hostName'..."
try {
    $enroll = Invoke-RestMethod `
        -Uri "$EnrollUrl/enroll" -Method POST `
        -Headers @{ Authorization = "Bearer $InviteToken" } `
        -ContentType 'application/json' -Body $body
} catch {
    $msg = $_.Exception.Message
    $inner = $_.Exception.InnerException
    while ($inner) {
        $msg += " | $($inner.GetType().Name): $($inner.Message)"
        $inner = $inner.InnerException
    }
    if ($_.Exception.Response) {
        try {
            $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $msg += " | HTTP body: $($sr.ReadToEnd())"
        } catch {}
    }
    throw "Enrollment failed: $msg"
}
Log "Assigned address: $($enroll.address)  SPT URL: $($enroll.spt_url)"

# --- 3. Tunnel config + service --------------------------------------------
$confLines = @(
    '[Interface]'
    "PrivateKey = $privKey"
    "Address    = $($enroll.address)/32"
)
if ($enroll.dns) { $confLines += "DNS        = $($enroll.dns)" }
$confLines += @(
    ''
    '[Peer]'
    "PublicKey  = $($enroll.server_pubkey)"
    "Endpoint   = $($enroll.endpoint)"
    "AllowedIPs = $($enroll.allowed_ips)"
    'PersistentKeepalive = 25'
)
$plainConf = Join-Path $WorkDir "$TunnelName.conf"
Set-Content -Path $plainConf -Value ($confLines -join "`r`n") -Encoding ASCII

& $WgExe /uninstalltunnelservice $TunnelName 2>$null | Out-Null
Log "Installing tunnel service '$TunnelName'..."
$p = Start-Process -FilePath $WgExe `
        -ArgumentList @('/installtunnelservice', "`"$plainConf`"") `
        -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "wireguard /installtunnelservice exit $($p.ExitCode)" }

Log "Waiting up to 30s for tunnel to come up..."
$sptIp = $enroll.server_vpn_ip
if (-not $sptIp) { $sptIp = $SptHostVpnIp }
$ok = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Connection -ComputerName $sptIp -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        $ok = $true; break
    }
}
if ($ok) { Log "Tunnel up; ping $sptIp ok." }
else     { Log "WARNING: ping $sptIp failed; continuing anyway." }

# --- 4. Fika-Installer (EFT clone + SPT + Fika base) -----------------------
$null = New-Item -ItemType Directory -Force -Path $InstallDir
$fikaInstaller = Join-Path $InstallDir 'Fika-Installer.exe'
if (-not (Test-Path $fikaInstaller)) {
    Log "Downloading Fika-Installer.exe..."
    [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
    Invoke-WebRequest -Uri $FikaInstallerUrl -OutFile $fikaInstaller -UseBasicParsing
    . $pin -Fingerprint $EnrollFingerprint
}
Log "Launching Fika-Installer.exe (interactive wizard)..."
$p = Start-Process -FilePath $fikaInstaller -WorkingDirectory $InstallDir -Wait -PassThru
if ($p.ExitCode -ne 0) {
    Log "WARNING: Fika-Installer exited $($p.ExitCode). Continuing to mod sync."
}

# --- 5. Sync mods from server manifest --------------------------------------
& "$PSScriptRoot\sync-mods.ps1" `
    -EnrollUrl         $EnrollUrl `
    -EnrollFingerprint $EnrollFingerprint `
    -InviteToken       $InviteToken `
    -InstallDir        $InstallDir

# --- 6. Patch SPT launcher config -------------------------------------------
$launcherCfg = Join-Path $InstallDir 'SPT\user\launcher\config.json'
if (Test-Path $launcherCfg) {
    Log "Patching launcher config -> $($enroll.spt_url)"
    $cfg = Get-Content $launcherCfg -Raw | ConvertFrom-Json
    if (-not $cfg.Server) {
        $cfg | Add-Member -NotePropertyName Server -NotePropertyValue ([pscustomobject]@{})
    }
    $cfg.Server.Url = $enroll.spt_url
    if (-not $cfg.Server.Name) { $cfg.Server.Name = 'SPT (VPN)' }
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $launcherCfg -Encoding UTF8
} else {
    Log "Launcher config not found at $launcherCfg (Fika installer may have used a different path)."
}

# --- 7. Diagnostics ---------------------------------------------------------
$diag = [pscustomobject]@{
    address      = $enroll.address
    pubkey       = $pubKey
    enroll_url   = $EnrollUrl
    fingerprint  = $EnrollFingerprint
    spt_url      = $enroll.spt_url
    install_dir  = $InstallDir
    installed_at = (Get-Date).ToString('o')
}
$diag | ConvertTo-Json | Set-Content -Path (Join-Path $LogDir 'client.json') -Encoding UTF8

Log "DONE. Launch SPT.Launcher.exe from $InstallDir\SPT."
Stop-Transcript | Out-Null
