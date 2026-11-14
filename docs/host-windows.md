# Set up a Windows host

[Back to the README](../README.md) · [Glossary](glossary.md)

> **Do this on the HOST**: the Windows PC that will be controlled (for example the desktop you leave at home).
> The device you'll sit at is the controller; it has [its own guide](controller-windows.md).

When you're done, this PC can be reached by RustDesk from your controllers, only through Tailscale, only with a
password and a two-factor code, and from nowhere else.

## Contents

1. [Before you start](#before-you-start)
2. [The order across both devices](#the-order-across-both-devices)
3. [Quick path: the setup script](#quick-path-the-setup-script)
4. [Manual path](#manual-path)
5. [Check the host](#check-the-host)
6. [When something goes wrong](#when-something-goes-wrong)

## Before you start

- **Admin rights on this PC.** Installing programs and changing firewall rules need them.
- **An account to sign in to Tailscale** (Google, Microsoft or GitHub). Turn on two-factor for that account first:
  whoever can sign in to it can add devices to your private network.
- **An authenticator app on your phone**, such as Microsoft Authenticator or Google Authenticator.
- **A password manager** (Bitwarden, 1Password, or the one built into your browser) to make and store a long
  random password.
- About 20 minutes with the script, 45 by hand.

## The order across both devices

The host's whitelist needs the controller's Tailscale address, and the controller only gets one after it joins
Tailscale. So:

1. **Host:** this guide, up to the point where it asks for the controller's address.
2. **Controller:** its guide, up to joining Tailscale. Note its `100.x` address.
3. **Host:** add the controller's address (the script's second run, or the whitelist by hand).
4. **Controller:** connect and run the tests.

## Quick path: the setup script

The script does every step except the ones that need you: signing in to Tailscale, choosing the password and
scanning the two-factor QR code. It's safe to run more than once; each run skips what's already done.

### 1. Get the scripts

1. Open [the repo's main page](https://github.com/stunnas/tailnet-desk), click the green **Code** button, then
   **Download ZIP**.
2. Open your Downloads folder, right-click the ZIP and choose **Extract All**, then **Extract**.
3. Open the extracted folder, then `scripts`, then `windows`. Keep this window open.

### 2. Open PowerShell as administrator in that folder

1. Press the Windows key, type `powershell`, right-click **Windows PowerShell** and choose **Run as
   administrator**. Click **Yes**. The window title starts with "Administrator".
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

1. **Tailscale** is installed (with winget, Windows' own installer). The first time, the script stops and asks you
   to sign in: click the Tailscale icon by the clock (click `^` if you don't see it), choose **Log in**, and sign
   in. Then run the same command again.
2. **RustDesk** is downloaded from its official GitHub page. The script checks the file's SHA-256 fingerprint
   against the one GitHub publishes and refuses to install a file that doesn't match.
3. **RustDesk's settings:** RustDesk's public servers are switched off, only the permanent password is accepted,
   and LAN discovery is off. Direct IP access stays **off** for now, because there's no controller to whitelist yet.
4. **The firewall:** RustDesk's rules are limited to the Tailscale adapter.
5. **Sleep:** the PC no longer sleeps while plugged in.
6. **A check** runs and prints PASS or FAIL lines, then the steps left for you.

At the end it prints **this PC's Tailscale address**. Write it down: the controller connects to it.

One Tailscale setting the script can't change: in the [admin console](https://login.tailscale.com/admin/machines),
click the `...` menu next to this PC and choose **Disable key expiry**. Otherwise Tailscale makes the PC sign in
again every 180 days, and a host nobody sits at can't.

### 4. Set the password and two-factor (by hand)

Open RustDesk, click the menu next to your ID (or the gear icon) to open **Settings**, go to **Security**, and
click **Unlock security settings** (approve the admin prompt).

1. **Password:** choose **Use permanent password**, then **Set permanent password**. Generate a random password
   of 20 or more characters in your password manager, save it there, and paste it in. Never reuse it, not even on
   another of your computers: one leak would then open both.
2. **Two-factor:** turn on **two-factor authentication**. A QR code appears. In your authenticator app, tap **+**,
   scan it, and name the entry after this PC. Don't photograph or share the QR code: it's the secret that makes
   the codes.

### 5. Second run, with the controller's address

Once the controller has joined Tailscale (its guide, step 1), find its `100.x` address in the
[Tailscale admin console](https://login.tailscale.com/admin/machines). Then, in the same admin PowerShell
window, run the script again with that address in place of the example:

```powershell
.\Install-Host.ps1 -ControllerIp 100.64.0.10
```

This turns on direct IP access with only that address on RustDesk's whitelist. For more than one controller,
separate the addresses with commas: `-ControllerIp 100.64.0.10,100.64.0.11`.

Then go to the controller and follow its guide to connect and test.

## Manual path

The same result by hand, for when you'd rather see each step or the script fails. Skip this section if the
script worked.

### 1. Tailscale

1. Download Tailscale from [tailscale.com/download](https://tailscale.com/download) and install it.
2. Click the Tailscale icon by the clock, choose **Log in**, and sign in. Use the **same account** on every
   device: two accounts make two separate networks that can't see each other.
3. In the [admin console](https://login.tailscale.com/admin/machines), click the `...` menu next to this PC and
   choose **Disable key expiry**. Otherwise Tailscale makes it sign in again every 180 days, and a host nobody
   sits at can't.

### 2. RustDesk

1. Download it **only** from [github.com/rustdesk/rustdesk/releases](https://github.com/rustdesk/rustdesk/releases).
   Under the newest release, open **Assets** and pick the file ending in `x86_64.exe`. Fake RustDesk sites hand
   out malware, so don't use a search ad.
2. Run it and choose **Install** (not "Run without install"). Installing adds the RustDesk **service**, which
   lets you reach the PC even at the Windows sign-in screen.

### 3. RustDesk security settings

Open RustDesk, go to **Settings**, then **Security**, and click **Unlock security settings**. Menu names may
differ slightly between versions.

| Where | Setting | Set it to | Why |
|---|---|---|---|
| Security | Password | **Use permanent password**, then **Set permanent password** | A random 20+ character password from your password manager, used nowhere else. Lets you connect when nobody is at the host. |
| Security | Two-factor authentication | **On**, scan the QR code with your authenticator app | A stolen password alone is useless. |
| Security | Enable direct IP access | **On**, port **21118** | The controller connects straight to the host's Tailscale address, not through RustDesk's public servers. |
| Security | Use IP whitelisting | **On**, add only the controller's `100.x` address | RustDesk refuses everything else with "Your ip is blocked by the peer". Never add a whole range like `100.64.0.0/10`: that lets in every device on your Tailscale network. |
| Network | ID server and Relay server | `127.0.0.1` in both | Stops the PC registering with RustDesk's public servers, which would be a second way in outside Tailscale. RustDesk will then say it can't reach a server; that's expected. |

Also set Windows **Settings → System → Power** so the PC never **sleeps** while plugged in. The screen turning
off is fine.

### 4. Firewall: let RustDesk answer only through Tailscale

RustDesk's installer adds Windows Firewall rules that accept connections on every network adapter. These
commands limit them to Tailscale, so a device on your home network (a guest's phone, a hacked smart TV) can't
reach RustDesk at all. It's a second lock next to the whitelist: the firewall stops connections before RustDesk
sees them.

Open PowerShell as administrator (see the quick path, step 2). Paste each command as one line and press
**Enter**. Common mistakes:

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
Get-NetFirewallRule -DisplayName "RustDesk Service","rustdesk.exe" | Select-Object DisplayName, Direction, Profile, EdgeTraversalPolicy
```

3. Only if a rule shows `DeferToUser` in the last column: switch it to `Block`. Windows won't limit such a rule to
   one adapter. Skip this if every rule shows `Block`.

```powershell
Get-NetFirewallRule -DisplayName "RustDesk Service","rustdesk.exe" | Where-Object EdgeTraversalPolicy -eq "DeferToUser" | Set-NetFirewallRule -EdgeTraversalPolicy Block
```

4. Limit the rules to Tailscale. It prints nothing when it works.

```powershell
Get-NetFirewallRule -DisplayName "RustDesk Service","rustdesk.exe" | Set-NetFirewallRule -InterfaceAlias "Tailscale"
```

5. Check: every rule should show `InterfaceAlias : Tailscale`.

```powershell
Get-NetFirewallRule -DisplayName "RustDesk Service","rustdesk.exe" | Get-NetFirewallInterfaceFilter
```

6. Make sure the firewall itself is on: Domain, Private and Public should all show `True`.

```powershell
Get-NetFirewallProfile | Select-Object Name, Enabled
```

## Check the host

Run the check script on the host, in admin PowerShell in the `scripts\windows` folder. It changes nothing and
prints PASS or FAIL for each item. Run it again **after every RustDesk update**, which may reinstall the firewall
rules.

```powershell
.\Test-Host.ps1
```

It can't see the password or two-factor settings; check those in RustDesk. The tests that prove the firewall
works must run from the controller: see the [controller guide](controller-windows.md#test-from-the-controller).

## When something goes wrong

| What you see | What it means | Fix |
|---|---|---|
| "running scripts is disabled on this system" | Windows' default script policy. | Run the two commands in the quick path, step 2.3, in the same window. |
| "cannot be loaded ... not digitally signed" | The files still carry the downloaded-from-the-internet mark. | Run the `Unblock-File` command in the quick path, step 2.3. |
| "The script ... cannot be run because it contains a #requires statement for running as Administrator" | PowerShell isn't running as administrator. | Close it and open it again with **Run as administrator**. |
| "winget is missing" | Older Windows without winget. | Install Tailscale from [tailscale.com/download](https://tailscale.com/download), then run the script again. |
| "Not a Tailscale address" | The address passed to `-ControllerIp` doesn't start with `100.`. | Copy the controller's address from the Tailscale admin console. |
| FAIL on a firewall rule after a RustDesk update | The update reinstalled the rules. | Run `.\Install-Host.ps1` again (or the manual firewall commands 3 and 4). |
| "Your ip is blocked by the peer" on the controller | The controller's address isn't on the whitelist, or Tailscale is off on the controller. | Check the controller's `100.x` address and run the second run again with it. |
| Lost the phone with the authenticator app | You can't pass two-factor. | Sit at the host, turn two-factor off and on in RustDesk's Security settings, and scan the new QR code. |

**Undo the firewall step** (admin PowerShell, in `scripts\windows`):

```powershell
.\Undo-HostFirewall.ps1
```
