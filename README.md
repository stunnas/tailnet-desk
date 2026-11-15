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
| [`Undo-HostFirewall.ps1`](scripts/windows/Undo-HostFirewall.ps1) | Windows host, as administrator | Puts RustDesk's Allow rules back on every network adapter. Edge traversal stays Block. |
| [`install-host.sh`](scripts/mac/install-host.sh) | Mac host, in Terminal | Installs RustDesk if it's missing, sets its security settings, stops sleep on the charger, then checks the result. Tailscale, RustDesk's service and its macOS permissions stay manual. Never sets or shows a password. |
| [`test-host.sh`](scripts/mac/test-host.sh) | Mac host, in Terminal | Checks the host's setup. Changes nothing. |
| [`test-from-controller.sh`](scripts/mac/test-from-controller.sh) | Mac controller, in Terminal | Checks a Windows or Mac host answers over Tailscale and not over the home network. Changes nothing. |
| [`enable-pf.sh`](scripts/mac/enable-pf.sh) / [`undo-pf.sh`](scripts/mac/undo-pf.sh) | Mac host, in Terminal | Optional: lets RustDesk's port answer only to Tailscale addresses, also after a restart / undoes it. |

The scripts install pinned versions and check RustDesk's SHA-256 fingerprint before running it. On Windows the pins
are in `Setting` at the top of [`TailnetDesk.psm1`](scripts/windows/TailnetDesk.psm1): open it and read the lines
`RustDeskVersion = '...'` (also used by the guides' manual path) and `TailscaleWinget = '...'` (used only by the
script; the manual path installs Tailscale's current release, and Tailscale updates itself either way). On a Mac they
are at the top of [`tailnet-desk.sh`](scripts/mac/tailnet-desk.sh), with RustDesk's Apple signing team, which the
script checks too; Tailscale is installed by hand there. The RustDesk version is the same on both, and a test checks
that. The Windows scripts are PowerShell, which every Windows PC has; the Mac scripts and the repo's checks are bash,
and the Mac scripts run on the bash 3.2 every Mac has.

## Folders

| Folder | Holds |
|---|---|
| `docs/` | The guides, the glossary and the screenshot rules |
| `scripts/windows/` | The Windows scripts and their shared module, named in PowerShell's Verb-Noun style |
| `scripts/mac/` | The Mac scripts and their shared library, named in kebab-case like the repo's checks |
| `tests/` | Pester tests for the Windows module, bats tests for the Mac library and the repo checks, and planted test data |
| `tools/` | The repo's own checks (private data, links) and the CI module installer, named in kebab-case |

## Status

Phase 1 (Windows) is being tested; phase 2 (Mac) and the iPhone guide are being written.

| Part | Tested how |
|---|---|
| Manual steps in the Windows guides | Followed on two PCs with RustDesk 1.5.3. Not confirmed on a real PC yet: host manual step 3, command 3 (edge traversal) and command 6 as now written (firewall profiles as Windows applies them). |
| The shared module (`TailnetDesk.psm1`) | Its checks are tested automatically, and so are most of its steps, with the Windows commands they call replaced by stand-ins (mocks). The firewall reads that pass rules from one Windows command to the next aren't. |
| The four scripts themselves | Not tested automatically: their step order and how they combine the module's results are checked only by running them. |
| The scripts on a real PC | `Test-Host.ps1` and the module's read-only commands ran on a set-up Windows 11 PC: RustDesk's settings, the firewall profiles and rules, the registry paths and the locked-installer launch all worked. **`Install-Host.ps1` hasn't been run on a real PC yet.** Until it has, follow the guides' manual path. |
| Mac guides | Most manual host steps match a MacBook set up as a host with RustDesk 1.5.3 and used from an iPhone. Not yet followed: the ID and relay server setting, the firewall steps, and the Mac controller guide. |
| The Mac scripts | Their checks are tested automatically on macOS's own bash 3.2. **Not yet run end to end on a real Mac.** |
| iPhone guide | Matches an iPhone used as a controller for a Mac host; not yet followed with a Windows host. |

## License

[MIT](LICENSE)
