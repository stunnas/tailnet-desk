# tailnet-desk

See and use one computer's screen from another, from anywhere, without opening anything to the internet.
[RustDesk](https://github.com/rustdesk/rustdesk) shows the screen; [Tailscale](https://tailscale.com) is a
private network between your own devices that carries it. Guides are written for beginners, and scripts do the
repeatable parts on Windows.

## Host and controller

Every setup has two roles. Get these right and the rest follows.

| Role | What it is | What it needs |
|---|---|---|
| **Host** | The computer being controlled. You leave it behind and reach into it. | Tailscale, RustDesk, and the lock-down steps: it's the one that can be broken into. |
| **Controller** | The device in front of you: a laptop, another PC, a phone. | Tailscale and RustDesk. Nothing else. |

One computer can be both: set it up as a host, and it can still control others.

## Pick your guides

Follow one host guide and one controller guide.

| Host (being controlled) | Guide |
|---|---|
| Windows PC | [Set up a Windows host](docs/host-windows.md) |
| Mac | Coming in phase 2 |

| Controller (in front of you) | Guide |
|---|---|
| Windows PC | [Set up a Windows controller](docs/controller-windows.md) |
| Mac | Coming in phase 2 |
| iPhone | Coming in phase 3 |

New to networking words like port, firewall or IP address? Read the [glossary](docs/glossary.md) first.

## How it stays safe

Anyone who reaches a host's remote desktop could control the whole computer, so the host gets four separate
locks. An attacker would have to get past all of them.

1. **Tailscale.** Only devices signed in to your Tailscale account can find the host. Nothing is exposed to the
   internet, and the traffic is encrypted.
2. **Firewall.** The host's RustDesk only answers through Tailscale, not through home Wi-Fi or a public network.
3. **RustDesk's IP whitelist.** RustDesk refuses every device except your controllers.
4. **Password and two-factor.** Each connection needs a long password and a 6-digit code from your phone.

The host also stops using RustDesk's public servers, so the only way in is through Tailscale.

## Scripts

| Script | Run on | Does |
|---|---|---|
| [`Install-Host.ps1`](scripts/windows/Install-Host.ps1) | Windows host, as administrator | Installs Tailscale and RustDesk, sets RustDesk's security settings and the firewall, then checks the result. Never touches passwords. |
| [`Test-Host.ps1`](scripts/windows/Test-Host.ps1) | Windows host, as administrator | Checks the host's setup. Changes nothing. Run it after every RustDesk update. |
| [`Test-FromController.ps1`](scripts/windows/Test-FromController.ps1) | Windows controller | Checks the host answers over Tailscale and not over the home network. Changes nothing. |
| [`Undo-HostFirewall.ps1`](scripts/windows/Undo-HostFirewall.ps1) | Windows host, as administrator | Undoes the firewall step. |

Tested with RustDesk 1.5.3 and Windows PowerShell 5.1.

## Status

Phase 1 (Windows) is being tested. The manual steps in the Windows guides have been followed on two PCs; the
scripts are new and are being tested on a real host before they're recommended.

## License

[MIT](LICENSE)
