<#
.SYNOPSIS
    Installs a process-wide cert-pinning callback so HTTPS calls
    (Invoke-WebRequest, Invoke-RestMethod) only succeed when the
    server's leaf cert SHA256 fingerprint matches the expected value.

.PARAMETER Fingerprint
    Hex SHA256 (64 chars, lower-case, no colons) of the server's leaf
    cert. Produced by:
        openssl x509 -in server.crt -noout -fingerprint -sha256 \
            | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f'

.NOTES
    Dot-source this script; do not run it as a child process - the
    callback is installed on the calling AppDomain only.
#>
param([Parameter(Mandatory)][string] $Fingerprint)

$norm = ($Fingerprint -replace '[: ]', '').ToLowerInvariant()
if ($norm.Length -ne 64 -or $norm -notmatch '^[0-9a-f]{64}$') {
    throw "Pin '$Fingerprint' is not a 64-char hex SHA256."
}

# TLS 1.2/1.3
[Net.ServicePointManager]::SecurityProtocol =
    [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# Inject a global validator. The expected fingerprint is captured in a
# script-scope variable so the callback can read it.
$script:__SptVpnExpectedFp = $norm

[Net.ServicePointManager]::ServerCertificateValidationCallback = {
    param($sender, $cert, $chain, $errors)
    if (-not $cert) { return $false }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $cert.GetRawCertData()
        $hash  = $sha.ComputeHash($bytes)
        $hex   = -join ($hash | ForEach-Object { $_.ToString('x2') })
        return ($hex -eq $script:__SptVpnExpectedFp)
    } finally {
        $sha.Dispose()
    }
}
