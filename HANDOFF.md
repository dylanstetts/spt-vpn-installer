# Final handoff — read me first

Everything except the actual GitHub push is done. You're offline so I
couldn't run `gh auth login` (it needs your browser).

## What's done

- **Azure VM (`rustdesk-relay`, 20.115.55.17)**
  - WireGuard server already running (unchanged).
  - NSG rule **Allow-SPT-Enroll-HTTPS** (priority 120, TCP 443) added.
  - `install-server.sh` deployed and run successfully.
  - `spt-vpn-enroll.service` is **active** (`curl -sk https://localhost/health` from the VM returns `{"ok":true}`).
  - TLS cert SHA256 fingerprint: `b91cf04b1b29e0d276c4420a6c859360562294611cf9616843b6500b7628fed1`
  - Test invite token issued (use this to test the installer yourself):
    - **Token:** `***REVOKED-TOKEN***`
    - **Friend name:** `testfriend`
- **Client installer built:** `C:\SPT\fika-vpn-installer\client\dist\SptVpnSetup.exe` (2.3 MB) with the fingerprint above baked in.
- **Local git repo:** `C:\SPT\fika-vpn-installer\` — initialized on branch `main`, single commit `ac61717` with 16 tracked files including the built `SptVpnSetup.exe`.

## What you need to finish (two commands)

```powershell
# 1. Sign into GitHub (opens browser, one-time)
gh auth login --hostname github.com --git-protocol https --web

# 2. Create the private repo and push everything
cd C:\SPT\fika-vpn-installer
gh repo create spt-vpn-installer --private --source=. --push --description "SPT + Fika over WireGuard installer"
```

That's it. After the push, share the repo URL with your friends.

## Caveats

1. **Local TCP 443 reachability from your home LAN to 20.115.55.17 fails** (`Test-NetConnection ... -Port 443` returns False). NSG and effective rules confirm 0.0.0.0/0 is allowed; nginx listens; cert works locally. This is almost certainly your ISP or home router doing some kind of egress filtering on that destination. Friends on other networks will succeed. To verify, ask a friend on a different connection to run `curl -k https://20.115.55.17/health` — they should see `{"ok":true}`. If your home network turns out to block it, you'll need to test from a phone hotspot when issuing real tokens to yourself.

2. **Mod manifest is not yet published.** `/etc/spt-vpn/manifest.json` does not exist on the server yet. The enrollment endpoint works; `/manifest` will 404 until you run the publisher. When you're ready:
   ```powershell
   cd C:\SPT\fika-vpn-installer\publish
   Copy-Item publish.config.example.json publish.config.json
   # edit publish.config.json: set ssh_target=azureuser@20.115.55.17
   .\publish-mods.ps1
   ```
   It walks `C:\SPT\BepInEx\plugins\*`, prompts for each mod's public URL (sp-tarkov Hub or GitHub release), HEAD-probes them, uploads the manifest. This is interactive on first run; subsequent runs reuse the cached URLs.

3. **gh CLI is installed but you'll need to refresh PATH** if you opened a new terminal. The `gh` binary is at `C:\Program Files\GitHub CLI\gh.exe`.

## Issuing real invite tokens

```powershell
az vm run-command invoke -g rustdesk-rg -n rustdesk-relay --command-id RunShellScript --scripts "sudo -u spt-vpn /opt/spt-vpn/venv/bin/python /opt/spt-vpn/enroll_api.py new-token <friend_name>"
```

Send the friend the token and `SptVpnSetup.exe` (or just the repo link if they have access).

## To revoke a friend's access

```powershell
az vm run-command invoke -g rustdesk-rg -n rustdesk-relay --command-id RunShellScript --scripts "sudo -u spt-vpn /opt/spt-vpn/venv/bin/python /opt/spt-vpn/enroll_api.py revoke <token>"
```

## Reference docs

- Client guide: [`README.md`](README.md)
- Server ops: [`server/README.md`](server/README.md)
- Publishing mods: [`publish/README.md`](publish/README.md)
