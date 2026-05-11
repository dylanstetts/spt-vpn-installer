# SPT-VPN Setup — client install guide

Single-executable installer that connects you to a private SPT (Single Player
Tarkov) server running [Fika](https://github.com/project-fika/Fika-Plugin)
multiplayer, over a WireGuard VPN.

The installer:

1. Installs WireGuard and joins the host's private VPN.
2. Runs the official Fika-Installer, which clones your existing Escape From
   Tarkov files locally and applies SPT + Fika on top.
3. Downloads the server's mod set automatically from their public sources.
4. Points the SPT launcher at the host's server.

Once it's done, you launch `SPT.Launcher.exe` and you're in.

---

## Before you start

You need:

- **Windows 10 / 11 (64-bit)** with administrator rights on the PC.
- **A legitimate, fully installed copy of Escape From Tarkov.** Install it
  via the [Battlestate Games launcher](https://www.escapefromtarkov.com/launcher)
  and run it at least once. SPT does not work without it, and this
  installer never downloads EFT for you.
- **An invite token** from the server admin. It looks like a random
  32-character string. It's single-use and tied to your machine.
- **About 30 GB of free disk space** for the new SPT install (it copies
  your EFT files into a separate folder, leaving your real EFT alone).
- **A stable internet connection.** The Fika installer pulls about 500 MB,
  then mod downloads add maybe 100–300 MB depending on the modlist.

---

## Install

1. Download `SptVpnSetup.exe` from this repo's
   [latest release](../../releases/latest) (or wherever the admin shared
   it).
2. Right-click the file → **Properties** → check **Unblock** at the bottom
   if it's there, then **OK**. (Windows flags downloaded executables; this
   is normal.)
3. Double-click to run. Windows SmartScreen will warn you the publisher
   is unknown — click **More info → Run anyway**.
4. Follow the wizard:
   - **Install folder**: default `C:\SPT` is fine.
   - **Invite token**: paste exactly what the admin sent you.
5. Click **Install**. The installer will:
   - Install WireGuard (silent, ~10 seconds).
   - Open a PowerShell window showing setup progress. Leave it alone.
   - Open the **Fika-Installer wizard**. **You need to interact with this
     window** — point it at your EFT folder when it asks (it
     auto-detects in most cases), and click through to completion.
   - Resume in PowerShell to download server mods.
6. When the PowerShell window closes, you're done. A Start Menu shortcut
   "SPT Launcher" is created.

Total time from start to "in a raid": **15–30 minutes**, most of which is
the local EFT clone and mod downloads.

---

## Running the game

1. Launch **SPT Launcher** from the Start Menu (or
   `C:\SPT\SPT\SPT.Launcher.exe`).
2. The launcher should already be pointed at the host's server (look
   for `https://10.8.0.2:6969` in the server URL — it's set
   automatically). Create a profile or log in.
3. Click **Play**. Tarkov starts in SPT mode.
4. To join a Fika co-op raid the admin is hosting, use the in-game Fika
   menu and pick their session.

---

## Troubleshooting

### "Cannot connect to server" or the launcher hangs

The VPN tunnel may not be up. Open WireGuard (system tray icon) and
check that the tunnel named **spt-vpn** is **Active**. If it isn't,
click **Activate**. Then try the launcher again.

Sanity check from PowerShell:

```powershell
ping 10.8.0.2
```

You should see replies. If you don't:

- Make sure the WireGuard tunnel is active (system tray → **Manage
  tunnels** → **spt-vpn** should say *Active*).
- The host's PC must be on. The VPN can be up while their PC is off, but
  the launcher won't connect.
- If you suddenly get "Permission denied" the admin may have revoked
  your invite — ask them for a new one.

### "Automated download blocked" pops up during install

This happens when sp-tarkov.com's Hub interposes a captcha or moves a
mod's download URL. The installer will:

1. Open an empty folder in Explorer.
2. Show a message box telling you which URL to visit.

What to do:

1. Open the URL in your browser.
2. Solve any captcha and download the file (it'll be a `.zip` or `.7z`).
3. Save it into the folder Explorer just opened (filename doesn't
   matter — the installer auto-detects).
4. Click **OK** in the message box. The installer continues.

### EFT prereq fails ("Escape From Tarkov not detected")

The installer reads
`HKLM\SOFTWARE\Battlestate Games\EFT\Client\InstallLocation` from the
registry. If you have a portable EFT install, or just haven't run the
BSG launcher yet, this can come up empty.

Fix:

1. Install EFT via the [Battlestate Games launcher](https://www.escapefromtarkov.com/launcher).
2. Run the launcher and log in once so it writes the registry key.
3. Re-run `SptVpnSetup.exe`.

### Install log

Detailed logs land in `%ProgramData%\spt-vpn\install.log`. Send this to
the admin if something goes sideways.

### Uninstalling

Use **Settings → Apps → SPT-VPN Setup → Uninstall**. This removes the
WireGuard tunnel service. To also delete the game files, manually delete
`C:\SPT` afterwards.

---

## What this does and does not do

It **does**:

- Install WireGuard and create one tunnel called `spt-vpn` scoped to
  reach only the admin's PC (10.8.0.2).
- Install SPT + Fika in `C:\SPT` (or your chosen folder), separate from
  your real EFT install.
- Download mods the admin has flagged as required/optional from their
  original public sources (sp-tarkov Hub, GitHub releases).
- Patch the SPT launcher config to point at the host.

It does **not**:

- Modify your real EFT install. Your live Tarkov is untouched.
- Route your normal internet through the VPN. Only traffic for
  `10.8.0.2` goes over the tunnel; everything else is unchanged.
- Send your EFT or SPT files anywhere. EFT clone is purely local.
- Bundle Escape From Tarkov game files. Those come from your own legit
  install.
- Auto-update itself or mods. If the admin pushes a new modlist, re-run
  `SptVpnSetup.exe` with the same invite token to refresh.

---

## Privacy and security

- The installer requires administrator rights to install WireGuard as
  a Windows service and write to `C:\Program Files\WireGuard\Data`.
- Your invite token authenticates you to the admin's enrollment service
  and is single-use. After install, the token is consumed; only the
  WireGuard keypair (generated locally, private key never leaves your
  PC) authenticates from then on.
- All traffic to the admin's enrollment service is over HTTPS with a
  pinned self-signed certificate; man-in-the-middle attempts will fail.
- Mod downloads come from their original public URLs over your normal
  internet, not the VPN.

---

## For the admin (server-side)

See [server/README.md](server/README.md) and
[publish/README.md](publish/README.md) for operating the enrollment
service and updating the mod manifest.
