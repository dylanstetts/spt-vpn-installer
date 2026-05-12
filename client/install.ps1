<#
.SYNOPSIS
    SPT-VPN client installer.

    Steps run conditionally based on -Components:
      VPN  : Install WireGuard, enroll, install + start tunnel service
      SPT  : Download and run SPTInstaller.exe (ligma), then validate
      Fika : Run Fika-Installer.exe (only after SPT is validated)
      Mods : Pull manifest, download and extract mods, patch launcher

.PARAMETER EnrollUrl
    Base URL of the enrollment service, e.g. https://20.115.55.17

.PARAMETER EnrollFingerprint
    SHA256 (hex) of the enrollment server's TLS cert. Baked in at
    installer build time.

.PARAMETER InviteToken
    Single-use bearer token issued by the server admin. Required when
    Components contains VPN or Mods.

.PARAMETER InstallDir
    Where SPT lives (or will be installed). Also passed to
    SPTInstaller / Fika-Installer.

.PARAMETER Components
    Comma-separated list of components to install. Any combination of:
    VPN, SPT, Fika, Mods. Defaults to all four ("first-time install").

.PARAMETER TunnelName
    WireGuard tunnel name (default: spt-vpn).

.PARAMETER SptHostVpnIp
    The VPN IP of the SPT host (your PC). Default 10.8.0.2; used to
    patch the launcher config if the manifest does not override.

.PARAMETER SptInstallerUrl
    Override URL for SPTInstaller.exe.

.PARAMETER FikaInstallerUrl
    Override URL for Fika-Installer.exe.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnrollUrl,
    [Parameter(Mandatory)] [string] $EnrollFingerprint,
    [Parameter(Mandatory)] [string] $InstallDir,
    [string] $InviteToken       = '',
    [string] $Components        = 'VPN,SPT,Fika,Mods',
    [string] $TunnelName        = 'spt-vpn',
    [string] $SptHostVpnIp      = '10.8.0.2',
    [string] $SptInstallerUrl   = 'https://ligma.waffle-lord.net/SPTInstaller.exe',
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

# --- Component selection ----------------------------------------------------
$validComponents = @('VPN', 'SPT', 'Fika', 'Mods')
$selected = @($Components -split '[,\s]+' |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ })
foreach ($c in $selected) {
    if ($validComponents -notcontains $c) {
        throw "Unknown component '$c'. Valid: $($validComponents -join ', ')."
    }
}
if (-not $selected) { throw "No components selected." }
function HasComponent([string]$name) { return ($selected -contains $name) }
Log ("Selected components: " + ($selected -join ', '))

if ((HasComponent 'VPN') -and (-not $InviteToken)) {
    throw "InviteToken is required when installing the VPN component."
}
# Mods alone is fine without a token: /manifest is public.

# --- SPT installation validation -------------------------------------------
function Test-SptInstallation {
    param([string]$Root)
    if (-not $Root -or -not (Test-Path $Root)) { return $false }

    $launcherCandidates = @(
        (Join-Path $Root 'SPT.Launcher.exe'),
        (Join-Path $Root 'SPT\SPT.Launcher.exe')
    )
    $hasLauncher = $false
    foreach ($p in $launcherCandidates) {
        if (Test-Path $p) { $hasLauncher = $true; break }
    }
    if (-not $hasLauncher) { return $false }

    $bepinexCandidates = @(
        (Join-Path $Root 'BepInEx'),
        (Join-Path $Root 'SPT\BepInEx')
    )
    $hasBepinex = $false
    foreach ($p in $bepinexCandidates) {
        if (Test-Path $p -PathType Container) { $hasBepinex = $true; break }
    }
    if (-not $hasBepinex) { return $false }

    $modsCandidates = @(
        (Join-Path $Root 'user\mods'),
        (Join-Path $Root 'SPT\user\mods'),
        (Join-Path $Root 'BepInEx\plugins')
    )
    foreach ($p in $modsCandidates) {
        if (Test-Path $p -PathType Container) { return $true }
    }
    return $false
}

