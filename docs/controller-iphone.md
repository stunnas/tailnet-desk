# Set up an iPhone controller

[Back to the README](../README.md) · [Glossary](glossary.md)

> **Do this on the CONTROLLER**: your iPhone. The computer you'll control is the host; set it up with its own guide:
> [Windows](host-windows.md) or [Mac](host-mac.md). The same steps work with either, and with both.

The iPhone only views the host's screen and sends your taps and typing. RustDesk on an iPhone can't be controlled
itself, so the phone needs no lock-down: two apps, and the tests that prove the host is locked down.

**Example addresses in these guides:** the host is `100.64.0.10` and this iPhone is `100.64.0.12`. Use your real
ones from the Tailscale app or admin console.

**Partly followed on an iPhone:** see the [README's Status](../README.md#status) for what has been checked. The app's
button and menu names, the developer name and the data use come from RustDesk's App Store page and documentation and
may differ in your version.

## 1. Join Tailscale

1. Install **Tailscale** from the App Store (by Tailscale Inc.).
2. Open it, sign in with the **same account as the host**, and allow it to add a VPN configuration when iOS asks.
   Two accounts make two separate networks that can't see each other.
3. In the Tailscale app, tap this iPhone in the list (or open the
   [admin console](https://login.tailscale.com/admin/machines)) and note its address starting with `100.` (the short one; Tailscale also shows a long one starting `fd7a:`, see the [glossary](glossary.md)). The host
   needs it for its whitelist.

Now go back to the host and add this iPhone's address to its whitelist (host guide:
[Windows](host-windows.md#4-rustdesk-security-settings) or [Mac](host-mac.md#3-rustdesk-security-settings)). To
reach both a Windows and a Mac host, add it to each host's whitelist.

## 2. Install RustDesk

Install **RustDesk Remote Desktop** from the App Store. Check the developer: **Purslane Limited**. Look-alike apps
exist, so don't install one from a search ad.

There's nothing to lock down: the iPhone app can only control other computers, never be controlled.

## 3. Connect

1. Make sure Tailscale shows **Connected** on the iPhone and on the host.
2. In RustDesk, type the **host's** `100.x` address into the **Remote ID** box (just the address, no port) and tap
   the arrow.
3. Enter the host's permanent password, then the 6-digit code from your authenticator app. **Leave "Remember
   password" off**: otherwise anyone who gets hold of your unlocked iPhone can open the host without knowing it.
   Trusting this device (if the host allows it) skips the code here for a while; only do that if your iPhone has a
   passcode and locks itself, because whoever unlocks it then needs only the password.
4. The host's screen appears. Drag to move the pointer and tap to click; the keyboard icon opens the keyboard.

Useful settings in a session:

| Setting | Where | Why |
|---|---|---|
| Image quality: **Optimize reaction time**, frame rate **30** | The display menu in the session's toolbar | Less lag over mobile data. Left alone, the phone can push the frame rate up and the delay climbs. |
| Choosing a monitor | The screen icon in the toolbar, then a numbered display | A host with two monitors shows one at a time. |

A session over mobile data uses a lot of data: a few hundred megabytes in a short session is normal. Keep the iPhone
locked when you're not using it.

## Test from the iPhone

These prove the host's locks work. A computer can test the home network path better ([Windows](controller-windows.md#test-from-the-controller)
or [Mac](controller-mac.md#test-from-the-controller) controller guides), but the iPhone can check the rest.

- **The Tailscale path works.** Connecting in step 3 showed the host's screen.
- **Two-factor is required.** Connecting asked for a 6-digit code after the password.
- **The whitelist refuses other devices.** Turn **Tailscale off** on the iPhone, stay on the same Wi-Fi as the host,
  and connect to the host's **home address** (such as `192.168.0.10`). Expect "Your ip is blocked by the peer", or "Failed to
  connect" with a firewall step on the host. If it asks for a password instead, the whitelist isn't on. Turn
  Tailscale back on afterwards.

## When something goes wrong

| What you see | What it means | Fix |
|---|---|---|
| "Your ip is blocked by the peer" | The host's whitelist doesn't have this iPhone's address, or Tailscale is off on the iPhone. | Check the iPhone's `100.x` address in the Tailscale app and that it shows Connected. Then add it on the host. |
| "Failed to connect" or a timeout | The iPhone can't reach the host. | Check Tailscale is connected on both and the host is awake. Check the host ([Windows](host-windows.md#check-the-host), [Mac](host-mac.md#check-the-host)). |
| It tries to connect by RustDesk ID | A name was typed instead of the `100.x` address. | Type the host's `100.x` address, or a name followed by `:21118`. |
| The host's screen is black, or taps do nothing | The host (a Mac) hasn't allowed RustDesk to record the screen or control it. | On the host, see [its other problems](host-mac.md#other-problems). |
| The session drops when you switch apps | iOS pauses apps in the background. | Reconnect when you come back to RustDesk. |
| Lag or a choppy picture | The frame rate is too high, or the mobile signal is weak. | Set it to 30 and "Optimize reaction time" in the session's display menu. |
