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

Account names, machine names, the tailnet's name as Tailscale shows it at sign-in (such as `stunnas.github`), the
repo owner's name and photo, and Tailscale sign-in links may show. MagicDNS names (ending in `.ts.net`) may not: the
private data check blocks them in text, so cover them in images too.

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

## Shot list: Mac

None are taken yet. As for Windows, script output is shown as text in the guide, not as a screenshot.

| File | Shows | Guide and step |
|---|---|---|
| `tailscale-mac-extension.png` | macOS asking to allow Tailscale's network extension | Host manual 1, controller 1 |
| `rustdesk-mac-install-service.png` | RustDesk's prompt to install its service | Host manual 2 |
| `privacy-screen-recording.png` | Privacy & Security → Screen & System Audio Recording with RustDesk on | Host manual 2 |
| `privacy-accessibility.png` | Privacy & Security → Accessibility with RustDesk on | Host manual 2 |
| `rustdesk-mac-security.png` | RustDesk's Security settings (ID and password covered) | Host manual 3 |
| `battery-prevent-sleep.png` | Battery → Options with "Prevent automatic sleeping on the power adapter" on | Host manual 4 |
| `macos-firewall-options.png` | Network → Firewall → Options with stealth mode on | Optional macOS firewall |

Save these in `docs/images/mac/`.

## Shot list: iPhone

None are taken yet. Taken on the iPhone (the owner takes these: press the side button and volume up together). Crop the status bar out:
it can show the carrier, time and notifications.

| File | Shows | Guide and step |
|---|---|---|
| `tailscale-ios-connected.png` | Tailscale app showing Connected (addresses covered) | iPhone 1 |
| `rustdesk-ios-app-store.png` | The App Store page for RustDesk Remote Desktop by Purslane Limited | iPhone 2 |
| `rustdesk-ios-remote-id.png` | The Remote ID box with an example `100.x` address typed in | iPhone 3 |
| `rustdesk-ios-2fa-prompt.png` | The 6-digit code prompt when connecting | iPhone 3 |
| `rustdesk-ios-display-menu.png` | The session's display menu with frame rate and image quality | iPhone 3 |

Save these in `docs/images/iphone/`.
