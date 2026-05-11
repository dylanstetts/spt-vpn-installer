# Publisher (host PC)

Builds and uploads `manifest.json` to the Azure VM. The manifest lists
each client mod with its public download URL. The Azure VM does **not**
host mod binaries — clients fetch directly from sp-tarkov Hub / GitHub
releases over their normal internet.

## Setup

1. Copy `publish.config.example.json` to `publish.config.json`.
2. Edit the values:
   - `spt_root`: your local SPT install root (default `C:\SPT`).
   - `ssh_target`: `<user>@<vm_ip>`.
   - `ssh_key`: optional path to an SSH private key.
   - `remote_manifest_path`: default `/etc/spt-vpn/manifest.json`.
   - `server_vpn_ip` / `spt_url`: usually `10.8.0.2` and
     `https://10.8.0.2:6969`.
   - `spt_release_url` / `fika_release_url`: optional, informational.
   - `mod_urls`: leave `{}` — the script will fill it as it prompts you.

## Usage

```powershell
# Dry run: walk mods, probe URLs, print the manifest, write nothing
.\publish-mods.ps1 -WhatIf

# Build and upload to the Azure VM
.\publish-mods.ps1

# Build but fail (don't prompt) if a URL is missing
.\publish-mods.ps1 -NonInteractive
```

For each mod in `C:\SPT\BepInEx\plugins\*` that's listed in
`fika.jsonc`'s `client.mods.required` or `client.mods.optional`, the
script:

1. Looks up the URL in `mod_urls`. If missing, prompts you (paste the
   public sp-tarkov Hub or GitHub release URL).
2. HEAD-probes the URL: expects HTTP 200, non-`text/html`
   Content-Type, ≥ 1 KB. Required URL failure → aborts. Optional
   URL failure → warning, keep in manifest.
3. Computes a SHA256 of the local install folder (informational).

It then assembles `manifest.json`, writes it locally, and:

```powershell
scp manifest.json <ssh_target>:/tmp/manifest.json.upload
ssh <ssh_target> sudo install -m 0640 -o spt-vpn -g spt-vpn \
    /tmp/manifest.json.upload /etc/spt-vpn/manifest.json
```

After upload, friends running `SptVpnSetup.exe` will pick up the new
mod list on their next install.

## Maintenance

- When you install a new mod: add it to `fika.jsonc`'s `client.mods`,
  drop the folder in `C:\SPT\BepInEx\plugins\`, then re-run
  `publish-mods.ps1`. It'll prompt for the new mod's URL.
- When a mod author publishes a new version: edit `publish.config.json`
  and change the URL under `mod_urls.<name>`, then re-run.
- The script is idempotent. Re-run any time without harm.

## Files

| Path | Purpose |
|---|---|
| `publish-mods.ps1` | Main script |
| `publish.config.json` | Local config (URL cache, SSH target) — gitignored |
| `publish.config.example.json` | Template |
| `manifest.json` | Generated each run; uploaded to the VM |
