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

# TLS 1.2 only.
#
# TLS 1.3 on Windows Schannel is brittle with self-signed certs - the
# handshake can fail with "The underlying connection was closed: An
# unexpected error occurred on a send" before our ServerCertificateValidationCallback
# is even consulted. Sticking to 1.2 makes the pinning path reliable.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Implement the cert-pin callback as a compiled C# delegate.
#
# A PowerShell ScriptBlock used as a TLS validation callback is invoked
# by SslStream on whatever thread completes the handshake. That thread
# usually has no PowerShell Runspace attached, which makes any access
# to script-scope variables ($script:...) inside the script block throw
# "There is no Runspace available to run scripts in this thread". The
# SslStream interprets that as a failed validation and the connection
# is torn down with "The underlying connection was closed: An unexpected
# error occurred on a send" - intermittently, depending on whether the
# callback ran inline or on a worker thread. A compiled delegate has no
# runspace dependency and is always thread-safe.
if (-not ('SptVpnPin' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

public static class SptVpnPin {
    public static string Expected;
    public static bool Validate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
        if (cert == null) return false;
        byte[] raw = cert.GetRawCertData();
        using (var sha = SHA256.Create()) {
            byte[] h = sha.ComputeHash(raw);
            var sb = new StringBuilder(64);
            for (int i = 0; i < h.Length; i++) sb.Append(h[i].ToString("x2"));
            return sb.ToString() == Expected;
        }
    }
}
"@
}
[SptVpnPin]::Expected = $norm
$__sptVpnPinDelegate = [System.Delegate]::CreateDelegate(
    [System.Net.Security.RemoteCertificateValidationCallback],
    [SptVpnPin].GetMethod('Validate'))
[Net.ServicePointManager]::ServerCertificateValidationCallback = $__sptVpnPinDelegate
