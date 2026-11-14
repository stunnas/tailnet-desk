# tailnet-desk

See and use one computer's screen from another, from anywhere, without opening anything to the internet.
[RustDesk](https://github.com/rustdesk/rustdesk) shows the screen; [Tailscale](https://tailscale.com) is a
private network between your own devices that carries it. The guides are written for beginners, and scripts do the
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

New to words like port, firewall or IP address? Read the [glossary](docs/glossary.md) first.

## How it stays safe

Anyone who reaches a host's remote desktop could control the whole computer, so the host gets four separate locks.

1. **Tailscale.** Only devices signed in to your Tailscale account can find the host. Nothing is exposed to the
   internet, and the traffic is encrypted.
2. **Firewall.** The host's RustDesk only answers through Tailscale, not through home Wi-Fi or a public network.
3. **RustDesk's IP whitelist.** RustDesk refuses every device except your controllers.
4. **Password and two-factor.** Each connection needs a long password and a 6-digit code from your phone.

The host also stops using RustDesk's public servers, so the only way in is through Tailscale.

Someone on the internet or on your home network has to get past all four. Someone who has one of your controllers,
unlocked, is already past the first three, so only the password and two-factor code stand in the way. Keep your
controllers locked, and don't let RustDesk remember the host's password on them
([controller guide](docs/controller-windows.md#3-connect)).

## Scripts

| Script | Run on | Does |
|---|---|---|
| [`Install-Host.ps1`](scripts/windows/Install-Host.ps1) | Windows host, as administrator | Installs Tailscale and RustDesk, limits the firewall, sets RustDesk's security settings, stops sleep while plugged in, then checks the result. Never sets or shows a password. |
| [`Test-Host.ps1`](scripts/windows/Test-Host.ps1) | Windows host, as administrator | Checks the host's setup. Changes nothing. |
| [`Test-FromController.ps1`](scripts/windows/Test-FromController.ps1) | Windows controller | Checks the host answers over Tailscale and not over the home network. Changes nothing. |
| [`Undo-HostFirewall.ps1`](scripts/windows/Undo-HostFirewall.ps1) | Windows host, as administrator | Puts RustDesk's firewall rules back on every network adapter. |

The scripts install pinned versions and check RustDesk's SHA-256 fingerprint before running it. The pinned versions,
which the manual path uses too, are set in one place: `Setting` at the top of
[`TailnetDesk.psm1`](scripts/windows/TailnetDesk.psm1) (`RustDeskVersion`, `TailscaleWinget`). They're written in PowerShell, which every Windows PC has, and the repo's checks in bash.

## Folders

| Folder | Holds |
|---|---|
| `docs/` | The guides, the glossary and the screenshot rules |
| `scripts/windows/` | The Windows scripts and their shared module (PowerShell files use PowerShell's Verb-Noun names) |
| `tests/` | Pester tests for the Windows module, bats tests for the repo checks, and planted test data |
| `tools/` | The repo's own checks: private data, links, and the CI module installer |

## Status

Phase 1 (Windows) is being tested. The manual steps in the Windows guides were followed on two PCs with RustDesk
1.5.3. The scripts' checks (addresses, RustDesk settings, firewall rule results) and the installer's fingerprint
check are tested automatically; the steps that change Windows are not, and the scripts **have not yet been run on a
real Windows PC**. Until they have, follow the guides' manual path.

## License

[MIT](LICENSE)
