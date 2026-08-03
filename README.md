# Harbor HomeKit

Connect a Harbor camera to Apple Home through a small local
[go2rtc](https://github.com/AlexxIT/go2rtc) bridge.

```text
Harbor camera ──authenticated WHIP──► narrow gateway ──localhost──► go2rtc
                                                                    │
                                                                 HomeKit
                                                                    ▼
                                                               Apple Home
```

> [!IMPORTANT]
> This integration is for a trusted home LAN. Do not expose ports 1984 or 8555
> to the internet. Read [SECURITY.md](SECURITY.md) before installing.

## Requirements

- A Harbor camera
- An iPhone or iPad with the Apple Home app
- An always-on Mac or Linux computer on the same LAN
- The camera serial number

On macOS, the bridge starts after the user logs in. It does not run at the
FileVault login screen.

## macOS installation

Download this repository with **Code > Download ZIP**, open the ZIP, and open
Terminal in the extracted folder. Then run:

```bash
./install-macos-service.sh
```

The installer asks for the Harbor camera serial number and applies it
consistently throughout the configuration. Leave `pin: GENERATE` unchanged;
setup creates a unique HomeKit code and preserves it across updates.

For support or automated deployment, the prompt can be skipped:

```bash
./install-macos-service.sh --camera-serial 2400000000
```

The resulting camera configuration is equivalent to:

```yaml
streams:
  "2400000000":
    - ffmpeg:2400000000#video=h264#audio=opus

homekit:
  "2400000000":
    pin: GENERATE
    name: Harbor Camera
```

The installer:

- downloads Harbor's pinned go2rtc build and verifies its SHA-256 checksum;
- generates a unique HomeKit setup code;
- generates a separate 256-bit WHIP ingest token;
- keeps the go2rtc API and RTSP listener accessible only from this Mac;
- installs files under `~/Library/Application Support/Harbor HomeKit`;
- starts the `co.harbor.homekit` LaunchAgent after login;
- restarts the bridge automatically if it exits; and
- preserves Apple Home pairing records during upgrades.

At completion it prints:

```text
HomeKit setup code: XXX-XX-XXX

Harbor camera WHIP endpoint:
http://BRIDGE_IP:1984/api/webrtc?dst=CAMERA_SERIAL&token=...
```

Keep both the setup code and complete WHIP endpoint private.

For a temporary foreground run:

```bash
./run-native.sh
```

To remove automatic startup while preserving the installed configuration:

```bash
./uninstall-macos-service.sh
```

Logs are stored in `~/Library/Logs/Harbor HomeKit`.

## Linux installation

Install Docker, then run:

```bash
./generate-homekit-pin.sh
chmod 600 go2rtc.yaml
mkdir -p .harbor-data
chmod 700 .harbor-data
docker compose up -d
```

Docker host networking is required for HomeKit's mDNS advertisement. The
compose configuration is Linux-only. It builds the restricted WHIP gateway and
stores its generated token in `.harbor-data/whip-token`. The container runs as
the unprivileged UID/GID `1000:1000`. If the Linux account uses different IDs,
set `HARBOR_UID` and `HARBOR_GID` before running Compose.

## Point Harbor at the bridge

Find the bridge computer's LAN IP and configure the Harbor camera's WHIP
publisher endpoint printed by the macOS installer:

```text
http://BRIDGE_IP:1984/api/webrtc?dst=CAMERA_SERIAL&token=UNIQUE_TOKEN
```

The `dst` value must exactly match the serial used in `go2rtc.yaml`. Contact
Harbor Support if the camera's publisher settings are not available in your
software version.

On Linux, construct the same endpoint using:

```bash
cat .harbor-data/whip-token
```

The token is generated once and preserved across restarts. Treat the complete
endpoint as a password. The gateway accepts only authenticated WHIP publishing
for the configured serial; it does not expose the go2rtc dashboard, stream
playback, configuration, or other API routes.

## Add to Apple Home

1. Make sure the Harbor camera is actively publishing.
2. Open **Home** → **+** → **Add Accessory** → **More Options**.
3. Select **Harbor Camera**.
4. Enter the setup code printed by the installer.

## Troubleshooting

### Harbor Camera does not appear

- Keep the bridge and Apple device on the same LAN/subnet.
- On macOS, use the native LaunchAgent rather than Docker Desktop.
- Check `~/Library/Logs/Harbor HomeKit/go2rtc.error.log`.
- `no interfaces for listen` indicates the unpatched upstream mDNS behavior.
  Harbor release binaries include the workaround from
  [go2rtc PR #1283](https://github.com/AlexxIT/go2rtc/pull/1283).

### Apple Home says “No Response”

Confirm the camera uses the complete authenticated endpoint. On the bridge,
check stream status locally with:

```bash
curl http://127.0.0.1:1985/api/streams
```

### High CPU usage

Apple Home requires H.264 video. Transcoding H.265 video can be CPU-intensive.
Install FFmpeg with `brew install ffmpeg` on macOS. The Linux container includes
FFmpeg.

## Building the patched binary

Customers normally use the checksum-verified release binary. Developers can
reproduce it locally:

```bash
brew install go
./build-patched-go2rtc-macos.sh
```

The build verifies the exact upstream go2rtc commit before applying Harbor's
versioned patch.

## Releases and signing

Release archives contain go2rtc and the Harbor WHIP gateway.
`checksums.txt` is generated by GitHub Actions. macOS releases must be signed
with Project Monitor Inc.'s Developer ID and accepted by Apple's notarization
service; the workflow fails rather than publishing unsigned macOS binaries.
The native runner verifies the exact identity
`Developer ID Application: Project Monitor, Inc. (TC395YUVC2)` and Team ID
`TC395YUVC2` before executing downloaded macOS binaries.

GitHub also publishes signed build-provenance attestations for every archive
and `checksums.txt`. They can be verified independently with GitHub CLI:

```bash
gh attestation verify harbor-homekit-go2rtc_mac_arm64.zip \
  --repo Harbor-Systems/harbor-homekit-public
```

## License

Copyright © 2026 Project Monitor Inc. Released under the [MIT License](LICENSE).
