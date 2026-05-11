<#
.SYNOPSIS
    Build manifest.json for the SPT-VPN enrollment service from the
    host PC's installed SPT/Fika/mods, then upload it to the Azure VM.

.DESCRIPTION
    The publisher does NOT zip or upload any mod binaries. It just
    inspects C:\SPT, reads fika.jsonc, asks you (once per mod) for a
    public download URL, HEAD-probes every URL, and writes the
    manifest. The Azure VM serves only the manifest; clients fetch
    mods directly from the public URLs over their own internet.

.PARAMETER ConfigPath
    Path to publish.config.json. Default: ./publish.config.json next
    to this script. See publish.config.example.json for the schema.

.PARAMETER WhatIf
    Build and validate the manifest but don't write it locally or
    upload it. Prints what would change.

.PARAMETER NonInteractive
    Fail instead of prompting when a mod URL is missing from the cache.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [switch] $WhatIf,
    [switch] $NonInteractive
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition

if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'publish.config.json' }
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath. Copy publish.config.example.json and edit it."
}

$cfg = Get-Content -Raw $ConfigPath | ConvertFrom-Json
$cfgDirty = $false  # track whether we added URLs and need to save back

# --- Helpers ----------------------------------------------------------------
function Read-Jsonc([string]$Path) {
    # Strip // line comments and /* block comments, then JSON-parse.
    $raw = Get-Content -Raw $Path
    $noBlock = [regex]::Replace($raw, '/\*.*?\*/', '', 'Singleline')
    $sb = New-Object System.Text.StringBuilder
    foreach ($line in $noBlock -split "`n") {
        $idx = -1
        for ($i = 0; $i -lt $line.Length - 1; $i++) {
            # Skip "//" inside http:// and https://
            if ($line[$i] -eq '/' -and $line[$i+1] -eq '/') {
                if ($i -gt 0 -and $line[$i-1] -eq ':') { continue }
                $idx = $i; break
            }
        }
        if ($idx -ge 0) { $line = $line.Substring(0, $idx) }
        [void]$sb.AppendLine($line)
    }
    return $sb.ToString() | ConvertFrom-Json
}

