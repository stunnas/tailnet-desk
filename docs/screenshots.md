# Screenshots

How screenshots are added to the guides. They live in `docs/images/<system>/` and are named after the step they
show, for example `docs/images/windows/rustdesk-security-unlock.png`.

## Rules

Check every screenshot by hand before committing it: the private data check skips images. Cover or crop out:

- Tailscale addresses (`100.x`), home addresses (`192.168.x`, `10.x`, `172.16.x` to `172.31.x`), and any IPv6 address.
- RustDesk IDs and one-time passwords shown in RustDesk's main window.
- Two-factor QR codes. Never commit one, even blurred: show the step with the code area cropped out.
- Computer names, account names, email addresses and anything else that identifies a person or a device.

Blur isn't enough for text: some blurs can be reversed. Use solid boxes. Crop to the part of the screen the step
is about, and save as PNG.

## Shot list: Windows

None are taken yet. Script output isn't a screenshot: the guides show it as text, with the example addresses, so
readers can search it and the private data check can scan it.

| File | Shows | Guide and step |
|---|---|---|
| `tailscale-tray-login.png` | The Tailscale tray icon menu with **Log in** | Host manual 1, controller 1 |
| `tailscale-admin-key-expiry.png` | Admin console `...` menu with **Disable key expiry** (machine names covered) | Host manual 1 |
| `powershell-run-as-admin.png` | Start menu, right-click Windows PowerShell, **Run as administrator** | Host manual 3 |
| `rustdesk-settings-open.png` | RustDesk main window with the Settings menu (ID and password covered) | Host manual 4 |
| `rustdesk-security-top.png` | Security page, unlocked: the password section with **Use permanent password** and the two-factor switch, QR code cropped out | Host manual 4 |
| `rustdesk-direct-ip-whitelist.png` | Security page: direct IP access and the whitelist (addresses covered) | Host manual 4 |
| `rustdesk-network-servers.png` | Network page with `127.0.0.1` in ID and Relay server | Host manual 4, controller 2 |
| `rustdesk-connect-box.png` | Controller's **Control Remote Desktop** box | Controller 3 |
| `rustdesk-2fa-prompt.png` | The 6-digit code prompt when connecting | Controller 3 |

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
