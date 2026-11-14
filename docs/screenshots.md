# Screenshots

How screenshots are added to the guides. They live in `docs/images/<system>/` and are named after the step they
show, for example `docs/images/windows/rustdesk-security-unlock.png`.

## Rules

Every screenshot is checked before it's committed. Cover or crop out:

- Tailscale addresses (`100.x`), home addresses (`192.168.x`), and any IPv6 address.
- RustDesk IDs and one-time passwords shown in RustDesk's main window.
- Two-factor QR codes. Never commit one, even blurred: show the step with the code area cropped out.
- Computer names, account names, email addresses and anything else that identifies a person or a device.

Blur isn't enough for text: some blurs can be reversed. Use solid boxes. Crop to the part of the screen the step
is about, and save as PNG.

## Shot list: Windows

| File | Shows | Guide and step |
|---|---|---|
| `tailscale-tray-login.png` | The Tailscale tray icon menu with **Log in** | Host manual 1, controller 1 |
| `tailscale-admin-key-expiry.png` | Admin console `...` menu with **Disable key expiry** (machine names covered) | Host manual 1 |
| `powershell-run-as-admin.png` | Start menu, right-click Windows PowerShell, **Run as administrator** | Host manual 3 |
| `install-host-output.png` | The end of `Install-Host.ps1` with PASS lines (addresses covered) | Host script path 3 |
| `rustdesk-settings-open.png` | RustDesk main window with the Settings menu (ID and password covered) | Host manual 4 |
| `rustdesk-security-unlock.png` | Security page with **Unlock security settings** | Host manual 4 |
| `rustdesk-permanent-password.png` | Password section with **Use permanent password** | Host manual 4 |
| `rustdesk-2fa-toggle.png` | Two-factor switch, QR code cropped out | Host manual 4 |
| `rustdesk-direct-ip-whitelist.png` | Direct IP access and the whitelist (addresses covered) | Host manual 4 |
| `rustdesk-network-servers.png` | Network page with `127.0.0.1` in ID and Relay server | Host manual 4, controller 2 |
| `test-host-output.png` | `Test-Host.ps1` all PASS | Check the host |
| `rustdesk-connect-box.png` | Controller's **Control Remote Desktop** box | Controller 3 |
| `rustdesk-2fa-prompt.png` | The 6-digit code prompt when connecting | Controller 3 |
| `test-from-controller-output.png` | `Test-FromController.ps1` all PASS (addresses covered) | Controller tests |
