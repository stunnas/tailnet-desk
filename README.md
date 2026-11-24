# tailnet-desk

See and use one computer's screen from another, from anywhere, without opening anything to the internet.
[RustDesk](https://github.com/rustdesk/rustdesk) shows the screen; [Tailscale](https://tailscale.com) is a
private network between your own devices that carries it. The guides are written for beginners, and scripts do the
repeatable parts on Windows and Mac.

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
| Mac | [Set up a Mac host](docs/host-mac.md) |

| Controller (in front of you) | Guide |
|---|---|
| Windows PC | [Set up a Windows controller](docs/controller-windows.md) |
| Mac | [Set up a Mac controller](docs/controller-mac.md) |
| iPhone | [Set up an iPhone controller](docs/controller-iphone.md) |

New to words like port, firewall or IP address? Read the [glossary](docs/glossary.md) first.

## How it stays safe

Anyone who reaches a host's remote desktop could control the whole computer, so the host gets four separate locks
(three on a Mac host that skips the optional firewall step).

1. **Tailscale.** Only devices signed in to your Tailscale account can find the host. Nothing is exposed to the
   internet, and the traffic is encrypted.
2. **Firewall.** The host's RustDesk only answers through Tailscale, not through home Wi-Fi or a public network. On
   Windows the script always does this; on a Mac it's the optional
   [firewall step](docs/host-mac.md#optional-limit-rustdesk-to-tailscale-in-the-firewall), and without it the whitelist
   alone refuses other devices on the network.
3. **RustDesk's IP whitelist.** RustDesk refuses every device except your controllers.
4. **Password and two-factor.** Each connection needs a long password and a 6-digit code from your phone. A
   controller you choose to trust for two-factor skips the code for a while (host guide's security settings:
   [Windows](docs/host-windows.md#4-rustdesk-security-settings), [Mac](docs/host-mac.md#3-rustdesk-security-settings)).

The host also stops using RustDesk's public servers, so the only way in is through Tailscale.

Someone on the internet or on your home network has to get past all of them. Someone who has one of your controllers,
unlocked, is already past the first three, so only the password and two-factor code stand in the way. Keep your
controllers locked, don't let RustDesk remember the host's password on them, and only trust a controller for
two-factor if it stays locked (controller guides: [Windows](docs/controller-windows.md#3-connect),
[Mac](docs/controller-mac.md#3-connect), [iPhone](docs/controller-iphone.md#3-connect)).

## Scripts

| Script | Run on | Does |
|---|---|---|
| [`install-host.ps1`](scripts/windows/install-host.ps1) | Windows host, as administrator | Installs Tailscale and RustDesk, limits the firewall, sets RustDesk's security settings, stops sleep while plugged in, then checks the result. Never sets or shows a password. |
| [`test-host.ps1`](scripts/windows/test-host.ps1) | Windows host, as administrator | Checks the host's setup. Changes nothing. |
| [`test-from-controller.ps1`](scripts/windows/test-from-controller.ps1) | Windows controller | Checks the host answers over Tailscale and not over the home network. Changes nothing. |
| [`undo-host-firewall.ps1`](scripts/windows/undo-host-firewall.ps1) | Windows host, as administrator | Puts RustDesk's Allow rules back on every network adapter. Edge traversal stays Block. |
| [`install-host.sh`](scripts/mac/install-host.sh) | Mac host, in Terminal | Installs Tailscale and RustDesk if they're missing, sets RustDesk's security settings, stops sleep on the charger, then checks the result. Allowing Tailscale's network extension and signing in, RustDesk's service and its macOS permissions stay manual. Never sets or shows a password. |
| [`test-host.sh`](scripts/mac/test-host.sh) | Mac host, in Terminal | Checks the host's setup. Changes nothing. |
| [`test-from-controller.sh`](scripts/mac/test-from-controller.sh) | Mac controller, in Terminal | Checks a Windows or Mac host answers over Tailscale and not over the home network. Changes nothing. |
| [`enable-pf.sh`](scripts/mac/enable-pf.sh) / [`undo-pf.sh`](scripts/mac/undo-pf.sh) | Mac host, in Terminal | Optional: lets RustDesk's port answer only to addresses in Tailscale's ranges (which a few carrier-grade NAT networks also use), also after a restart / undoes it. |

The scripts install pinned versions and check each installer before running it: its SHA-256 fingerprint, and that
it carries its publisher's valid signature (`PURSLANE` for RustDesk and `Tailscale Inc.` for Tailscale on Windows;
their Apple developer teams on a Mac, where Apple must also have notarized Tailscale's installer). The host guides'
script paths have the details. On Windows the pins are in `Setting` at the top of
[`tailnet-desk.psm1`](scripts/windows/tailnet-desk.psm1): open it and read the lines `RustDeskVersion = '...'` (also
used by the guides' manual path) and `TailscaleVersion = '...'` with the installer's SHA-256 (used only by the script;
the manual path installs Tailscale's current release). On a Mac they are at the top of
[`tailnet-desk.sh`](scripts/mac/tailnet-desk.sh): `TD_RUSTDESK_VERSION`, and `TD_TAILSCALE_VERSION` with the
Tailscale installer's SHA-256. Both versions are the same on Windows and Mac, and tests check that. Each week the
[version watch](.github/workflows/version-watch.yml) compares them with the releases and, when a bump is due, opens
a PR with the new versions, their SHA-256 values and links to the release notes; trying a new version on a real
machine stays by hand. The Windows
scripts are PowerShell, which every Windows PC has; the Mac scripts and the repo's checks are bash, and the Mac
scripts run on the bash 3.2 every Mac has.

## Folders

Every file is named in kebab-case (`install-host.ps1`, `install-host.sh`, `host-windows.md`), except `README.md`, `LICENSE`, git's own dotfiles, and the files whose tools expect a fixed name: `PSScriptAnalyzerSettings.psd1` and `.shellcheckrc`
(both read by editors and CI) and Pester's `.Tests.ps1` ending.

| Folder | Holds |
|---|---|
| `docs/` | The guides, the glossary and the screenshot rules |
| `scripts/windows/` | The Windows scripts and their shared module |
| `scripts/mac/` | The Mac scripts and their shared library |
| `tests/` | Pester tests for the Windows module, bats tests for the Mac library and the repo checks, and planted test data |
| `tools/` | The repo's own checks (private data, links), the version watch's comparison and download check, and the CI module installer |

## Status

Phase 1 (Windows) is being tested; phase 2 (Mac) and the iPhone guide are being written.

| Part | Tested how |
|---|---|
| Manual steps in the Windows guides | Followed on two PCs with RustDesk 1.5.3. Not confirmed on a real PC yet: host manual step 3, command 3 (edge traversal) and command 6 as now written (firewall profiles as Windows applies them), and the Digital Signatures check in step 2 of both guides. |
| The shared module (`tailnet-desk.psm1`) | Its checks are tested automatically, and so are most of its steps, with the Windows commands they call replaced by stand-ins (mocks). The firewall reads that pass rules from one Windows command to the next aren't. |
| The four scripts themselves | Not tested automatically: their step order and how they combine the module's results are checked only by running them. |
| The scripts on a real PC | On a Windows 11 PC that already had Tailscale and RustDesk 1.5.3, `install-host.ps1 -ControllerIp` ran every step and its check passed, and `test-host.ps1` passed after it. From the controller, RustDesk's port answered over Tailscale and not on the home network, and a device not on the whitelist was refused. An earlier run also tried the locked-installer launch, which worked. Not yet run on a real PC: installing Tailscale (from its own installer) and RustDesk with the script, the publisher signature checks (added after that run, including `test-host.ps1`'s two signature lines), `install-host.ps1` waiting for the Tailscale sign-in and asking for the controller's address (both added since), and `test-from-controller.ps1`. |
| Mac guides | The manual host steps for RustDesk's install, service, permissions and security settings match a MacBook set up as a host with RustDesk 1.5.3 and used from an iPhone. Not yet followed: the manual pf commands, the macOS firewall step and the Mac controller guide. RustDesk's Mac buttons were checked on that Mac: Install adds its startup items, Stop service removes them, and Start service alone doesn't bring them back. |
| The Mac scripts | The library's checks that don't touch the system are tested automatically on macOS's own bash 3.2, and so are the installers' refusals (a wrong hash or signature installs nothing and runs nothing with sudo), with stand-ins for the programs they call. The scripts' own steps are checked only by running them. On a MacBook that was already a host (Tailscale and RustDesk installed): `test-host.sh` and `install-host.sh --keep-sleep` passed, and the run fixed one setting; `enable-pf.sh` (run twice), `test-host.sh` and `undo-pf.sh` passed, and iCloud Private Relay came back on after the undo, so each run released its pf reference; with pf on, the iPhone still connected over Tailscale and got "Failed to connect" on the Mac's Wi-Fi address. Not yet run on a real Mac: installing Tailscale and RustDesk with the script, `install-host.sh` waiting for the Tailscale sign-in and for RustDesk's service and asking for the controller's address (added since that run), the sleep step, the RustDesk signature check before running it with sudo, `enable-pf.sh` making its folder root's (added since that run), and the undo's path for a pf reference it can't release (tested only through its decision function). `test-from-controller.sh` ran on a Mac controller against a Windows host: the host's port answered over Tailscale and not on the home network. |
| iPhone guide | Partly followed with a Mac host: connecting over Tailscale asked for the permanent password and the two-factor code, and the Mac's Wi-Fi address got "Failed to connect" with its firewall step on. The app's other buttons and settings aren't confirmed yet. With a Windows host, an iPhone not on the whitelist got "Your ip is blocked by the peer"; the rest isn't followed with a Windows host yet. |

## License

[MIT](LICENSE)
