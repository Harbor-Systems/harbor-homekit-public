# Security

## Supported versions

Only the latest tagged release is supported.

## Network boundary

This integration is intended for a trusted home LAN. The Harbor camera, bridge
computer, and Apple Home devices must be on a network where they can reach one
another. Do not port-forward or otherwise expose ports 1984, 8554, or 8555 to
the internet.

The current Harbor camera WHIP flow does not authenticate to go2rtc. Anyone who
can reach the bridge on the LAN may be able to access the go2rtc API or camera
streams. Use a strong Wi-Fi password, avoid untrusted devices on the same LAN,
and do not use this integration on public or shared networks.

The HomeKit setup code protects Apple Home pairing. It does not authenticate
the go2rtc API, WHIP ingest, or RTSP output.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Report it privately
through GitHub's **Report a vulnerability** button on this repository's
Security page.
