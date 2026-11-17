# Screenshots

How screenshots and screen recordings are added to the guides. They live in `docs/images/<system>/` and are named
after the step they show, for example `docs/images/windows/rustdesk-network-servers.gif`.

## Rules

Check every screenshot, and every frame of a recording, by hand before committing it: the private data check skips
images. Cover or crop out:

- Real Tailscale addresses (`100.x`), home addresses (`192.168.x`, `10.x`, `172.16.x` to `172.31.x`), and any IPv6
  address. The guides' example addresses (`100.64.0.10` to `100.64.0.12`) may show: setting your devices to them in
  the Tailscale admin console (a machine's `...` menu, **Edit machine IPv4**) keeps real ones out of a recording.
- RustDesk IDs and one-time passwords shown in RustDesk's main window.
- Two-factor QR codes. Never commit one, even blurred: show the step with the code area cropped out.

Account names, machine names, the repo owner's name and photo, and Tailscale sign-in links may show.

Blur isn't enough for text: some blurs can be reversed. Use solid boxes, and in a recording make sure they cover the
text in every frame. Crop to the part of the screen the step is about. Save stills as PNG. Save recordings as GIF,
640 pixels wide at 8 frames a second, and keep them short: every guide reader who downloads the repo downloads them.

## Shot list: Windows

Script output isn't a screenshot: the guides show it as text, with the example addresses, so readers can search it
and the private data check can scan it. Save these in `docs/images/windows/`.

| File | Shows | Guide and step |
|---|---|---|
| `tailscale-tray-login.gif` (taken) | The Tailscale tray icon menu with **Log in** | Host manual 1 |
| `tailscale-login-page.png` (taken) | Tailscale's sign-in page | Host manual 1 |
| `tailscale-connect-device.gif` (taken) | The **Connect device** page, then "Login successful" | Host manual 1 |
| `tailscale-admin-key-expiry.gif` (taken) | Admin console `...` menu with **Disable key expiry** | Host manual 1 |
| `powershell-run-as-admin.gif` (taken) | Start menu search, right-click Windows PowerShell, **Run as administrator** | Host manual 3 |
| `rustdesk-settings-open.png` (taken) | RustDesk main window and its **Settings** tab (ID covered) | Host manual 4 |
| `rustdesk-security.png` (taken) | Security page, unlocked: password, two-factor and direct IP settings | Host manual 4 |
| `rustdesk-direct-ip-whitelist.gif` (taken) | Turning on IP whitelisting and adding the controller's address | Host manual 4 |
| `rustdesk-network-servers.gif` (taken) | Network page with `127.0.0.1` in ID and Relay server | Host manual 4 |
| `rustdesk-connect-box.png` | Controller's **Control Remote Desktop** box | Controller 3 |
| `rustdesk-2fa-prompt.png` | The 6-digit code prompt when connecting | Controller 3 |

The last two need a Windows controller.