# Returns the first plausible SPT install root on this machine, or $null.
# Scans common locations on every fixed drive. The originally requested
# install dir is checked first.
function Find-SptInstallation {
    param([string]$Preferred)

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Preferred) {
        $candidates.Add($Preferred) | Out-Null
        # SPTInstaller often creates a "SPT" subfolder under the chosen dir.
        $candidates.Add((Join-Path $Preferred 'SPT')) | Out-Null
    }

    $subdirs = @(
        'SPT', 'SPT-AKI', 'SPTarkov',
        'Games\SPT', 'Games\SPT-AKI', 'Games\SPTarkov',
        'Program Files\SPT', 'Program Files (x86)\SPT'
    )
    try {
        $drives = [IO.DriveInfo]::GetDrives() |
            Where-Object { $_.IsReady -and $_.DriveType -eq 'Fixed' } |
            ForEach-Object { $_.RootDirectory.FullName }
    } catch {
        $drives = @('C:\')
    }
    foreach ($d in $drives) {
        foreach ($s in $subdirs) {
            $candidates.Add((Join-Path $d $s)) | Out-Null
        }
    }

    $seen = @{}
    foreach ($c in $candidates) {
        $key = $c.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if (Test-SptInstallation -Root $c) { return $c }
    }
    return $null
}

