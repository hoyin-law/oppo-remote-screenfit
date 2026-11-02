# oppo-remote-screenfit

> Automatically switch your Windows display to the **native resolution of your OPPO Pad / Find N6** when using **OPPO Connect (O+ Connect)** remote control — no stretching, no letterboxing.

For Windows 11 + OPPO Connect remote-control scenarios. Verified with **OPPO Pad 5 Pro** and **OPPO Find N6**.

[简体中文](README.md) | English

---

## The problem

The remote-control engine inside OPPO Connect does not adapt to the receiving device's resolution. It captures whatever the host display is currently showing and scales it onto the tablet/phone.

- A laptop panel is 16:10 / 16:9, a tablet is 1.41 / 1.10 → the image is either stretched or letterboxed.
- Changing the resolution manually is limited by the physical panel's supported modes (laptop panels usually have no tablet-like aspect ratio).

This project uses the **virtual display driver that ships with OPPO Connect** (installed by OPPO Connect itself, WHQL-signed) to create a virtual display that exactly matches the device's native resolution when a remote session starts, switches to it, and restores everything afterwards. The result is pixel-perfect 1:1 output with no stretching and no black bars.

| Device | Native resolution | Aspect |
|---|---|---|
| OPPO Pad 5 Pro / Pad 4 Pro | 3392 × 2400 | 7:5 |
| OPPO Pad 5 / Pad 3 Pro | 3000 × 2120 | 7:5 |
| OPPO Pad 3 | 2800 × 2000 | 7:5 |
| OPPO Pad Mini | 2520 × 1680 | 3:2 |
| OPPO Pad Air5 | 2800 × 1980 | 7:5 |
| OPPO Find N6 (inner screen) | 2480 × 2248 | ≈1.10 |
| OnePlus Pad 3 Pro / 2 Pro | 3392 × 2400 | 7:5 |
| OnePlus Pad Pro / Pad 2 | 3000 × 2120 | 7:5 |
| OnePlus Pad (1st gen) | 2800 × 2000 | 7:5 |

See [docs/devices.md](docs/devices.md) for the full table and instructions to add new devices
via `scripts/devices.json` without touching code.

---

## How it works (short version)

1. `Watcher.ps1` (elevated scheduled task, starts at logon) reads OPPO Connect's own logs to detect **remote-control session start/end**:
   - `start remote control: ... "deviceName":"OPPO Find N6" ...`
   - `stop remote control: ...`
2. On session start it calls OPPO's bundled `OPDisplayDriverTool.exe` to create a virtual display at the device's native resolution.
3. The same watcher switches the display topology to **"show only on the virtual display"**, so the remote side only sees one screen.
4. When the session ends it restores the exact layout you had before connecting (extend / duplicate / single screen), then removes the virtual display.

Ordinary device connect/disconnect does not trigger any switching; only a remote-control session does.

The tool only reads log files — it does not inject into or modify OPPO Connect.

For design details, anti-flapping strategy and pitfalls, see [docs/how-it-works.md](docs/how-it-works.md).

---

## Requirements

- Windows 11 (22H2+, 24H2/25H2 recommended)
- OPPO Connect PC client (tested with 16.2.20.0)
- OPPO Connect installed and at least one phone/tablet successfully connected once (this is when the virtual-display driver and tool become available)
- PowerShell 5.1 (built into Windows)
- Administrator rights for installation; no admin needed for daily use

Virtual display tool path (installed by OPPO Connect):

```
%LOCALAPPDATA%\DeviceSpace\ext-service\OPVirtualDisplayDriver\OPDisplayDriverTool.exe
```

If it does not exist: open OPPO Connect's "Screen Extend" feature once so it unpacks the components.

---

## Install (recommended: one-click Release package)

1. Download the latest `oppo-remote-screenfit-v*.zip` from [Releases](https://github.com/hoyin-law/oppo-remote-screenfit/releases);
2. Extract it anywhere;
3. Double-click **`一键安装.cmd`** and approve the UAC prompt.

The installer copies the program to `%LOCALAPPDATA%\OPPO-ScreenFit` (so you can move or delete the extracted folder afterwards) and registers a logon-start, highest-privilege scheduled task.

### Command-line install (optional)

```powershell
irm https://raw.githubusercontent.com/hoyin-law/oppo-remote-screenfit/main/install.ps1 | iex
```

(The script downloads the latest release and requests elevation automatically.)

### Manual install (development / debugging)

```powershell
git clone https://github.com/hoyin-law/oppo-remote-screenfit.git
cd oppo-remote-screenfit
.\scripts\Install.ps1
```

---

## Usage

- **Idle**: both guards only read logs; they never touch the display.
- **Remote session starts**: within ~10–20 seconds the virtual display is created and activated at the device's native resolution.
- **Session ends**: the previous layout is restored within about a second, then the virtual display is removed.

### Manual mode

```powershell
# Create a virtual display
.\scripts\TabletScreen.ps1 -Device Pad5Pro    # 3392x2400
.\scripts\TabletScreen.ps1 -Device FindN6     # 2480x2248

# Show current displays (read-only)
.\scripts\TabletScreen.ps1 -Status

# Remove the virtual display
.\scripts\TabletScreen.ps1 -Device Off
```

> For best results set Windows display scaling for the virtual display to **200%** once
> (Settings → System → Display). Windows remembers it per monitor.

### Diagnostics

```powershell
.\scripts\Diagnose.ps1
```

Prints current displays, OPPO Connect session/device, the latest encoder resolution and this project's logs.

---

## Disable / Uninstall

- **Temporarily disable**: create an empty `STOP.txt` in the install directory (`%LOCALAPPDATA%\OPPO-ScreenFit`); both guards exit on next start.
- **Uninstall**: double-click **`一键卸载.cmd`** (or run `scripts\Uninstall.ps1`). It stops/removes the tasks, removes autostart, deletes the virtual display, restores the internal display and deletes the install directory.

---

## Known limitations

- **Portrait is not supported**: a landscape stream in a portrait viewport must have top/bottom bars (correct aspect, no stretching). The project only guarantees full-screen in landscape.
- **10–20 second delay**: the virtual display is created after the remote session starts; the client may briefly show the old picture before it switches.
- **Client compatibility**: OPPO Connect log formats may change between major versions. If it stops working after an update, run `Diagnose.ps1` and open an issue.
- **Display numbering**: Windows keeps incrementing the virtual display's GDI number (DISPLAY47, 57, …). The tool enumerates up to 200; a reboot resets the numbering in extreme cases.
- The physical screen flickers briefly during a topology switch — expected.

---

## macOS

OPPO Connect also supports remotely controlling a Mac (since OPPO Pad 4 Pro). The macOS version cannot reuse the Windows driver; it would need `CGVirtualDisplay` / BetterDisplay for the virtual screen and `displayplacer` for switching.

Feasibility notes and a "collect info on your Mac" script: [macos/README.md](macos/README.md).

---

## Safety & disclaimer

- This project only calls the virtual display driver/tool **already installed by OPPO Connect**; it does **not** contain, modify or redistribute any OPPO/ByteDance (SunLogin/Oray) binaries.
- It only reads OPPO Connect's local logs to detect session state; it does not inject into or modify OPPO Connect.
- This project is not affiliated with OPPO or Oray.
- Display switching uses system-level APIs — **use at your own risk**. It is recommended to know how to use Win+P / display settings as a fallback.
- If you run into issues, please open an Issue and include the output of `Diagnose.ps1`.

---

## License

[MIT](LICENSE)
