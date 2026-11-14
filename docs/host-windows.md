# Set up a Windows host

[Back to the README](../README.md) · [Glossary](glossary.md)

> **Do this on the HOST**: the Windows PC that will be controlled (for example the desktop you leave at home).
> The device you'll sit at is the controller; it has [its own guide](controller-windows.md).

When you're done, this PC can be reached by RustDesk from your controllers, only through Tailscale, only with a
password and a two-factor code, and from nowhere else.

**Example addresses in these guides:** the host is `100.64.0.10` (home address `192.168.0.10`) and the controller
is `100.64.0.11`. Yours will be different: always use the real ones from your Tailscale admin console.

## Contents

1. [Before you start](#before-you-start)
2. [The order across both devices](#the-order-across-both-devices)
3. [Manual path](#manual-path)
4. [Script path (not yet tested on a real PC)](#script-path-not-yet-tested-on-a-real-pc)
5. [Check the host](#check-the-host)
6. [When something goes wrong](#when-something-goes-wrong)

## Before you start

- **Admin rights on this PC.** Installing programs and changing firewall rules need them.
- **An account to sign in to Tailscale** (Google, Microsoft or GitHub). Turn on two-factor for that account first:
  whoever can sign in to it can add devices to your private network.
- **An authenticator app on your phone**, such as Microsoft Authenticator or Google Authenticator.
- **A password manager** (Bitwarden, 1Password, or the one built into your browser) to make and store a long
  random password.
- About 45 minutes.

## The order across both devices

The host's whitelist needs the controller's Tailscale address, and the controller only gets one after it joins
Tailscale. So:

1. **Host:** this guide, steps 1 and 2 of the manual path (or the script's first run).
2. **Controller:** [its guide, step 1](controller-windows.md#1-join-tailscale). Note its `100.x` address.
3. **Host:** finish this guide with the controller's address in the whitelist.
4. **Controller:** [connect](controller-windows.md#3-connect) and [run the tests](controller-windows.md#test-from-the-controller).

## Manual path

### 1. Tailscale

1. Download Tailscale from [tailscale.com/download](https://tailscale.com/download) and install it.
2. Click the Tailscale icon by the clock (click `^` if you don't see it), choose **Log in**, and sign in. Use the
   **same account** on every device: two accounts make two separate networks that can't see each other.
3. **Turn off key expiry.** In the [admin console](https://login.tailscale.com/admin/machines), click the `...` menu
   next to this PC and choose **Disable key expiry**. Otherwise Tailscale makes the PC sign in again every 180
   days, and a host nobody sits at can't.
4. Note this PC's address starting with `100.` from the admin console: the controller connects to it.

### 2. RustDesk

1. Download it **only** from [github.com/rustdesk/rustdesk/releases](https://github.com/rustdesk/rustdesk/releases).
   Pick the release with the pinned version: open [`TailnetDesk.psm1`](../scripts/windows/TailnetDesk.psm1) and read the line
   `RustDeskVersion = '...'` near the top. Then open that
   release's **Assets** and pick the file ending in `x86_64.exe`. Fake RustDesk sites hand out malware, so don't use a search ad.
2. Run it and choose **Install** (not "Run without install"). Installing adds the RustDesk **service**, which
   lets you reach the PC even at the Windows sign-in screen.

### 3. Firewall: let RustDesk answer only through Tailscale

RustDesk's installer adds Windows Firewall rules that accept connections on every network adapter. These commands
limit them to Tailscale, so a device on your home network (a guest's phone, a hacked smart TV) can't reach
RustDesk at all. It's a second lock next to the whitelist: the firewall stops connections before RustDesk sees
them. Do this before turning on direct IP access in step 4, so RustDesk is never reachable from every network.

**Open PowerShell as administrator:** press the Windows key, type `powershell`, right-click **Windows PowerShell**
and choose **Run as administrator**, then click **Yes**. The window title starts with "Administrator".

Paste each command as one line and press **Enter**. Common mistakes:

- **A missing hyphen** when copying, e.g. `SelectObject` instead of `Select-Object`. PowerShell then says the term
  "is not recognized".
- **A `>>` prompt** means PowerShell is waiting for the rest of a command. Press **Ctrl+C** and paste again.

1. Find the Tailscale adapter's name. It's almost always `Tailscale` ("Tailscale Tunnel"):

```powershell
Get-NetAdapter | Select-Object Name, InterfaceDescription
```

2. See RustDesk's firewall rules. Their names vary: some PCs have `RustDesk Service` and `rustdesk.exe` rules,
   others only `RustDesk Service`. A red "No MSFT_NetFirewallRule objects found" error for a missing name is
   harmless; the rules that exist are still listed.

```powershell
Get-NetFirewallRule -DisplayName "RustDesk Service","rustdesk.exe" | Select-Object DisplayName, Direction, Action, EdgeTraversalPolicy
```

3. Only if a rule shows `DeferToUser` in the last column: switch it to `Block`. Windows won't limit such a rule to
   one adapter. Skip this if every rule shows `Block`.

```powershell
Get-NetFirewallRule -DisplayName "RustDesk Service","rustdesk.exe" | Where-Object EdgeTraversalPolicy -eq "DeferToUser" | Set-NetFirewallRule -EdgeTraversalPolicy Block
```

4. Limit the rules that **Allow** RustDesk to Tailscale. It prints nothing when it works.

```powershell
Get-NetFirewallRule -DisplayName "RustDesk Service","rustdesk.exe" | Where-Object Action -eq "Allow" | Set-NetFirewallRule -InterfaceAlias "Tailscale"
```

5. Check: every Allow rule should show `InterfaceAlias : Tailscale`.

```powershell
Get-NetFirewallRule -DisplayName "RustDesk Service","rustdesk.exe" | Where-Object Action -eq "Allow" | Get-NetFirewallInterfaceFilter
```

6. Make sure the firewall itself is on and blocks connections nobody asked for. This reads what Windows actually
   applies, including any company or Group Policy settings: Domain, Private and Public should all show `Enabled` as
   `True` and `DefaultInboundAction` as `Block`.

```powershell
Get-NetFirewallProfile -PolicyStore ActiveStore | Select-Object Name, Enabled, DefaultInboundAction
```

### 4. RustDesk security settings

Open RustDesk, click the menu next to your ID (or the gear icon) to open **Settings**, go to **Security**, and click
**Unlock security settings** (approve the admin prompt). Menu names may differ slightly between versions.

| Where | Setting | Set it to | Why |
|---|---|---|---|
| Security | Password | **Use permanent password**, then **Set permanent password** | Generate a random password of 20 or more characters in your password manager, save it there, and paste it in. Never reuse it, not even on another of your computers: one leak would then open both. It lets you connect when nobody is at the host. |
| Security | Two-factor authentication | **On** | A QR code appears. In your authenticator app, tap **+**, scan it, and name the entry after this PC. A stolen password alone is then useless. Don't photograph or share the QR code: it's the secret that makes the codes. |
| Security | Accept sessions | **via password** | A session starts on the password and code alone. Nobody has to be at the host to click Accept. |
| Security | Deny LAN discovery | **On** (ticked) | The PC stops announcing itself to other RustDesk apps on your home network. |
| Security | Enable direct IP access | **On**, port **21118** | The controller connects straight to the host's Tailscale address, not through RustDesk's public servers. |
| Security | Use IP whitelisting | **On**, add only the controller's `100.x` address | RustDesk refuses everything else with "Your ip is blocked by the peer". Never add this PC's own address, and never a whole range like `100.64.0.0/10`: that lets in every device on your Tailscale network. |
| Network | ID server and Relay server | `127.0.0.1` in both | Stops the PC registering with RustDesk's public servers, which would be a second way in outside Tailscale. RustDesk will then say it can't reach a server; that's expected. |

### 5. Never sleep while plugged in

Windows **Settings → System → Power** ("Power & battery" on Windows 11): set **Sleep** to **Never** when plugged
in. A sleeping PC can't be reached. The screen turning off is fine.

Then [check the host](#check-the-host) and go to the controller to [connect](controller-windows.md#3-connect).

## Script path (not yet tested on a real PC)

> **Not yet run on a real Windows PC.** The script's checks are tested automatically, but the steps that change
> Windows aren't. Until it has been run on a real host, use the manual path above. See the
> [README's Status](../README.md#status).

The script does the manual path's steps except the ones that need you: signing in to Tailscale, turning off key
expiry, choosing the password and scanning the two-factor QR code. It's safe to run more than once: each run skips
what's already done and keeps the controllers already on the whitelist.

### 1. Get the scripts

1. Open [the repo's main page](https://github.com/stunnas/tailnet-desk), click the green **Code** button, then
   **Download ZIP**.
2. Open your Downloads folder, right-click the ZIP and choose **Extract All**, then **Extract**.
3. Open the extracted `tailnet-desk-main` folder (open it twice if there's a folder with the same name inside),
   then `scripts`, then `windows`. Keep this window open.

### 2. Open PowerShell as administrator in that folder

1. Open PowerShell as administrator ([how](#3-firewall-let-rustdesk-answer-only-through-tailscale)).
2. Type `cd ` (with a space), drag the `windows` folder from File Explorer into the PowerShell window, and press
   **Enter**. The prompt now ends in `\scripts\windows>`.
3. Windows blocks scripts downloaded from the internet by default. Allow these ones for this window only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

```powershell
Get-ChildItem *.ps1, *.psm1 | Unblock-File
```

The first command only lasts until you close this window. The second removes the "downloaded from the internet"
mark from these files, so Windows stops asking about them.

### 3. First run

```powershell
.\Install-Host.ps1
```

What happens:

1. **Tailscale** (the pinned version) is installed with winget, Windows' own installer. The first time, the script stops
   and asks you to sign in: click the Tailscale icon by the clock, choose **Log in**, and sign in. Then run the same
   command again.
2. **RustDesk** (the pinned version) is downloaded from its official GitHub page into a new folder only
   administrators can change. The script checks the file's SHA-256 fingerprint against the one stored in the script,
   keeps the file locked until the installer finishes, and refuses to run a file that doesn't match.
3. **The firewall:** RustDesk's Allow rules are limited to the Tailscale adapter.
4. **RustDesk's settings:** the same as the manual table, except the password and two-factor. Direct IP access
   stays **off** for now, because there's no controller to whitelist yet.
5. **Sleep:** the PC no longer sleeps while plugged in.
6. **A check** runs and prints PASS or FAIL lines, then the steps left for you.

At the end it prints **this PC's Tailscale address**: the controller connects to it. Then do the manual path's
[key expiry step](#1-tailscale) (step 3) and the password and two-factor rows of [step 4](#4-rustdesk-security-settings).

### 4. Second run, with the controller's address

Once the controller has [joined Tailscale](controller-windows.md#1-join-tailscale), find the **controller's**
`100.x` address in the [Tailscale admin console](https://login.tailscale.com/admin/machines). Not this PC's own
address. Then, in the same admin PowerShell window, run the script with it in place of the example:

```powershell
.\Install-Host.ps1 -ControllerIp 100.64.0.11
```

This turns on direct IP access with only that address on RustDesk's whitelist. For more than one controller,
separate the addresses with commas: `-ControllerIp 100.64.0.11,100.64.0.12`. Later runs without `-ControllerIp`
keep the controller addresses already on the whitelist and drop anything that isn't a single Tailscale address, such
as a range or this PC's own address. If no valid address is left, direct IP access is turned off instead.

Then go to the controller to [connect](controller-windows.md#3-connect).

## Check the host

Run the check script on the host, in admin PowerShell in the `scripts\windows` folder (get it as in
[the script path, steps 1 and 2](#1-get-the-scripts)). It changes nothing and prints PASS or FAIL for each item.
Like the setup script, it hasn't been run on a real PC yet, so until it has, also confirm by hand: manual firewall
commands 5 and 6 above, the settings in [step 4's table](#4-rustdesk-security-settings), and the controller's
[tests by hand](controller-windows.md#by-hand).

```powershell
.\Test-Host.ps1
```

**Run it again after every RustDesk update**: an update may reinstall the firewall rules without the Tailscale limit.

It can't see the password or two-factor settings; check those in RustDesk. The tests that prove the firewall works
must run from the controller: see the [controller guide](controller-windows.md#test-from-the-controller).

## When something goes wrong

### Messages while running the scripts

| What you see | What it means | Fix |
|---|---|---|
| "running scripts is disabled on this system" | Windows' default script policy. | Run the two commands in [step 2.3](#2-open-powershell-as-administrator-in-that-folder) in the same window. |
| "cannot be loaded ... not digitally signed" | The files still carry the downloaded-from-the-internet mark. | Run the `Unblock-File` command in step 2.3. |
| "... contains a #requires statement for running as Administrator" | PowerShell isn't running as administrator. | Close it and open it again with **Run as administrator**. |
| "winget is missing" | Older Windows without winget. | Install Tailscale from [tailscale.com/download](https://tailscale.com/download), then run the script again. |
| "Not a Tailscale address" | An address given to `-ControllerIp` doesn't start with `100.`. | Copy the controller's address from the Tailscale admin console. |
| "... is this PC's own address" | You gave the host's address instead of the controller's. | Use the controller's `100.x` address. |
| "The '<' operator is reserved" | Angle brackets were left in a command. | Type the real value without `<` and `>`. |
| "The RustDesk service didn't start within a minute" | RustDesk installed, but its background service didn't start. | Restart the PC and run the script again. |
| "RustDesk didn't take the setting ..." | RustDesk refused a setting, usually because its service isn't running. | Restart the PC and run the script again. |

### FAIL lines from Test-Host.ps1

| FAIL line | Fix |
|---|---|
| Tailscale is signed in | Click the Tailscale icon by the clock and choose **Log in**. |
| Network adapter 'Tailscale' exists | Reinstall Tailscale. If `Get-NetAdapter` shows it under another name, use that name in the manual firewall commands. |
| RustDesk is installed / RustDesk service is running | Reinstall RustDesk ([manual step 2](#2-rustdesk)), choosing **Install**. A stopped service: restart the PC. |
| Given controller address ... / Whitelist entry ... is one Tailscale address | Replace it with the controller's single `100.x` address, no ranges. |
| Whitelist doesn't include this PC's own address | Remove the host's own `100.x` address from the whitelist: only controllers belong there. |
| Whitelist is not empty while direct IP access is on | Add the controller's address to the whitelist, or turn off direct IP access. |
| RustDesk setting ... | That setting differs from [step 4's table](#4-rustdesk-security-settings). Fix it in RustDesk, or run `Install-Host.ps1` again. |
| RustDesk listens on TCP 21118 | Direct IP access is on but nothing listens: restart the PC. |
| Windows Firewall is on for the ... profile | Turn Windows Firewall back on for that profile (Windows Security → Firewall & network protection). |
| RustDesk firewall rules exist | Reinstall RustDesk; its installer creates them. |
| Rule '...' only on Tailscale | Usually after a RustDesk update. Run [manual firewall commands 3 and 4](#3-firewall-let-rustdesk-answer-only-through-tailscale) again, or `Install-Host.ps1`. If the rule has another name, the manual commands won't find it: run `Install-Host.ps1`, or limit it to Tailscale in Windows Defender Firewall → Advanced settings, as for a port rule. |
| Windows Firewall blocks unasked-for connections on the ... profile | Set **Inbound connections** back to **Block (default)** for that profile in Windows Defender Firewall → Advanced settings → Windows Defender Firewall Properties. |
| Port rule: ... | A rule lets any program in on port 21118 (or on all ports) from every network. Find it in Windows Defender Firewall → Advanced settings → Inbound Rules, and delete it or limit it to Tailscale. |

### Other problems

| What you see | What it means | Fix |
|---|---|---|
| "Your ip is blocked by the peer" on the controller | The controller's address isn't on the whitelist, or Tailscale is off on the controller. | Check the controller's `100.x` address and add it (manual step 4, or the script's second run). |
| Lost the phone with the authenticator app | You can't pass two-factor. | Sit at the host, turn two-factor off and on in RustDesk's Security settings, and scan the new QR code. |

**Undo the firewall step** (admin PowerShell, in `scripts\windows`). It puts RustDesk's Allow rules back on every
network adapter. The edge traversal setting (whether a rule may let in connections from outside your router) stays
`Block`.

```powershell
.\Undo-HostFirewall.ps1
```
