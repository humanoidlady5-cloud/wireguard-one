# WireGuard One (Free Edition)

One-command WireGuard VPN installer for Ubuntu & Debian VPS.

## Install

    chmod +x install.sh
    sudo ./install.sh

Press Enter to accept defaults. The script handles everything else.

## Add More Devices Manually

The free version includes just the installer. To add more devices, append
a [Peer] block to /etc/wireguard/wg0.conf manually. See the
WireGuard docs: https://www.wireguard.com/quickstart/

## Upgrade to Pro ($12)

The Pro version includes:

- wg-add-client.sh — add devices with one command
- uninstall.sh — clean removal
- Extended README with troubleshooting
- Priority support

Buy WireGuard One Pro: https://humanoidlady.gumroad.com/l/gdlwmm

## Full Setup

1. Install: sudo ./install.sh
2. Open UDP 51820 in your VPS provider firewall
3. Scan the QR code with the WireGuard mobile app
4. Toggle the tunnel on

## Requirements

- Ubuntu 22.04/24.04 or Debian 12
- Root access
- A VPS with a public IPv4

## License

MIT — free to use, modify, and distribute.

---

Not affiliated with the WireGuard project.