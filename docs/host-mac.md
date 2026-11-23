# Set up a Mac host

[Back to the README](../README.md) · [Glossary](glossary.md)

> **Do this on the HOST**: the Mac that will be controlled (for example a MacBook you leave on the charger).
> The device you'll sit at is the controller; it has its own guide: [Windows](controller-windows.md),
> [Mac](controller-mac.md) or [iPhone](controller-iphone.md).

When you're done, this Mac can be reached by RustDesk from your controllers, only through Tailscale, only with a
password and a two-factor code, and from nowhere else.

**Example addresses in these guides:** the host is `100.64.0.10` (home address `192.168.0.10`) and the controller
is `100.64.0.11`. Yours will be different: always use the real ones from your Tailscale admin console.

## Contents

1. [Before you start](#before-you-start)
2. [The order across both devices](#the-order-across-both-devices)
3. [Manual path](#manual-path)
4. [Script path (partly tested on a real Mac)](#script-path-partly-tested-on-a-real-mac)
5. [Optional: limit RustDesk to Tailscale in the firewall](#optional-limit-rustdesk-to-tailscale-in-the-firewall)
6. [Optional: the macOS firewall (not yet tested)](#optional-the-macos-firewall-not-yet-tested)
7. [Check the host](#check-the-host)
8. [When something goes wrong](#when-something-goes-wrong)

## Before you start

- **An administrator account on this Mac.** Installing RustDesk's service and changing the firewall need your Mac
  password.
- **An account to sign in to Tailscale** (Google, Microsoft, Apple or GitHub). Turn on two-factor for that account
  first: whoever can sign in to it can add devices to your private network.
- **An authenticator app on your phone**, such as Microsoft Authenticator or Google Authenticator.
- **A password manager** (Bitwarden, 1Password, or Apple's Passwords app) to make and store a long random password.
- About 45 minutes.

## The order across both devices

The host's whitelist needs the controller's Tailscale address, and the controller only gets one after it joins
Tailscale. So:

1. **Host:** this guide, steps 1 and 2 of the manual path, and step 3 except the whitelist (or the script's first
   run).
2. **Controller:** its guide, step 1 ([Windows](controller-windows.md#1-join-tailscale), [Mac](controller-mac.md#1-join-tailscale)
   or [iPhone](controller-iphone.md#1-join-tailscale)). Note its `100.x` address.
3. **Host:** finish this guide with the controller's address in the whitelist.
4. **Controller:** connect, and run its tests.

## Manual path

### 1. Tailscale

1. Download the Mac app from [tailscale.com/download/mac](https://tailscale.com/download/mac). Pick the
   **Standalone** download, which Tailscale recommends, rather than the App Store version. Don't install both.
2. Open it. macOS asks to allow Tailscale's **network extension** (its VPN part): click **Allow** in the prompt, or in
   System Settings → General → Login Items & Extensions → Network Extensions.
3. Click the Tailscale icon in the menu bar and choose **Log in**. Use the **same account** on every device: two
   accounts make two separate networks that can't see each other.
4. **Turn off key expiry.** In the [admin console](https://login.tailscale.com/admin/machines), click the `...` menu
   next to this Mac and choose **Disable key expiry**. Otherwise Tailscale makes the Mac sign in again every 180
   days, and a host nobody sits at can't.
5. Note this Mac's address starting with `100.` from the admin console: the controller connects to it.

### 2. RustDesk

1. Download it **only** from [github.com/rustdesk/rustdesk/releases](https://github.com/rustdesk/rustdesk/releases).
   Pick the release with the pinned version: open [`tailnet-desk.sh`](../scripts/mac/tailnet-desk.sh) and read the line
   `TD_RUSTDESK_VERSION='...'` near the top. In that release's **Assets**, pick the file ending in `aarch64.dmg` for an
   Apple-chip Mac (Apple menu → About This Mac shows "Chip: Apple ...") or `x86_64.dmg` for an Intel Mac. Fake
   RustDesk sites hand out malware, so don't use a search ad.
2. Open the `.dmg` and drag **RustDesk** into **Applications**. Before opening it, check it's RustDesk's own: in
   Terminal, run the command below. It checks the signature is valid and that Apple issued it to RustDesk's developer
   team, `HZF9JMC8YN` (the same check and value as `TD_RUSTDESK_TEAM` in the script). It must print `OK`; an error or
   no output means it isn't RustDesk's own, so delete it. Then open it from Applications; if macOS asks, choose
   **Open**.

```bash
codesign --verify --strict -R='anchor apple generic and certificate leaf[subject.OU] = "HZF9JMC8YN"' /Applications/RustDesk.app && echo OK
```

3. RustDesk shows "For starting on boot, you need to install system service". Click **Install** and enter your Mac
   password. This is the part that runs in the background and starts at every boot, so you can reach the Mac when
   nobody has opened RustDesk, even at the login screen. macOS then says "Background Items Added". A **Start
   service** button alone isn't enough: it only runs RustDesk until the next restart. And on a Mac, RustDesk's **Stop service** does more than
   stop it: it removes the startup items too. After using it, click **Install** again, or the Mac can't be reached
   after its next restart.
4. Give RustDesk the two macOS permissions it needs. In System Settings → Privacy & Security:
   - **Screen & System Audio Recording**: turn on RustDesk. Without it, the controller sees a blank screen.
   - **Accessibility**: turn on RustDesk. Without it, the controller sees the screen but can't click or type.

   Quit RustDesk and open it again after each. macOS may ask again from time to time whether RustDesk may keep
   recording the screen; the answer has to be given at the Mac.
5. In System Settings → General → Login Items & Extensions, check that RustDesk is allowed **in the background**.

### 3. RustDesk security settings

In RustDesk, open **Settings**, go to **Security**, and click **Unlock security settings** (enter your Mac
password). Menu names may differ slightly between versions.

| Where | Setting | Set it to | Why |
|---|---|---|---|
| Security | Password | **Use permanent password**, then **Set permanent password** | Generate a random password of 20 or more characters in your password manager, save it there, and paste it in. Never reuse it, not even on another of your computers: one leak would then open both. It lets you connect when nobody is at the host. |
| Security | Two-factor authentication | **On** | A QR code appears. In your authenticator app, tap **+**, scan it, and name the entry after this Mac. A stolen password alone is then useless. Don't photograph or share the QR code: it's the secret that makes the codes. A controller that was trusted for two-factor skips the code from then on: remove it under **Manage trusted devices** in the same section. |
| Security | Enable trusted devices | Your choice | With it on, a controller can tick "trust this device" when it connects, and then skips the 6-digit code for the trust duration (90 days unless you change it). That's convenient on a controller that stays locked, but whoever unlocks it then needs only the password. With it off, every connection asks for the code. |
| Security | Accept sessions | **via password** | A session starts on the password and code alone. Nobody has to be at the host to click Accept. |
| Security | Deny LAN discovery | **On** (ticked) | The Mac stops announcing itself to other RustDesk apps on your home network. |
| Security | Enable direct IP access | **On**, port **21118** | The controller connects straight to the host's Tailscale address, not through RustDesk's public servers. |
| Security | Use IP whitelisting | **On**, add only the controller's `100.x` address | RustDesk refuses everything else with "Your ip is blocked by the peer". Never add this Mac's own address, and never a whole range like `100.64.0.0/10`: that lets in every device on your Tailscale network. |
| Network | ID server and Relay server | `127.0.0.1` in both | Stops the Mac registering with RustDesk's public servers, which would be a second way in outside Tailscale. RustDesk will then say it can't reach a server; that's expected. |

### 4. Stay awake

A sleeping Mac can't be reached. In System Settings:

- **A MacBook:** Battery → Options: turn on **Prevent automatic sleeping on the power adapter when the display is off**.
  It only works on the charger, and only with the lid open. A closed MacBook sleeps unless it has an external display
  (or an HDMI dummy plug, a small adapter that acts like one) on the charger, or an app that keeps it awake.
- **A Mac desktop:** Energy: turn on **Prevent automatic sleeping when the display is off**.

The screen turning off is fine.

Then [check the host](#check-the-host) and go to the controller to connect.

## Script path (partly tested on a real Mac)

> **Partly tested.** On a Mac that already had Tailscale and RustDesk, the scripts ran and passed. Installing
> Tailscale and RustDesk with the script hasn't run on a real Mac yet, so for a fresh install the manual path above
> is the tested route. See the [README's Status](../README.md#status) for exactly what has run.

The script does the manual path's steps except the ones that need you: allowing Tailscale's network extension and
signing in, turning off key expiry, allowing RustDesk's service and its two permissions, choosing the password and scanning the
two-factor QR code. It's safe to run more than once: each run skips what's already done and keeps the controllers
already on the whitelist.

### 1. Get the scripts

1. Open [the repo's main page](https://github.com/stunnas/tailnet-desk), click the green **Code** button, then
   **Download ZIP**. Safari unzips it into your Downloads folder.
2. Open **Terminal** (press Command and Space, type `Terminal`, press Return).
3. Type `cd ` (with a space), drag the `scripts/mac` folder from Finder into the Terminal window, and press
   **Return**.

Run the scripts as yourself, not with `sudo`: they ask for your Mac password when a step needs it. If macOS says a
script "can't be opened", run it as `bash ./install-host.sh` instead.

### 2. First run

```bash
./install-host.sh
```

What happens:

1. **Tailscale** (the pinned version), if it isn't installed yet, is downloaded from Tailscale's own package server
   into a new private folder. The script checks the installer's SHA-256 fingerprint against the one stored in the
   script, that Tailscale's Apple developer team signed it and that Apple notarized it, and refuses anything else.
   Then it installs it and opens Tailscale. An existing Tailscale, Standalone or App Store, is kept as it is. If
   Tailscale isn't signed in yet, the script stops: allow its network extension when macOS asks, then log in (manual
   step 1, items 2 and 3), and run it again.
2. **RustDesk** (the pinned version), if it isn't installed yet, is downloaded from its official GitHub page into a
   new private folder. The script checks the disk image's SHA-256 fingerprint against the one stored in the script
   and that RustDesk's Apple developer team signed it, and refuses anything else. An existing RustDesk is kept as it
   is.
3. **RustDesk's service and permissions:** the first time, the script stops and asks you to do manual step 2, items
   3 to 5 (open RustDesk from Applications first). Then run it again. RustDesk then stops using its public servers.
4. **RustDesk's settings:** the same as the manual table, except the password and two-factor. Direct IP access stays
   **off** for now, because there's no controller to whitelist yet.
5. **Sleep:** the Mac no longer sleeps on the charger (skip with `--keep-sleep`).
6. **A check** runs and prints PASS or FAIL lines, then the steps left for you.

At the end it prints **this Mac's Tailscale address**: the controller connects to it. Then do the manual path's
[key expiry step](#1-tailscale) (step 4) and the password and two-factor rows of [step 3](#3-rustdesk-security-settings).

### 3. Second run, with the controller's address

Once the controller has joined Tailscale, find the **controller's** `100.x` address in the
[Tailscale admin console](https://login.tailscale.com/admin/machines). Not this Mac's own address. Then run:

```bash
./install-host.sh --controller-ip 100.64.0.11
```

This turns on direct IP access with only that address on RustDesk's whitelist. For more than one controller,
separate the addresses with commas: `--controller-ip 100.64.0.11,100.64.0.12`.

On a Mac that already has Tailscale and RustDesk, the output looks like this (with your addresses). It asks for your Mac password
once:

```text
== Step 1 of 6: Tailscale
Tailscale is already installed.
Tailscale is signed in. This Mac's (the host's) Tailscale address: 100.64.0.10

== Step 2 of 6: RustDesk
RustDesk is already installed.

== Step 3 of 6: RustDesk's background service and permissions
RustDesk is running. Your Mac password may be asked: RustDesk only shows its settings to an administrator.
Password:
RustDesk no longer uses its public servers.
Check by hand that Screen & System Audio Recording and Accessibility both list RustDesk as allowed.

== Step 4 of 6: RustDesk security settings
Direct IP access: on. Whitelist (from --controller-ip): 100.64.0.11

== Step 5 of 6: Sleep
...

== Step 6 of 6: Check

Host checks
  PASS  Tailscale is signed in
  ...   (the same lines as in "Check the host" below)

All host checks passed. Now test from the controller: test-from-controller.sh on a Mac, test-from-controller.ps1 on a Windows PC.
```

After that it lists the password and two-factor steps for you to do in RustDesk, and this Mac's Tailscale address
again.

Later runs without `--controller-ip` keep the controller addresses already on the whitelist. They don't keep anything
that isn't a single Tailscale address, such as a range or this Mac's own address: the script names those entries.
If valid addresses are left, the whitelist is set to just those. If none are left, direct IP access is turned off
and the old entries stay in RustDesk's whitelist, so the check at the end fails them. Run the script again with
`--controller-ip` and the controller's address to replace them.

## Optional: limit RustDesk to Tailscale in the firewall

RustDesk's direct port listens on every network the Mac joins: home Wi-Fi, a café, a hotel. The whitelist refuses
everyone but your controllers, but they can still knock. This step makes the Mac's built-in packet filter (pf) drop
connections to that port unless they come from an address in Tailscale's ranges, so on an ordinary network RustDesk's
direct port can't be reached. It's a second lock next to the whitelist.

One limit: the rule goes by address, not by network, because macOS can't name Tailscale's network in a lasting way.
A few networks, those using carrier-grade NAT (some mobile hotspots and providers), hand out addresses from the same
range as Tailscale (`100.64.0.0/10`). On such a network, devices on it could still reach RustDesk's port, and only the
whitelist, password and two-factor stop them.

The script keeps the rule after a restart and can undo it. It never edits Apple's `/etc/pf.conf`, and it never turns
pf off for anything else that uses it.

**The trade-off: while pf is on, macOS turns off iCloud Private Relay.** System Settings then shows "Private Relay:
Unavailable" and "Some of your system settings prevent Private Relay from working". Private Relay is part of iCloud+;
macOS describes it as hiding your IP address and browsing activity in Safari and protecting your unencrypted internet
traffic. So it matters most if you browse in Safari. Pages other browsers load over HTTPS (most pages, in Chrome,
Brave, Firefox or Tor Browser) don't go through it. pf itself only drops incoming connections to RustDesk's port, so
browsing works the same. After the undo, Private Relay comes back on if nothing else on the Mac uses pf. If you browse
in Safari and rely on Private Relay, skip this step: the whitelist, password and two-factor still protect RustDesk.

```bash
./enable-pf.sh
```

To undo it:

```bash
./undo-pf.sh
```

Then run the controller's test with the host's home address: that test must now show the port closed.

**By hand, until the next restart** (the same rule without the startup item; not yet tested by hand). Each command
is one line:

```bash
sudo pfctl -E
```

That prints a line `Token : 12345`. Keep the number for the undo. Then:

```bash
printf 'pass in quick inet proto tcp from 100.64.0.0/10 to 100.64.0.0/10 port 21118\npass in quick inet6 proto tcp from fd7a:115c:a1e0::/48 to fd7a:115c:a1e0::/48 port 21118\nblock drop in quick proto tcp from any to any port 21118\n' | sudo pfctl -a com.apple/tailnet-desk -f -
```

A "No ALTQ support in kernel" message is harmless. To undo it: `sudo pfctl -a com.apple/tailnet-desk -F all`, then
`sudo pfctl -X 12345` with your token number. Never use `sudo pfctl -d`: that turns pf off for everything that uses
it.

## Optional: the macOS firewall (not yet tested)

> Not yet tested with this setup. If you turn it on, check the controller can still connect, and that `ping` over
> Tailscale still answers (the controller guides use it to check the two can see each other).

macOS also has an app firewall, which is off by default. It decides which apps may accept connections at all,
whatever the port. It's separate from the pf step above; both can be on.

1. System Settings → Network → **Firewall**: turn it on.
2. Click **Options**: turn on **Enable stealth mode** (the Mac stops answering probes such as ping). Make sure RustDesk is listed as **Allow incoming connections**. Don't turn on "Block all incoming
   connections": that blocks RustDesk too.
3. Connect from the controller again to check RustDesk still works.

## Check the host

Run the check script on the host, in Terminal in the `scripts/mac` folder (get it as in
[the script path, step 1](#1-get-the-scripts)). It changes nothing and prints PASS or FAIL for each item. It asks for
your Mac password, because RustDesk only shows its settings to an administrator.

```bash
./test-host.sh
```

On a working host, every line says PASS (your controller's address in place of the example):

```text
Host checks
  PASS  Tailscale is signed in
  PASS  RustDesk is installed
  PASS  RustDesk is signed by its Apple team (HZF9JMC8YN)
  PASS  RustDesk starts at boot (its system service is installed)
  PASS  RustDesk's background service is running
  PASS  Whitelist is not empty while direct IP access is on
  PASS  Whitelist entry '100.64.0.11' is one Tailscale address
  PASS  RustDesk setting custom-rendezvous-server
  PASS  RustDesk setting relay-server
  PASS  RustDesk setting verification-method
  PASS  RustDesk setting approve-mode
  PASS  RustDesk setting enable-lan-discovery
  PASS  RustDesk setting whitelist
  PASS  RustDesk setting direct-server
  PASS  RustDesk listens on TCP 21118
  NOTE  The optional firewall step (enable-pf.sh) isn't in use; the whitelist alone limits who can connect.

All host checks passed. Now test from the controller: test-from-controller.sh on a Mac, test-from-controller.ps1 on a Windows PC.
```

With the [firewall step](#optional-limit-rustdesk-to-tailscale-in-the-firewall) on, the NOTE line is a PASS line for
the firewall instead.

**Run it again after every RustDesk update**, and check that RustDesk is still allowed in both privacy settings.

It can't see the password, two-factor or macOS permission settings; check those in RustDesk and System Settings. The
tests that prove the setup works must run from the controller.

## When something goes wrong

### Messages while running the scripts

| What you see | What it means | Fix |
|---|---|---|
| "can't be opened" or "Permission denied" | The script lost its run permission when it was downloaded. | Run it as `bash ./install-host.sh` (or `bash ./test-host.sh`, and so on). |
| "Run this as yourself, not with sudo" | The script was started with `sudo`. | Run it without `sudo`; it asks for your password when needed. |
| "Tailscale is installed but not signed in (or not running) yet" | Tailscale gave this Mac no address: its network extension isn't allowed yet, or nobody has logged in. | Allow the extension and log in ([manual step 1](#1-tailscale), items 2 and 3). Then run the script again. |
| "Not a Tailscale address" | An address given to `--controller-ip` isn't a Tailscale address (`100.64.x.x` to `100.127.x.x`). | Copy the controller's address from the Tailscale admin console. |
| "... is this Mac's own address" | You gave the host's address instead of the controller's. | Use the controller's `100.x` address. |
| "Couldn't download ..." | The script couldn't reach Tailscale's package server or GitHub. Nothing was installed. | Check the internet connection and try again later. |
| "The download's SHA-256 doesn't match the pinned one", "The installer isn't signed by Tailscale's Apple team and notarized by Apple", "The disk image isn't signed by RustDesk's Apple team" or "The app in the disk image isn't signed ..." | The downloaded file isn't the one this repo was tested with. Nothing was installed. | Don't install it by hand from that download. Try again later, and if it keeps happening, [open an issue](https://github.com/stunnas/tailnet-desk/issues). |
| "macOS's installer couldn't install Tailscale" | The installer stopped, for example because the Mac password was wrong or macOS is older than Tailscale needs (macOS 11). | Run the script again. If it keeps happening, install Tailscale by hand ([manual step 1](#1-tailscale)). |
| "Tailscale in Applications isn't signed by Tailscale's Apple team after installing" | The installed app doesn't pass the signature check. | Delete Tailscale from Applications and run the script again. |
| "Couldn't open the disk image" | macOS couldn't mount the downloaded file. Nothing was installed. | Run the script again. If it keeps happening, install RustDesk by hand ([manual step 2](#2-rustdesk)). |
| "RustDesk in Applications isn't signed by RustDesk's Apple team" (with "after copying", "Delete it", or "so it isn't run") | The RustDesk in Applications doesn't pass the signature check, so the script doesn't run it. | Delete RustDesk from Applications and run `install-host.sh` again: it installs RustDesk's own. |
| "Couldn't copy RustDesk to Applications" | The copy failed, for example because the Mac password was wrong. Nothing was left behind. | Run the script again. |
| "Couldn't install the firewall step's files" | `enable-pf.sh` couldn't put its files in place, for example because the Mac password was wrong. | Run `./enable-pf.sh` again. |
| "--controller-ip needs an address" or "Unknown option" | The script was run with a mistyped option. | Run it with `--help` to see its options. |
| "Unsupported Mac type" | The Mac is neither an Apple-chip nor an Intel Mac. | Use the manual path. |
| "RustDesk's system service isn't installed or running yet" | RustDesk hasn't been opened, or its system service wasn't installed. | Do [manual step 2](#2-rustdesk), items 2 to 5, then run the script again. |
| "RustDesk refused to read the setting ..." or "RustDesk couldn't read the setting ..." | RustDesk's command line didn't answer. | Quit and reopen RustDesk, check it's allowed in the background, then run the script again. |
| "RustDesk didn't take the setting ..." | RustDesk refused a setting, usually because it isn't running. | Open RustDesk, then run the script again. |
| "The pf rules didn't load" | The firewall step's startup item didn't load its rules. Its errors are in the log file the message names. | Run `./undo-pf.sh`, then `./enable-pf.sh` again. If it still fails, [open an issue](https://github.com/stunnas/tailnet-desk/issues) with what the log says. |
| "The firewall step isn't installed, so there is nothing to undo" | `undo-pf.sh` found nothing of the pf step. | Nothing to do. |
| "Something of the firewall step is still there" | `undo-pf.sh` couldn't remove all of it. | Restart the Mac and run `./undo-pf.sh` again. |
| "pf itself stays on until you restart the Mac", or Private Relay stays "Unavailable" after the undo | pf is still on: this step's reference couldn't be released (the undo says why), or something else on the Mac uses pf. | Restart the Mac. If Private Relay is still unavailable, something else on the Mac uses pf. |

### FAIL lines from test-host.sh

| FAIL line | Fix |
|---|---|
| Tailscale is signed in | Click the Tailscale icon in the menu bar and choose **Log in**. |
| RustDesk is installed | Install it ([manual step 2](#2-rustdesk)) into Applications. |
| RustDesk is signed by its Apple team | The app in Applications isn't RustDesk's own. Delete it and install it again from [manual step 2](#2-rustdesk). |
| RustDesk starts at boot (its system service is installed) | Open RustDesk and click **Install** under "For starting on boot". "Start service" alone only lasts until the next restart, so an unattended Mac becomes unreachable after a power cut or update. |
| RustDesk's settings could be read | RustDesk's command line didn't answer. Quit and reopen RustDesk, check it's allowed in the background, and run the check again. |
| No checks ran | Nothing was checked, so nothing passed. Run the script again and see what it printed before this line. |
| RustDesk's background service is running | Open RustDesk and allow its service; check it's allowed in the background. |
| Given controller address ... / Whitelist entry ... is one Tailscale address | Replace it with the controller's single `100.x` address, no ranges: run `./install-host.sh --controller-ip` with it, or edit the whitelist in RustDesk. This fails even while direct IP access is off, so turning it on later can't bring the entry back. |
| Whitelist doesn't include this Mac's own address | Remove the host's own `100.x` address from the whitelist: only controllers belong there. |
| Whitelist is not empty while direct IP access is on | Add the controller's address to the whitelist, or turn off direct IP access. |
| RustDesk setting ... | That setting differs from [step 3's table](#3-rustdesk-security-settings). Fix it in RustDesk, or run `./install-host.sh` again. |
| RustDesk listens on TCP 21118 | Direct IP access is on but nothing listens: quit and reopen RustDesk. |
| The firewall step's rules are loaded and pf is on | Run `./enable-pf.sh` again. If you don't want the step any more, run `./undo-pf.sh`. |

### Other problems

| What you see | What it means | Fix |
|---|---|---|
| "Not ready. Please check your connection" at the bottom of RustDesk | RustDesk can't reach its ID server, because the ID and relay servers are set to `127.0.0.1` on purpose. | Nothing: connections by Tailscale address don't need it. |
| The controller sees a black or blank screen | RustDesk isn't allowed to record the screen. | Allow it under Screen & System Audio Recording, then quit and reopen RustDesk. |
| The controller sees the screen but can't click or type | RustDesk isn't allowed to control the Mac. | Allow it under Accessibility, then quit and reopen RustDesk. If it's already on, remove RustDesk with **-** and add it again with **+**. |
| "Your ip is blocked by the peer" on the controller | The controller's address isn't on the whitelist, or Tailscale is off on the controller. | Check the controller's `100.x` address and add it (manual step 3, or the script's second run). |
| The Mac can't be reached after a restart | RustDesk's startup items are missing: "Stop service" removes them, and "Start service" doesn't put them back. | At the Mac, open RustDesk and click **Install** under "For starting on boot". `test-host.sh` checks this. |
| The Mac can't be reached after a while | It went to sleep. | See [step 4](#4-stay-awake). A closed MacBook sleeps unless something keeps it awake. |
| Lost the phone with the authenticator app | You can't pass two-factor. | Sit at the host, turn two-factor off and on in RustDesk's Security settings, and scan the new QR code. |
| Lost a controller (laptop or phone) | If it saved the password or was trusted for two-factor, anyone who unlocks it can connect. | At the host, remove it under **Manage trusted devices** (Security settings), change the permanent password, and remove its `100.x` address from the whitelist. Also remove it from the [Tailscale admin console](https://login.tailscale.com/admin/machines). |
