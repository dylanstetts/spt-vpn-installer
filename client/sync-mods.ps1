<#
.SYNOPSIS
    Download the SPT-VPN manifest and install each listed client mod
    from its public URL (sp-tarkov Hub, GitHub releases, etc.).

.DESCRIPTION
    The Azure VM hosts ONLY the manifest. Mod archives are fetched
    directly from their public URL over the friend's normal internet -
    they do NOT cross the Azure VPN.

    Manifest schema (each entry):
        {
          "name": "DrakiaXYZ-BigBrain",
          "url":  "https://hub.sp-tarkov.com/files/file/.../mod.zip",
          "sha256": "abc..." (optional),
          "install_to": "BepInEx/plugins"   // or "SPT/user/mods"
        }

    Archives are detected by magic bytes:
        zip : 50 4B 03 04
        7z  : 37 7A BC AF 27 1C
    Anything else (Hub captcha / HTML landing page) triggers the
    manual-fallback prompt: a folder opens, user drops the file, presses
    OK, we re-validate.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnrollUrl,
    [Parameter(Mandatory)] [string] $EnrollFingerprint,
    [Parameter(Mandatory)] [string] $InviteToken,
    [Parameter(Mandatory)] [string] $InstallDir
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$EnrollUrl = $EnrollUrl.TrimEnd('/')

function Log([string]$m) { Write-Host "[$(Get-Date -Format s)] [mods] $m" }

# Cert pinning for /manifest. Mod URLs hit the public internet under
# system trust; we temporarily clear the callback for those.
. (Join-Path $PSScriptRoot '_pin.ps1') -Fingerprint $EnrollFingerprint
$SevenZipExe = Join-Path $PSScriptRoot '7zr.exe'

# --- Helpers ----------------------------------------------------------------
function Get-MagicKind([string]$path) {
    $fs = [IO.File]::OpenRead($path)
    try {
        $buf = New-Object byte[] 6
        $n   = $fs.Read($buf, 0, 6)
    } finally { $fs.Dispose() }
    if ($n -ge 4 -and $buf[0] -eq 0x50 -and $buf[1] -eq 0x4B -and `
        $buf[2] -eq 0x03 -and $buf[3] -eq 0x04) { return 'zip' }
    if ($n -ge 6 -and $buf[0] -eq 0x37 -and $buf[1] -eq 0x7A -and `
        $buf[2] -eq 0xBC -and $buf[3] -eq 0xAF -and `
        $buf[4] -eq 0x27 -and $buf[5] -eq 0x1C) { return '7z' }
    return 'unknown'
}

function Get-Sha256([string]$path) {
    (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLowerInvariant()
}

function Invoke-ManualFallback {
    param([string]$Name, [string]$Url, [string]$ManualDir)

    $null = New-Item -ItemType Directory -Force -Path $ManualDir
    Start-Process explorer.exe $ManualDir | Out-Null
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $msg = @"
Automated download for mod '$Name' was blocked
(the server returned a web page, not an archive).

1. Open this URL in your browser and download the file:
       $Url

2. Save it into the folder that just opened:
       $ManualDir
   (filename can be anything ending in .zip or .7z)

3. Click OK below.
"@
    [System.Windows.Forms.MessageBox]::Show(
        $msg, "SPT-VPN: manual download needed",
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null

    $candidate = Get-ChildItem -Path $ManualDir -File `
        | Where-Object { $_.Extension -in '.zip', '.7z' } `
        | Sort-Object LastWriteTime -Descending `
        | Select-Object -First 1
    if (-not $candidate) {
        return $null
    }
    return $candidate.FullName
}

function Expand-ModArchive {
    param([string]$ArchivePath, [string]$DestDir, [string]$Kind)
    $null = New-Item -ItemType Directory -Force -Path $DestDir
    if ($Kind -eq 'zip') {
        Expand-Archive -Path $ArchivePath -DestinationPath $DestDir -Force
    } elseif ($Kind -eq '7z') {
        if (-not (Test-Path $SevenZipExe)) {
            throw "7zr.exe missing alongside sync-mods.ps1 (needed for .7z mods)."
        }
        $p = Start-Process -FilePath $SevenZipExe `
            -ArgumentList @('x', "-o$DestDir", '-y', $ArchivePath) `
            -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -ne 0) { throw "7zr exit $($p.ExitCode) on $ArchivePath" }
    } else {
        throw "Unknown archive kind '$Kind'"
    }
}

# Returns the directory inside $Root that is the "effective" archive root:
# if $Root contains exactly one entry and it's a directory, descend into it
# (handles archives wrapped in a single top-level folder). Otherwise return
# $Root itself.
function Get-EffectiveArchiveRoot([string]$Root) {
    $entries = Get-ChildItem -LiteralPath $Root
    if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) {
        return $entries[0].FullName
    }
    return $Root
}

# Get a direct child directory of $Parent matching $Name (case-insensitive),
# or $null if absent.
function Get-ChildDir([string]$Parent, [string]$Name) {
    $hit = Get-ChildItem -LiteralPath $Parent -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ieq $Name } |
        Select-Object -First 1
    if ($hit) { return $hit.FullName } else { return $null }
}

