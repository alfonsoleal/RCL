# Security

RCL lets an iPhone or iPad see and control a Mac, so a flaw in it matters. If you find one, please
report it privately: use **Report a vulnerability** on this repository's Security tab. Say what you
found, how to reproduce it, and which versions of the Mac app and of the iPhone and iPad app you
tried. Please don't open a public issue or pull request for it, and give a fix time to ship before
you publish anything.

## In scope

- What the Mac app accepts on its own networks, over a USB cable, peer to peer and through Remote
  Access (TCP and QUIC), and what a device can make it do.
- Pairing: the QR code, the typed code, `rcl://` links, a USB cable's automatic pairing, Require
  pairing, and the paired devices and keys kept in the keychain.
- Files between the devices and the Mac, and the Files app's Mac location.
- Private Mode and the quick password.

Problems in Sill itself, which RCL derives from, may also concern Sill's author:
[Saffsanity/sill](https://github.com/Saffsanity/sill/security/policy).
