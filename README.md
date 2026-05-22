# ScreenToRtsp

Capture a GNOME Wayland desktop and publish it as an RTSP stream (for Frigate
or any RTSP client) — without the `xdg-desktop-portal` consent dialog.

```
org.gnome.Mutter.ScreenCast (DBus)
  → PipeWire node
  → GStreamer (videorate → videoscale → x264enc)
  → rtspclientsink
  → MediaMTX (rtsp://host:8554/screen)
```

## Quick start

Run **on the machine that will publish the stream** (the one with GNOME running):

```bash
cd ScreenToRtsp
./setup.sh
```

The wizard asks:
- action: install/reconfigure, uninstall, or just show the current stream URL
- which quality profile (`low` / `medium` / `high` / `ultra`)
- monitor connector — auto-detected from `org.gnome.Mutter.DisplayConfig`,
  press Enter to accept
- RTSP port (`8554`) and path (`screen`)
- whether to require username/password — empty password = auto-generated 16-char
- sudo password (cached for the run, so apt + writes to `/etc` are unattended)

It then installs everything, enables the systemd units, and prints the final
`rtsp://…` URL.

Re-run `./setup.sh` any time to switch profile or change the password — it
detects the existing install and pre-fills defaults.

### Copying the project into a VM

The wizard runs *inside* the target machine. To get the project there:

```bash
# from your workstation
scp -r ScreenToRtsp/ user@vm:~/
ssh user@vm
cd ScreenToRtsp && ./setup.sh
```

## Files installed on the target

| Path                                                | Owner | What it is              |
|-----------------------------------------------------|-------|-------------------------|
| `/usr/local/bin/mediamtx`                           | root  | RTSP server binary      |
| `/usr/local/bin/screen-to-rtsp`                     | root  | capture+encode script   |
| `/etc/mediamtx.yml`                                 | root  | mediamtx config (auth)  |
| `/etc/systemd/system/mediamtx.service`              | root  | mediamtx unit           |
| `~/.config/screen-to-rtsp/profile.env`              | user  | profile vars (no secret)|
| `~/.config/screen-to-rtsp/credentials.env` (0600)   | user  | RTSP_USER / RTSP_PASS   |
| `~/.config/systemd/user/screen-to-rtsp.service`     | user  | publisher unit          |

## Profiles

Edit `profiles/<name>.env` or add new ones. The wizard auto-discovers them.

| Profile | Resolution | FPS | Bitrate | x264 preset | CPU note            |
|---------|------------|-----|---------|-------------|---------------------|
| low     | 1280×720   | 15  | 1500    | ultrafast   | safe on busy VMs    |
| medium  | 1920×1080  | 20  | 2500    | superfast   | balanced            |
| high    | 1920×1080  | 25  | 4000    | superfast   | needs ~2 CPU cores  |
| ultra   | 1920×1080  | 30  | 6000    | veryfast    | needs ~3 CPU cores  |

## Re-running

Run `./setup.sh` again to switch profile, change the password, or move to a
different host. It overwrites previous config in place. To remove everything
choose the *Uninstall* action.

## Use it from Frigate

```yaml
cameras:
  desktop:
    enabled: true
    ffmpeg:
      inputs:
        - path: rtsp://USER:PASS@HOST:8554/screen
          input_args: preset-rtsp-restream
          roles: [detect, record]
    detect:
      width: 1920
      height: 1080
      fps: 5
```

## Tunables (env in `~/.config/screen-to-rtsp/profile.env`)

`WIDTH`, `HEIGHT`, `FPS`, `BITRATE_KBPS`, `X264_PRESET`, `X264_THREADS`,
`SCREEN_CONNECTOR`, `RTSP_URL`, `RTSP_LATENCY_MS`. After editing:

```bash
systemctl --user daemon-reload && systemctl --user restart screen-to-rtsp
```

## Troubleshooting

- **Service exits "no element x264enc"** — `apt install gstreamer1.0-plugins-ugly`.
- **"no more input formats"** — pipewiresrc got DMA-BUF and downstream wanted
  CPU memory. The pipeline pins `video/x-raw,format=BGRx` after pipewiresrc to
  force the shm path; do not remove it.
- **Stream FPS lower than configured** — Mutter only emits new frames on
  damage. The installer asks Mutter for a steady `frame-rate`; if you still
  see drops, the encoder is starved — lower the profile or give the VM more
  CPU.
- **Cannot find connector** — list monitors with
  `gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig --method org.gnome.Mutter.DisplayConfig.GetCurrentState`.
