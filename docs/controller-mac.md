# Set up a Mac controller

[Back to the README](../README.md) · [Glossary](glossary.md)

> **Do this on the CONTROLLER**: the Mac you'll sit at (for example your MacBook). The computer you'll control is
> the host; set it up with its own guide: [Windows](host-windows.md) or [Mac](host-mac.md).

A controller only views the host and sends your mouse and keyboard, so it needs far less than the host: two installs,
two settings, and the tests that prove the host is locked down.

**Example addresses in these guides:** the host is `100.64.0.10` (home address `192.168.0.10`) and this controller
is `100.64.0.11`. Use your real ones from the Tailscale admin console.

## 1. Join Tailscale

1. Download the **Standalone** Mac app from [tailscale.com/download/mac](https://tailscale.com/download/mac) and open
   it. Allow its network extension when macOS asks.
2. Click the Tailscale icon in the menu bar, choose **Log in**, and sign in with the **same account as the host**.
   Two accounts make two separate networks that can't see each other.
3. Open the [Tailscale admin console](https://login.tailscale.com/admin/machines). Find **this Mac** and note its
   address starting with `100.`. The host needs it for its whitelist.
4. Check the two can see each other. Open Terminal (Command and Space, type `Terminal`, press Return) and run this
   with the **host's** address in place of the example:

```bash
ping -c 3 100.64.0.10
```

Lines with `time=` mean it works. "Request timeout" means they can't see each other: check both show as connected in
the admin console.

Now go back to the host and add this Mac's address to its whitelist (host guide, security settings:
[Windows](host-windows.md#4-rustdesk-security-settings) or [Mac](host-mac.md#3-rustdesk-security-settings)).

If `ping` gets no reply although both show as connected, the host may have a firewall that drops ping (the macOS
firewall's stealth mode may do this). Go on to step 3: connecting is the real test.

## 2. Install RustDesk

1. Download it **only** from [github.com/rustdesk/rustdesk/releases](https://github.com/rustdesk/rustdesk/releases).
   Pick the release with the pinned version: open [`tailnet-desk.sh`](../scripts/mac/tailnet-desk.sh) and read the line
   `TD_RUSTDESK_VERSION='...'`. In its **Assets**, pick `aarch64.dmg` for an Apple-chip Mac or `x86_64.dmg` for an
   Intel Mac.
2. Open the `.dmg`, drag **RustDesk** into **Applications**, and open it from there.
3. Two settings keep the controller from becoming a way in itself. In RustDesk, open **Settings**:
   - **Security:** leave **Enable direct IP access** off (the default). Then nothing on this Mac accepts direct
     RustDesk connections.
   - **Network:** set **ID server** and **Relay server** to `127.0.0.1`. Out of the box, anyone with this Mac's
     RustDesk ID and the one-time password shown in its window could connect through RustDesk's public servers.
     This closes that path. You lose nothing, because you connect by address.

A controller doesn't need RustDesk's service or its Screen Recording and Accessibility permissions: those are for
being controlled. If keyboard shortcuts don't reach the host, allow RustDesk under System Settings → Privacy &
Security → **Input Monitoring**.

## 3. Connect

1. Make sure Tailscale shows **Connected** on both computers.
2. In RustDesk's **Control Remote Desktop** box, type the **host's** `100.x` address and click **Connect**.
3. Enter the host's permanent password, then the 6-digit code from your authenticator app. **Leave "Remember
   password" unticked**, and don't tick any option to trust this device for two-factor: otherwise anyone who gets
   hold of this Mac unlocked can open the host without knowing either.
4. The host's screen appears. With two monitors, the monitor buttons in the toolbar switch between them. If the
   picture lags, open the display menu in the toolbar and set the frame rate to **30**.

Keep this Mac locked when you're away from it (Control, Command and Q).

## Test from the controller

These prove each lock on the host works. **Run them here, on the controller, never on the host:** a firewall doesn't
filter a computer's connections to its own addresses, so a test run on the host always passes and proves nothing.
For the home network test, this Mac must be on the same home network as the host.

You need two of the **host's** addresses:

- Its **Tailscale address** (`100.x`), from the admin console.
- Its **home address**: on a Windows host, run `ipconfig` and read **IPv4 Address**; on a Mac host, System Settings
  → Wi-Fi → **Details** next to the network, **IP address** (often `192.168.x.x`).

### By hand

`nc -z` tries one port on one address and says whether it got through. Use the host's real addresses in place of
the examples.

1. **The Tailscale path is open.** Expect a line ending in `succeeded!`.

```bash
nc -z -G 3 100.64.0.10 21118
```

2. **The home network path is closed** (for a Windows host, or a Mac host with the
   [firewall step](host-mac.md#optional-limit-rustdesk-to-tailscale-in-the-firewall)). Expect no output after
   about 3 seconds. A `succeeded!` line means the host's firewall step isn't in effect. On a Mac host without the
   firewall step, the port answers here and only the whitelist refuses the connection.

```bash
nc -z -G 3 192.168.0.10 21118
```

### With the script (not yet tested on a real Mac)

The same two tests in one go. It hasn't been run end to end on a real Mac yet, so do the tests by hand as well until
it has.

1. Get the scripts as on a Mac host ([host guide, script path, step 1](host-mac.md#1-get-the-scripts)).
2. In Terminal, in the `scripts/mac` folder, run it with your two host addresses in place of the examples:

```bash
./test-from-controller.sh --host-tailscale-ip 100.64.0.10 --host-home-ip 192.168.0.10
```

### The tests no script can do

- **The whitelist refuses other devices.** From a Tailscale device that is **not** on the host's whitelist, connect
  to the host's `100.x` address. Expect "Your ip is blocked by the peer". If it asks for a password instead, the
  whitelist isn't on.
- **Two-factor is required.** Connecting asked for a 6-digit code after the password.

## When something goes wrong

| What you see | What it means | Fix |
|---|---|---|
| "Your ip is blocked by the peer" | The host's whitelist doesn't have this Mac's address. | Check this Mac's `100.x` address in the admin console, and that Tailscale is on here. Then add it on the host. |
| "Failed to connect" or a timeout | This Mac can't reach the host. | Check Tailscale is connected on both and the host is awake. Try `ping`. If ping works, check the host ([Windows](host-windows.md#check-the-host), [Mac](host-mac.md#check-the-host)). |
| The host's screen is black, or clicks do nothing | The host (a Mac) hasn't allowed RustDesk to record the screen or control it. | On the host, see [its other problems](host-mac.md#other-problems). |
| `succeeded!` on the home address | A Windows host's firewall step isn't working, or a Mac host doesn't use its optional firewall step. | On a Mac host without the [firewall step](host-mac.md#optional-limit-rustdesk-to-tailscale-in-the-firewall), this is expected: the whitelist refuses the connection instead. Otherwise check the host and fix what it marks FAIL. |
| Lag or a choppy picture | The frame rate is too high. | Set it to 30 in the session's display menu. |

### Messages and FAIL lines from test-from-controller.sh

| What you see | What it means | Fix |
|---|---|---|
| "Not a Tailscale address" | `--host-tailscale-ip` isn't a Tailscale address (`100.64.x.x` to `100.127.x.x`). | Copy the host's address from the Tailscale admin console. |
| "Not a home network address" | `--host-home-ip` isn't one private IPv4 address (`192.168.x.x`, `10.x.x.x` or `172.16.x.x` to `172.31.x.x`). | Use the host's home address, as above. |
| "That's this Mac's own address" | You gave the controller's address instead of the host's. | Use the host's `100.x` address. |
| FAIL: This Mac is signed in to Tailscale | Tailscale isn't signed in here. | Click the Tailscale icon in the menu bar and choose **Log in**. |
| FAIL: Host's Tailscale address answers on 21118 | The host can't be reached over Tailscale on RustDesk's port. | Check Tailscale is connected on both, the host is awake, and direct IP access is on there. Then check the host. |
| FAIL: Host's home address does NOT answer on 21118 | The host answers on the home network, so its firewall step isn't working (or isn't used). | On a Mac host without the optional firewall step, this is expected: run the test without `--host-home-ip`, or turn the step on. Otherwise check the host and fix what it marks FAIL. |