# Pop a folder-picker dialog asking the user to point at their SPT install.
# Re-asks (up to $maxRetries) if the chosen path doesn't validate.
function Read-SptInstallationPath {
    param(
        [string]$Initial,
        [int]$MaxRetries = 3
    )
    Add-Type -AssemblyName System.Windows.Forms | Out-Null

    for ($i = 0; $i -lt $MaxRetries; $i++) {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Locate your SPT installation folder (must contain SPT.Launcher.exe and BepInEx)."
        $dlg.ShowNewFolderButton = $false
        if ($Initial -and (Test-Path $Initial)) { $dlg.SelectedPath = $Initial }

        $res = $dlg.ShowDialog()
        if ($res -ne [System.Windows.Forms.DialogResult]::OK) {
            return $null
        }
        $picked = $dlg.SelectedPath
        if (Test-SptInstallation -Root $picked) { return $picked }
        # Allow user to pick the parent (e.g. C:\Games) that contains "SPT".
        $nested = Join-Path $picked 'SPT'
        if (Test-SptInstallation -Root $nested) { return $nested }

        [System.Windows.Forms.MessageBox]::Show(
            "'$picked' does not look like a valid SPT install.`n`n" +
            "Expected: SPT.Launcher.exe + BepInEx\ + a mods folder (user\mods or BepInEx\plugins).`n`n" +
            "Please try again, or Cancel to abort.",
            "SPT install not detected",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
    return $null
}

# Resolves an SPT install root for the current run:
#   1. Validate the requested install dir as-is.
#   2. Auto-scan common locations.
#   3. Prompt the user with a folder picker.
# Returns a validated path, or throws.
function Resolve-SptInstallationPath {
    param(
        [string]$Preferred,
        [string]$ContextLabel = 'SPT'
    )
    if (Test-SptInstallation -Root $Preferred) {
        return $Preferred
    }
    Log "Scanning for an SPT installation (preferred '$Preferred' did not validate)..."
    $found = Find-SptInstallation -Preferred $Preferred
    if ($found) {
        Log "Auto-detected SPT at '$found'."
        return $found
    }
    Log "No SPT install auto-detected; prompting user."
    $picked = Read-SptInstallationPath -Initial $Preferred
    if ($picked) {
        Log "User-selected SPT path: '$picked'."
        return $picked
    }
    throw ("Cannot locate an SPT installation for the $ContextLabel step. " +
           "Expected SPT.Launcher.exe, BepInEx folder, and a mods directory under the install root. " +
           "Install SPT first (re-run setup with the SPT component), or pick the correct folder when prompted.")
}

# --- Cert pinning (loaded from sibling _pin.ps1) ----------------------------
$pin = Join-Path $PSScriptRoot '_pin.ps1'
if (-not (Test-Path $pin)) { throw "_pin.ps1 missing alongside install.ps1." }
if ((HasComponent 'VPN') -or (HasComponent 'Mods')) {
    . $pin -Fingerprint $EnrollFingerprint
    Log "Cert pinning active (SHA256 $EnrollFingerprint)."
}

# --- 1. WireGuard -----------------------------------------------------------
$WgExe = 'C:\Program Files\WireGuard\wireguard.exe'
$WgCli = 'C:\Program Files\WireGuard\wg.exe'
if (HasComponent 'VPN') {
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
} else {
    Log "Skipping WireGuard install (VPN component not selected)."
}

# --- 2. Keygen + enroll -----------------------------------------------------
$enroll = $null
$pubKey = $null
if (HasComponent 'VPN') {
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

    # --- 3. Tunnel config + service ----------------------------------------
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

    # Best-effort uninstall of any prior tunnel of the same name. Native CLIs
    # that write to stderr can trip Stop-mode error handling, so we route
    # through Start-Process and ignore the exit code entirely.
    try {
        Start-Process -FilePath $WgExe `
            -ArgumentList @('/uninstalltunnelservice', $TunnelName) `
            -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
    } catch { }

    Log "Installing tunnel service '$TunnelName'..."
    $p = Start-Process -FilePath $WgExe `
            -ArgumentList @('/installtunnelservice', "`"$plainConf`"") `
            -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) { throw "wireguard /installtunnelservice exit $($p.ExitCode)" }

    Log "Waiting up to 30s for tunnel to come up..."
    $sptIp = $enroll.spt_host_vpn_ip
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
} else {
    Log "Skipping VPN enrollment and tunnel (VPN component not selected)."
}

# --- 4. SPT install (SPTInstaller.exe from ligma) --------------------------
$null = New-Item -ItemType Directory -Force -Path $InstallDir
# $sptRoot is the validated SPT install root used by Fika/Mods/launcher
# patching. It may differ from $InstallDir if SPTInstaller redirected
# (e.g. user picked C:\Program Files\SPT but SPTInstaller installed to
# C:\SPT) or if the user picked a different folder when prompted.
$sptRoot = $null
if (HasComponent 'SPT') {
    if (Test-SptInstallation -Root $InstallDir) {
        Log "Existing SPT installation detected at '$InstallDir' - skipping SPTInstaller."
        $sptRoot = $InstallDir
    } else {
        $sptInstaller = Join-Path $WorkDir 'SPTInstaller.exe'
        Log "Downloading SPTInstaller.exe from $SptInstallerUrl ..."
        $savedCb = [Net.ServicePointManager]::ServerCertificateValidationCallback
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
        try {
            Invoke-WebRequest -Uri $SptInstallerUrl -OutFile $sptInstaller -UseBasicParsing
        } finally {
            [Net.ServicePointManager]::ServerCertificateValidationCallback = $savedCb
        }

        Log "Launching SPTInstaller.exe (interactive). Waiting for completion..."
        $p = Start-Process -FilePath $sptInstaller `
                -WorkingDirectory $InstallDir -Wait -PassThru
        if ($p.ExitCode -ne 0) {
            Log "WARNING: SPTInstaller exited $($p.ExitCode)."
        }

        # SPTInstaller may install at a totally different location than the
        # one we passed (Program Files is often blocked; users can change
        # the destination inside the wizard). Auto-detect, then fall back
        # to a folder picker.
        $sptRoot = Resolve-SptInstallationPath -Preferred $InstallDir -ContextLabel 'SPT install validation'
        Log "SPT installation validated at '$sptRoot'."
    }
} else {
    Log "Skipping SPT install (SPT component not selected)."
}

# --- 5. Fika-Installer ------------------------------------------------------
if (HasComponent 'Fika') {
    if (-not $sptRoot) {
        $sptRoot = Resolve-SptInstallationPath -Preferred $InstallDir -ContextLabel 'Fika install'
    }
    $fikaInstaller = Join-Path $sptRoot 'Fika-Installer.exe'
    if (-not (Test-Path $fikaInstaller)) {
        Log "Downloading Fika-Installer.exe..."
        $savedCb = [Net.ServicePointManager]::ServerCertificateValidationCallback
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
        try {
            Invoke-WebRequest -Uri $FikaInstallerUrl -OutFile $fikaInstaller -UseBasicParsing
        } finally {
            [Net.ServicePointManager]::ServerCertificateValidationCallback = $savedCb
        }
    }
    Log "Launching Fika-Installer.exe (interactive wizard) at '$sptRoot'..."
    $p = Start-Process -FilePath $fikaInstaller -WorkingDirectory $sptRoot -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Log "WARNING: Fika-Installer exited $($p.ExitCode)."
    }
} else {
    Log "Skipping Fika install (Fika component not selected)."
}

# --- 6. Sync mods from server manifest --------------------------------------
if (HasComponent 'Mods') {
    if (-not $sptRoot) {
        $sptRoot = Resolve-SptInstallationPath -Preferred $InstallDir -ContextLabel 'mod sync'
    }
    & "$PSScriptRoot\sync-mods.ps1" `
        -EnrollUrl         $EnrollUrl `
        -EnrollFingerprint $EnrollFingerprint `
        -InviteToken       $InviteToken `
        -InstallDir        $sptRoot
} else {
    Log "Skipping mod sync (Mods component not selected)."
}

# --- 7. Patch SPT launcher config -------------------------------------------
if ((HasComponent 'VPN') -and $enroll) {
    if (-not $sptRoot) {
        # Best-effort detection; don't prompt if we don't have to.
        if (Test-SptInstallation -Root $InstallDir) { $sptRoot = $InstallDir }
        else { $sptRoot = Find-SptInstallation -Preferred $InstallDir }
    }
    if ($sptRoot) {
        $launcherCfgCandidates = @(
            (Join-Path $sptRoot 'user\launcher\config.json'),
            (Join-Path $sptRoot 'SPT\user\launcher\config.json')
        )
        $launcherCfg = $launcherCfgCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($launcherCfg) {
            Log "Patching launcher config ($launcherCfg) -> $($enroll.spt_url)"
            $cfg = Get-Content $launcherCfg -Raw | ConvertFrom-Json
            if (-not $cfg.Server) {
                $cfg | Add-Member -NotePropertyName Server -NotePropertyValue ([pscustomobject]@{})
            }
            $cfg.Server.Url = $enroll.spt_url
            if (-not $cfg.Server.Name) { $cfg.Server.Name = 'SPT (VPN)' }
            $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $launcherCfg -Encoding UTF8
        } else {
            Log "Launcher config not found under '$sptRoot' (skipping patch)."
        }
    } else {
        Log "No SPT install located; skipping launcher config patch."
    }
}

# --- 8. Diagnostics ---------------------------------------------------------
$diag = [pscustomobject]@{
    components    = $selected
    address       = if ($enroll) { $enroll.address } else { $null }
    pubkey        = $pubKey
    enroll_url    = $EnrollUrl
    fingerprint   = $EnrollFingerprint
    spt_url       = if ($enroll) { $enroll.spt_url } else { $null }
    install_dir   = $InstallDir
    spt_root      = $sptRoot
    installed_at  = (Get-Date).ToString('o')
}
$diag | ConvertTo-Json | Set-Content -Path (Join-Path $LogDir 'client.json') -Encoding UTF8

if ($sptRoot) {
    Log "DONE. Launch SPT.Launcher.exe from '$sptRoot'."
} else {
    Log "DONE. Launch SPT.Launcher.exe from $InstallDir (or $InstallDir\SPT)."
}
Stop-Transcript | Out-Null
