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
| [`install-host.ps1`](scripts/windows/install-host.ps1) | Windows host, as administrator | Installs Tailscale and RustDesk, limits the firewall, sets RustDesk's security settings, stops sleep while plugged in, then checks the result. Never sets or shows a password. |
| [`test-host.ps1`](scripts/windows/test-host.ps1) | Windows host, as administrator | Checks the host's setup. Changes nothing. |
| [`test-from-controller.ps1`](scripts/windows/test-from-controller.ps1) | Windows controller | Checks the host answers over Tailscale and not over the home network. Changes nothing. |
| [`undo-host-firewall.ps1`](scripts/windows/undo-host-firewall.ps1) | Windows host, as administrator | Puts RustDesk's Allow rules back on every network adapter. Edge traversal stays Block. |

The scripts install pinned versions and check RustDesk's SHA-256 fingerprint before running it. Both pins are set in
one place, `Setting` at the top of [`tailnet-desk.psm1`](scripts/windows/tailnet-desk.psm1): open it and read the
lines `RustDeskVersion = '...'` (also used by the guides' manual path) and `TailscaleWinget = '...'` (used only by
the script; the manual path installs Tailscale's current release, and Tailscale updates itself either way). They're written in PowerShell, which every Windows PC has, and the repo's checks in bash.

## Folders

Every file is named in kebab-case (`install-host.ps1`, `host-windows.md`), except `README.md`, `LICENSE`, and the files whose tools expect a fixed name (`PSScriptAnalyzerSettings.psd1`, and Pester's `.Tests.ps1` ending).

| Folder | Holds |
|---|---|
| `docs/` | The guides, the glossary and the screenshot rules |
| `scripts/windows/` | The Windows scripts and their shared module |
| `tests/` | Pester tests for the Windows module, bats tests for the repo checks, and planted test data |
| `tools/` | The repo's own checks (private data, links) and the CI module installer |

## Status

Phase 1 (Windows) is being tested.

| Part | Tested how |
|---|---|
| Manual steps in the Windows guides | Followed on two PCs with RustDesk 1.5.3. Not confirmed on a real PC yet: host manual step 3, command 3 (edge traversal) and command 6 as now written (firewall profiles as Windows applies them). |
| The shared module (`tailnet-desk.psm1`) | Its checks are tested automatically, and so are most of its steps, with the Windows commands they call replaced by stand-ins (mocks). The firewall reads that pass rules from one Windows command to the next aren't. |
| The four scripts themselves | Not tested automatically: their step order and how they combine the module's results are checked only by running them. |
| The scripts on a real PC | On a Windows 11 PC that already had Tailscale and RustDesk 1.5.3, `install-host.ps1 -ControllerIp` ran every step and its check passed, and `test-host.ps1` passed after it. From the controller, RustDesk's port answered over Tailscale and not on the home network, and a device not on the whitelist was refused. An earlier run also tried the locked-installer launch, which worked. Not yet run on a real PC: installing Tailscale and RustDesk with the script, and `test-from-controller.ps1`. |

## License

[MIT](LICENSE)
