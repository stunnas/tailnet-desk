# Words you'll see

[Back to the README](../README.md)

| Word | What it means here |
|---|---|
| **Host** | The computer being controlled. It shares its screen, so it's the one that gets locked down. |
| **Controller** | The device you sit at. It only views the host's screen and sends your mouse and keyboard. |
| **IP address** | A device's address on a network, like a street address for data. Example: `192.168.0.10`. |
| **Home IP / LAN address** | The address your router gives a computer on your home network, usually starting with `192.168.` or `10.`. Only devices on the same Wi-Fi or cable can use it. |
| **Tailscale address** | The address Tailscale gives each device, always starting with `100.` (written `100.x` in the guides). It stays the same wherever the device goes, and only your own Tailscale devices can reach it. |
| **Tailscale network (tailnet)** | All the devices signed in to your Tailscale account. They can reach each other; nobody else can. |
| **Port** | A numbered door on a computer. Each program listens at its own door. RustDesk's direct connections use port **21118**. |
| **Listening** | A program waiting at its port for someone to connect. A port nothing listens on can't be connected to. |
| **Firewall** | The gatekeeper built into Windows and macOS. Its rules decide which programs may accept connections, and on which networks. |
| **Network adapter / interface** | Each way a computer connects: `Wi-Fi`, `Ethernet`, and once installed, `Tailscale`. A firewall rule can be limited to one adapter. |
| **Whitelist** | A list of addresses allowed in. Everything not on it is refused. |
| **Two-factor (2FA)** | A second proof besides the password: a 6-digit code from an authenticator app on your phone, which changes every 30 seconds. |
| **Authenticator app** | A phone app that makes two-factor codes, such as Microsoft Authenticator or Google Authenticator. You add a service by scanning its QR code once. |
| **Permanent password** | A RustDesk password that stays the same, so you can connect when nobody is at the host. RustDesk's default is a one-time password that changes. |
| **ID server / relay server** | RustDesk's public servers, used when you connect by RustDesk's 9- or 10-digit ID. These guides turn them off and connect by Tailscale address instead. |
| **`127.0.0.1`** | A special address that always means "this same computer". Pointing a setting at it is a way of saying "nowhere else". |
| **Service** | A program that runs in the background, even before anyone signs in. RustDesk's service is what lets you see the sign-in screen remotely. |
| **PowerShell** | Windows' command window. Run it **as administrator** when a step changes system settings like the firewall. |
| **Script** | A file of commands that runs them for you in order. `.ps1` files are PowerShell scripts. |
| **SHA-256 / checksum** | A fingerprint of a file. The scripts store the fingerprint of each pinned installer; if a download's fingerprint differs, it isn't that file, and the script refuses to run it. |
| **Digital signature (publisher)** | A seal the publisher puts on a program, which Windows or macOS can check. A valid signature from the right publisher (`PURSLANE` for RustDesk and `Tailscale Inc.` for Tailscale on Windows; their Apple developer teams on a Mac) shows the file is theirs and unchanged. The scripts check it, and the guides show how to check it by hand. |
