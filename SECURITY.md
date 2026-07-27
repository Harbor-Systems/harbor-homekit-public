# Security

## Supported versions

Only the latest tagged release is supported.

## Network boundary

This integration is intended for a trusted home LAN. The Harbor camera, bridge
computer, and Apple Home devices must be on a network where they can reach one
another. Do not port-forward or otherwise expose ports 1984 or 8555 to the
internet.

go2rtc's API and RTSP listener bind only to loopback. The LAN-facing gateway
accepts only WHIP `POST` and session `DELETE` requests for the configured
camera serial, authenticated with a unique 256-bit token. It does not expose
go2rtc's Web UI, configuration, playback, snapshots, or general API.

The token is carried in an HTTP URL because the current Harbor app accepts a
custom endpoint but does not expose custom request headers. Anyone who obtains
the complete URL can publish to that stream. Plain HTTP also does not protect
the token from a device capable of intercepting traffic on the local network.
Keep the URL out of screenshots and logs, use a strong Wi-Fi password, avoid
untrusted devices on the same LAN, and do not use this integration on public
or shared networks.

Port 8555 remains reachable for WebRTC encrypted media transport. The HomeKit
setup code is separate: it protects Apple Home pairing and must not be used as
the WHIP token.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Report it privately
through GitHub's **Report a vulnerability** button on this repository's
Security page.
