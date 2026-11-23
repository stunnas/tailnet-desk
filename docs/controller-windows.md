# Set up a Windows controller

[Back to the README](../README.md) · [Glossary](glossary.md)

> **Do this on the CONTROLLER**: the Windows PC you'll sit at (for example your laptop). The computer you'll
> control is the host; set it up with its own guide: [Windows](host-windows.md) or [Mac](host-mac.md).

A controller only views the host and sends your mouse and keyboard, so it needs far less than the host: two
installs, two settings, and the tests that prove the host is locked down.

**Example addresses in these guides:** the host is `100.64.0.10` (home address `192.168.0.10`) and this controller
is `100.64.0.11`. Use your real ones from the Tailscale admin console.

## 1. Join Tailscale

1. Download Tailscale from [tailscale.com/download](https://tailscale.com/download) and install it.
2. Click the Tailscale icon by the clock (click `^` if you don't see it), choose **Log in**, and sign in with
   the **same account as the host**. Two accounts make two separate networks that can't see each other.
3. Open the [Tailscale admin console](https://login.tailscale.com/admin/machines). Find **this PC** and note its
   address starting with `100.` (the short one; Tailscale also shows a long one starting `fd7a:`, see the [glossary](glossary.md)). The host needs it for its whitelist.
4. Check the two can see each other. Open PowerShell (press the Windows key, type `powershell`, press Enter) and
   run this with the **host's** address in place of the example:

```powershell
ping 100.64.0.10
```

Lines saying `Reply from ...` mean it works. "Request timed out" means they can't see each other: check both
show as connected in the admin console.

Now go back to the host and add this PC's address to its whitelist
([host guide, step 4](host-windows.md#4-rustdesk-security-settings)).

## 2. Install RustDesk

1. Download it **only** from [github.com/rustdesk/rustdesk/releases](https://github.com/rustdesk/rustdesk/releases).
   Pick the release with the pinned version: open [`tailnet-desk.psm1`](../scripts/windows/tailnet-desk.psm1) and read the line
   `RustDeskVersion = '...'` near the top. Then open that
   release's **Assets** and pick the file ending in `x86_64.exe`.
2. Check it's RustDesk's own, as on the host ([host guide, step 2](host-windows.md#2-rustdesk)): right-click the
   file → **Properties** → **Digital Signatures** must show **PURSLANE**, and **Details** must say "This digital
   signature is OK".
3. Run it and choose **Install**.
4. Two settings keep the controller from becoming a way in itself. In RustDesk, open **Settings**:
   - **Security:** leave **Enable direct IP access** off (the default). Then nothing on this PC accepts direct
     RustDesk connections, and it needs no firewall step.
   - **Network:** set **ID server** and **Relay server** to `127.0.0.1`. Out of the box, anyone with this PC's
     RustDesk ID and the one-time password shown in its window could connect through RustDesk's public servers.
     This closes that path. You lose nothing, because you connect by address.

## 3. Connect

1. Make sure Tailscale shows **Connected** on both PCs.
2. In RustDesk's **Control Remote Desktop** box, type the **host's** `100.x` address and click **Connect**.
3. Enter the host's permanent password, then the 6-digit code from your authenticator app. **Leave "Remember
   password" unticked**: otherwise anyone who gets hold of this PC unlocked can open the host without knowing it.
   Ticking "trust this device" (if the host allows it) skips the code here for a while; only do that on a PC that
   stays locked, because whoever unlocks it then needs only the password.
4. The host's screen appears. With two monitors, the monitor buttons in the toolbar switch between them. If the
   picture lags, open the display menu in the toolbar and set the frame rate to **30**.

Keep this PC locked when you're away from it (Windows key + L).

## Test from the controller

These prove each lock on the host works. **Run them here, on the controller, never on the host:** Windows Firewall
doesn't filter a PC's connections to its own addresses, so a test run on the host always passes and proves
nothing. For the home network test, this PC must be on the same home network as the host.

You need two of the **host's** addresses:

- Its **Tailscale address** (`100.x`), from the admin console.
- Its **home address**: on a Windows host, run `ipconfig` and read **IPv4 Address** under Wi-Fi or Ethernet; on a Mac
  host, System Settings → Wi-Fi → **Details** next to the network, **IP address** (often `192.168.x.x`).

### By hand

`Test-NetConnection` tries one port on one address and reports whether it got through (`TcpTestSucceeded`). Use
the host's real addresses in place of the examples.

1. **The Tailscale path is open.** Expect `TcpTestSucceeded : True`.

```powershell
Test-NetConnection 100.64.0.10 -Port 21118
```

2. **The home network path is closed.** Expect `TcpTestSucceeded : False`, plus a warning that the connection
   failed. That's the host's firewall doing its job. `True` means the host's firewall step didn't take effect. A Mac
   host without its optional [firewall step](host-mac.md#optional-limit-rustdesk-to-tailscale-in-the-firewall)
   answers here, as expected: its whitelist refuses the connection instead.

```powershell
Test-NetConnection 192.168.0.10 -Port 21118
```

### With the script (not yet tested on a real PC)

The same two tests in one go. Unlike the host scripts, it hasn't been run on a real PC yet (see the
[README's Status](../README.md#status)), so do the tests by hand as well until it has.

1. Get the scripts as on the host ([host guide, script path, step 1](host-windows.md#1-get-the-scripts)).
2. Open a **normal** PowerShell (not as administrator): press the Windows key, type `powershell`, press Enter.
3. Type `cd ` (with a space), drag the `windows` folder from File Explorer into the window, and press **Enter**.
4. Allow scripts for this window (type `Y` and press **Enter** when it asks "Do you want to change the execution
   policy?"), then run the test with your two host addresses in place of the examples:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

```powershell
.\test-from-controller.ps1 -HostTailscaleIp 100.64.0.10 -HostHomeIp 192.168.0.10
```

When everything works, it prints:

```text
Controller checks
  PASS  Tailscale is signed by its publisher (Tailscale Inc.)
  PASS  This PC is signed in to Tailscale
  PASS  Host's Tailscale address answers on 21118
  PASS  Host's home address does NOT answer on 21118

Still test by hand: connecting from a device NOT on the whitelist must show "Your ip is blocked by the peer".
```

For the home address test, this PC must be on the same home network as the host. Away from home, leave out
`-HostHomeIp`: the script skips that test and says so.

### The tests no script can do

- **The whitelist refuses other devices.** From a Tailscale device that is **not** on the host's whitelist (for
  example your phone with Tailscale and RustDesk), connect to the host's `100.x` address. Expect "Your ip is
  blocked by the peer". If it asks for a password instead, the whitelist isn't on.
- **Two-factor is required.** Connecting asked for a 6-digit code after the password.

## When something goes wrong

| What you see | What it means | Fix |
|---|---|---|
| "Your ip is blocked by the peer" | The host's whitelist doesn't have this PC's address. | Check this PC's `100.x` address in the admin console, and that Tailscale is on here. Then add it on the host. |
| "Failed to connect" or a timeout | This PC can't reach the host. | Check Tailscale is connected on both and the host is awake. Try `ping`. If ping works, check the host ([Windows](host-windows.md#check-the-host), [Mac](host-mac.md#check-the-host)). |
| "The '<' operator is reserved" | Angle brackets were left in a command. | Type the real address without `<` and `>`. |
| "That's this PC's own address" | You gave the controller's address instead of the host's. | Use the host's `100.x` address. |
| `TcpTestSucceeded : True` on the home address | A Windows host's firewall step isn't working, or a Mac host doesn't use its optional firewall step. | On a Mac host without the [firewall step](host-mac.md#optional-limit-rustdesk-to-tailscale-in-the-firewall), this is expected. Otherwise check the host ([Windows](host-windows.md#check-the-host), [Mac](host-mac.md#check-the-host)) and fix what it marks FAIL. |
| Lag or a choppy picture | The frame rate is too high. | Set it to 30 in the session's display menu. |

### Messages and FAIL lines from test-from-controller.ps1

| What you see | What it means | Fix |
|---|---|---|
| "Not a Tailscale address" | `-HostTailscaleIp` isn't a Tailscale address (`100.64.x.x` to `100.127.x.x`). | Copy the host's address from the Tailscale admin console. |
| "Not a home network address" | `-HostHomeIp` isn't one private IPv4 address (`192.168.x.x`, `10.x.x.x` or `172.16.x.x` to `172.31.x.x`). A Tailscale, loopback or public address wouldn't test the home network. | Use the **IPv4 Address** that `ipconfig` shows on the host, such as `192.168.0.10`. |
| FAIL: Tailscale is signed by its publisher (Tailscale Inc.) | This PC's `tailscale.exe` doesn't carry Tailscale's valid signature, so the script doesn't run it, and "This PC is signed in to Tailscale" fails too. | Uninstall Tailscale (Settings, Apps) and install it again from [tailscale.com/download](https://tailscale.com/download). |
| FAIL: This PC is signed in to Tailscale | Tailscale isn't signed in here (or its signature check above failed). | Click the Tailscale icon by the clock and choose **Log in**. |
| FAIL: Host's Tailscale address answers on 21118 | The host can't be reached over Tailscale on RustDesk's port. | Check Tailscale is connected on both, the host is awake, and direct IP access is on there. Then check the host ([Windows](host-windows.md#check-the-host), [Mac](host-mac.md#check-the-host)). |
| FAIL: Host's home address does NOT answer on 21118 | The host answers on the home network, so its firewall step isn't working (or a Mac host doesn't use it). | On a Mac host without the optional firewall step, this is expected: run the test without `-HostHomeIp`, or turn the step on. Otherwise check the host ([Windows](host-windows.md#check-the-host), [Mac](host-mac.md#check-the-host)) and fix what it marks FAIL. |