function Get-FolderSha256([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $files = Get-ChildItem -Recurse -File -LiteralPath $Path | Sort-Object FullName
        foreach ($f in $files) {
            $rel  = $f.FullName.Substring($Path.Length).TrimStart('\','/').Replace('\','/')
            $name = [Text.Encoding]::UTF8.GetBytes($rel + "`0")
            [void]$sha.TransformBlock($name, 0, $name.Length, $name, 0)
            $bytes = [IO.File]::ReadAllBytes($f.FullName)
            [void]$sha.TransformBlock($bytes, 0, $bytes.Length, $bytes, 0)
        }
        [void]$sha.TransformFinalBlock([byte[]]::new(0), 0, 0)
        return (-join ($sha.Hash | ForEach-Object { $_.ToString('x2') }))
    } finally { $sha.Dispose() }
}

function Get-ProductVersion([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    return (Get-Item $Path).VersionInfo.ProductVersion
}

function Test-ModUrl([string]$Url) {
    # Returns @{ ok = $bool; reason = '...' }
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Head -MaximumRedirection 5 `
            -UseBasicParsing -UserAgent 'Mozilla/5.0 spt-vpn-publisher' `
            -TimeoutSec 20
    } catch {
        return @{ ok = $false; reason = "HEAD failed: $($_.Exception.Message)" }
    }
    if ($r.StatusCode -ne 200) {
        return @{ ok = $false; reason = "HTTP $($r.StatusCode)" }
    }
    $ct = ''
    if ($r.Headers.ContainsKey('Content-Type')) { $ct = [string]$r.Headers['Content-Type'] }
    if ($ct -like 'text/html*') {
        return @{ ok = $false; reason = "Content-Type=$ct (Hub captcha/landing page?)" }
    }
    $clen = 0
    if ($r.Headers.ContainsKey('Content-Length')) { $clen = [int64]$r.Headers['Content-Length'] }
    if ($clen -gt 0 -and $clen -lt 1024) {
        return @{ ok = $false; reason = "Content-Length=$clen (<1 KB)" }
    }
    return @{ ok = $true; reason = "ok ($ct, $clen bytes)" }
}

function Ask-ModUrl([string]$ModName, [string]$HintPath) {
    if ($NonInteractive) {
        throw "No URL cached for '$ModName' and -NonInteractive is set. Add it to publish.config.json -> mod_urls."
    }
    Write-Host ""
    Write-Host "===> URL needed for mod: $ModName" -ForegroundColor Yellow
    Write-Host "     Local path: $HintPath"
    Write-Host "     Paste the public download URL (sp-tarkov Hub, GitHub release, etc.):"
    $url = Read-Host "URL"
    return $url.Trim()
}

# --- Locate inputs ----------------------------------------------------------
$sptRoot     = $cfg.spt_root
$pluginsRoot = Join-Path $sptRoot 'BepInEx\plugins'
$serverMods  = Join-Path $sptRoot 'SPT\user\mods'
$fikaCfgPath = Join-Path $sptRoot 'SPT\user\mods\fika-server\assets\configs\fika.jsonc'
$sptExe      = Join-Path $sptRoot 'SPT\SPT.Server.exe'
$fikaClient  = Join-Path $pluginsRoot 'Fika\Fika.Core.dll'
$fikaServer  = Join-Path $sptRoot 'SPT\user\mods\fika-server\FikaServer.dll'

if (-not (Test-Path $pluginsRoot)) { throw "BepInEx plugins folder missing: $pluginsRoot" }
if (-not (Test-Path $fikaCfgPath)) { throw "fika.jsonc missing: $fikaCfgPath" }

# --- Read fika.jsonc to classify mods --------------------------------------
$fika = Read-Jsonc $fikaCfgPath
$reqNames = @()
$optNames = @()
if ($fika.client -and $fika.client.mods) {
    if ($fika.client.mods.required) { $reqNames = @($fika.client.mods.required) }
    if ($fika.client.mods.optional) { $optNames = @($fika.client.mods.optional) }
}
$reqSet = @{}; $reqNames | ForEach-Object { $reqSet[$_.ToLowerInvariant()] = $true }
$optSet = @{}; $optNames | ForEach-Object { $optSet[$_.ToLowerInvariant()] = $true }
Write-Host "fika.jsonc: $($reqNames.Count) required, $($optNames.Count) optional client mods."

# --- Enumerate client-side mod folders --------------------------------------
function New-ModEntry([string]$Name, [string]$Path, [string]$InstallTo, [bool]$Required) {
    [pscustomobject]@{
        Name      = $Name
        Path      = $Path
        InstallTo = $InstallTo
        Required  = $Required
    }
}

$candidates = @()
foreach ($d in Get-ChildItem -Directory $pluginsRoot) {
    $candidates += New-ModEntry $d.Name $d.FullName 'BepInEx/plugins' $false
}

# Decide required/optional/host-only by matching the folder name.
$mods = @()
foreach ($c in $candidates) {
    $low = $c.Name.ToLowerInvariant()
    $req = $reqSet.ContainsKey($low) -or $reqSet.ContainsKey(($low -replace ' ', ''))
    $opt = $optSet.ContainsKey($low) -or $optSet.ContainsKey(($low -replace ' ', ''))
    if (-not ($req -or $opt)) {
        # Fuzzy match: the fika.jsonc name might be a substring (some mods
        # use display names different from folder names).
        foreach ($n in $reqNames) {
            if ($low -like "*$($n.ToLowerInvariant())*" -or $n.ToLowerInvariant() -like "*$low*") {
                $req = $true; break
            }
        }
        if (-not $req) {
            foreach ($n in $optNames) {
                if ($low -like "*$($n.ToLowerInvariant())*" -or $n.ToLowerInvariant() -like "*$low*") {
                    $opt = $true; break
                }
            }
        }
    }
    if ($req)      { $mods += (New-ModEntry $c.Name $c.Path 'BepInEx/plugins' $true) }
    elseif ($opt)  { $mods += (New-ModEntry $c.Name $c.Path 'BepInEx/plugins' $false) }
    else           { Write-Host "  skip host-only: $($c.Name)" -ForegroundColor DarkGray }
}

if (-not $mods) {
    Write-Host "No mods to publish (nothing in fika.jsonc client.mods)." -ForegroundColor Yellow
}

# --- Resolve URLs + HEAD-probe ---------------------------------------------
if (-not ($cfg.PSObject.Properties.Name -contains 'mod_urls') -or $null -eq $cfg.mod_urls) {
    $cfg | Add-Member -NotePropertyName mod_urls -NotePropertyValue ([pscustomobject]@{}) -Force
}

function Get-CachedUrl($modName) {
    if ($cfg.mod_urls.PSObject.Properties.Name -contains $modName) {
        return [string]$cfg.mod_urls.$modName
    }
    return $null
}
function Set-CachedUrl($modName, $url) {
    if ($cfg.mod_urls.PSObject.Properties.Name -contains $modName) {
        $cfg.mod_urls.$modName = $url
    } else {
        $cfg.mod_urls | Add-Member -NotePropertyName $modName -NotePropertyValue $url
    }
    $script:cfgDirty = $true
}

$manifestRequired = @()
$manifestOptional = @()
$failures = @()

foreach ($m in $mods) {
    $url = Get-CachedUrl $m.Name
    if (-not $url) {
        $url = Ask-ModUrl $m.Name $m.Path
        if (-not $url) {
            $failures += "no URL provided for $($m.Name)"
            continue
        }
        Set-CachedUrl $m.Name $url
    }

    Write-Host "Probing: $($m.Name)" -NoNewline
    $probe = Test-ModUrl $url
    if ($probe.ok) {
        Write-Host "  [OK] $($probe.reason)" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $($probe.reason)" -ForegroundColor Red
        if ($m.Required) {
            $failures += "$($m.Name): $($probe.reason)  -- URL: $url"
            continue
        } else {
            Write-Host "  (optional - keeping in manifest; client will use fallback)" -ForegroundColor DarkYellow
        }
    }

    $sha = Get-FolderSha256 $m.Path
    $entry = [ordered]@{
        name       = $m.Name
        url        = $url
        install_to = $m.InstallTo
    }
    if ($sha) { $entry.sha256_source = $sha }  # purely informational

    if ($m.Required) { $manifestRequired += $entry } else { $manifestOptional += $entry }
}

if ($failures) {
    Write-Host ""
    Write-Host "Publish aborted - fix these required URLs:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  * $_" }
    if ($cfgDirty -and -not $WhatIf) {
        Get-Content -Raw $ConfigPath | Out-Null  # touch
        $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigPath -Encoding UTF8
        Write-Host "  (cached new URLs in $ConfigPath)"
    }
    exit 1
}