# Merge contents of $Source into $Dest, recursively. Files overwrite,
# subdirectories are merged rather than replaced wholesale.
function Merge-Tree([string]$Source, [string]$Dest) {
    $null = New-Item -ItemType Directory -Force -Path $Dest
    # robocopy MIR-style mirror would delete extras; we want additive merge.
    # /E = include empty subdirs, /NFL /NDL /NJH /NJS = quieter.
    $p = Start-Process -FilePath 'robocopy.exe' `
        -ArgumentList @("`"$Source`"", "`"$Dest`"", '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1') `
        -Wait -PassThru -WindowStyle Hidden
    # robocopy exit codes: 0-7 are success (8+ = real failure).
    if ($p.ExitCode -ge 8) {
        throw "robocopy '$Source' -> '$Dest' failed with exit code $($p.ExitCode)"
    }
}

function Install-Mod {
    param($Entry, [string]$InstallDir, [string]$WorkDir, [bool]$Required)

    $name      = $Entry.name
    $url       = $Entry.url
    $installTo = if ($Entry.install_to) { $Entry.install_to } else { 'BepInEx/plugins' }
    $targetDir = Join-Path $InstallDir ($installTo -replace '/', '\')

    Log "Installing $name (required=$Required) -> $installTo (fallback)"

    if (-not $url) {
        $msg = "Mod '$name' has no URL in the manifest."
        if ($Required) { throw $msg } else { Log "WARN: $msg"; return }
    }

    # Step 1: download attempt (no pinning - public internet).
    $savedCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
    [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
    $dl = Join-Path $WorkDir "$name.download"
    if (Test-Path $dl) { Remove-Item -Force $dl }
    try {
        Invoke-WebRequest -Uri $url -OutFile $dl -UseBasicParsing `
            -UserAgent 'Mozilla/5.0 spt-vpn-installer'
    } catch {
        Log "WARN: download failed for $name : $($_.Exception.Message)"
    } finally {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $savedCallback
    }

    # Step 2: magic-byte sniff
    $kind = if (Test-Path $dl) { Get-MagicKind $dl } else { 'unknown' }

    # Step 3: manual fallback if needed
    if ($kind -eq 'unknown') {
        Log "Download for $name didn't return a valid archive - prompting manual fallback."
        $manualDir = Join-Path $env:TEMP "spt-vpn\manual\$name"
        $picked = Invoke-ManualFallback -Name $name -Url $url -ManualDir $manualDir
        if (-not $picked) {
            $msg = "No file placed in $manualDir for mod '$name'."
            if ($Required) { throw $msg } else { Log "WARN: $msg"; return }
        }
        Copy-Item -Force $picked $dl
        $kind = Get-MagicKind $dl
        if ($kind -eq 'unknown') {
            $msg = "File placed for '$name' is not a valid .zip / .7z archive."
            if ($Required) { throw $msg } else { Log "WARN: $msg"; return }
        }
    }

    # Step 4: optional SHA256 check
    if ($Entry.sha256) {
        $have = Get-Sha256 $dl
        $want = ([string]$Entry.sha256).ToLowerInvariant()
        if ($have -ne $want) {
            Log "WARN: SHA256 mismatch for $name (got $have, want $want). Continuing."
        }
    }

    # Step 5: extract into staging and inspect layout.
    $staging = Join-Path $WorkDir "stage_$name"
    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
    Expand-ModArchive -ArchivePath $dl -DestDir $staging -Kind $kind

    # Look for a BepInEx/ or user/ subtree at the top level (or one level
    # down, in case the archive is wrapped in a single folder). Most SPT
    # mods ship one or both; some ship only one and rely on install_to.
    $effRoot = Get-EffectiveArchiveRoot $staging
    $bepDir  = Get-ChildDir $effRoot 'BepInEx'
    $usrDir  = Get-ChildDir $effRoot 'user'

    if ($bepDir -or $usrDir) {
        if ($bepDir) {
            $target = Join-Path $InstallDir 'BepInEx'
            Log "  -> merging BepInEx/ tree into $target"
            Merge-Tree $bepDir $target
        }
        if ($usrDir) {
            $target = Join-Path $InstallDir 'user'
            Log "  -> merging user/ tree into $target"
            Merge-Tree $usrDir $target
        }
    } else {
        # Legacy path: no BepInEx/ or user/ in the archive. Drop the
        # archive contents into the manifest-declared install_to.
        Log "  -> archive has no BepInEx/ or user/ root; using install_to=$installTo"
        $rootEntries = Get-ChildItem $staging
        $null = New-Item -ItemType Directory -Force -Path $targetDir
        if ($rootEntries.Count -eq 1 -and $rootEntries[0].PSIsContainer) {
            $modFolder = Join-Path $targetDir $rootEntries[0].Name
            if (Test-Path $modFolder) { Remove-Item -Recurse -Force $modFolder }
            Move-Item -Path $rootEntries[0].FullName -Destination $modFolder -Force
        } else {
            $modFolder = Join-Path $targetDir $name
            if (Test-Path $modFolder) { Remove-Item -Recurse -Force $modFolder }
            Move-Item -Path $staging -Destination $modFolder -Force
        }
    }

    Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
    Log "Installed $name"
}

# --- Main -------------------------------------------------------------------
Log "Fetching manifest from $EnrollUrl/manifest"
$manifest = Invoke-RestMethod -Uri "$EnrollUrl/manifest" `
    -Headers @{ Authorization = "Bearer $InviteToken" }

$required = @($manifest.required)
$optional = @($manifest.optional)
if (-not $required -and -not $optional) {
    Log "Manifest has no client mods. Done."
    return
}

$workDir = Join-Path $env:TEMP 'spt-vpn-mods'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue }
$null = New-Item -ItemType Directory -Force -Path $workDir

foreach ($entry in $required) { Install-Mod -Entry $entry -InstallDir $InstallDir -WorkDir $workDir -Required $true }
foreach ($entry in $optional) {
    try { Install-Mod -Entry $entry -InstallDir $InstallDir -WorkDir $workDir -Required $false }
    catch { Log "WARN: optional mod failed: $_" }
}

Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
Log "Mod sync complete."