# --- Assemble manifest -----------------------------------------------------
$manifest = [ordered]@{
    spt = [ordered]@{
        version     = (Get-ProductVersion $sptExe)
        release_url = [string]$cfg.spt_release_url
    }
    fika = [ordered]@{
        client_version = (Get-ProductVersion $fikaClient)
        server_version = (Get-ProductVersion $fikaServer)
        release_url    = [string]$cfg.fika_release_url
    }
    server_vpn_ip = [string]$cfg.server_vpn_ip
    spt_url       = [string]$cfg.spt_url
    required      = $manifestRequired
    optional      = $manifestOptional
}

$manifestJson = $manifest | ConvertTo-Json -Depth 10
$localOut = Join-Path $here 'manifest.json'

Write-Host ""
Write-Host "Manifest summary:"
Write-Host "  SPT version  : $($manifest.spt.version)"
Write-Host "  Fika client  : $($manifest.fika.client_version)"
Write-Host "  Fika server  : $($manifest.fika.server_version)"
Write-Host "  Required mods: $($manifestRequired.Count)"
Write-Host "  Optional mods: $($manifestOptional.Count)"

if ($WhatIf) {
    Write-Host ""
    Write-Host "[WhatIf] Would write $localOut and upload to $($cfg.ssh_target):$($cfg.remote_manifest_path)." -ForegroundColor Yellow
    Write-Host "[WhatIf] Manifest contents:" -ForegroundColor Yellow
    Write-Host $manifestJson
    exit 0
}

# Write local file + persist URL cache
Set-Content -Path $localOut -Value $manifestJson -Encoding UTF8
if ($cfgDirty) {
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Host "Cached new mod URLs in $ConfigPath."
}
Write-Host "Wrote $localOut"

# --- Upload via scp --------------------------------------------------------
if (-not $cfg.ssh_target) {
    Write-Host "ssh_target empty in config - skipping upload. Manifest is at $localOut." -ForegroundColor Yellow
    exit 0
}
$remoteTmp = "/tmp/manifest.json.upload"
$scpArgs = @()
if ($cfg.ssh_key) { $scpArgs += @('-i', $cfg.ssh_key) }
$scpArgs += @($localOut, "$($cfg.ssh_target):$remoteTmp")

Write-Host "Uploading manifest -> $($cfg.ssh_target):$remoteTmp"
& scp @scpArgs
if ($LASTEXITCODE -ne 0) { throw "scp failed (exit $LASTEXITCODE)." }

$remoteFinal = $cfg.remote_manifest_path
$sshArgs = @()
if ($cfg.ssh_key) { $sshArgs += @('-i', $cfg.ssh_key) }
$sshArgs += @($cfg.ssh_target, "sudo install -m 0640 -o spt-vpn -g spt-vpn $remoteTmp $remoteFinal && rm -f $remoteTmp")

Write-Host "Installing manifest into place ($remoteFinal)..."
& ssh @sshArgs
if ($LASTEXITCODE -ne 0) { throw "ssh install failed (exit $LASTEXITCODE)." }

Write-Host ""
Write-Host "Done. Friends will pick up the new manifest on their next install." -ForegroundColor Green
