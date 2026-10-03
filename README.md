<div align="center">
	<img width=140 src="assets/cover.svg" />
	<h2>iwhale</h2>
</div>

[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)]()
[![Platform](https://img.shields.io/badge/platform-Windows%20x64-0078D6.svg?style=flat-square)]()
[![Language](https://img.shields.io/badge/language-PowerShell-5391FE.svg?style=flat-square)]()
[![Python deps](https://img.shields.io/badge/python%20packages-zero-brightgreen.svg?style=flat-square)]()

### Finally, a monitor that knows a keyboard is not a phone.

An iPhone presence and battery monitor for Windows. It reports what the phone is doing, tells an Apple peripheral apart from an actual iPhone, and explains why a device that is visibly plugged in is refusing to answer questions.

Companion to [phonewatch](https://github.com/Weeabo-Inc/phonewatch), which covers Android. Both feeds render in [klabsat](https://github.com/Weeabo-Inc/klabsat).

---

### What does this do?

Polls [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) and writes a JSON snapshot:

```json
{
  "seq": 12,
  "timestamp": "2026-10-03T04:08:03.738Z",
  "usb": {
    "present": true,
    "likely_iphone": false,
    "devices": [],
    "note": "Apple device present but looks like a HID peripheral (keyboard/mouse), not an iPhone"
  },
  "usbmux_ids": [],
  "device": null,
  "device_count": 0,
  "warnings": [],
  "interval_ms": 4000
}
```

When a real iPhone is booted and trusted, `device` fills in:

```json
{
  "available": true,
  "name": "iPhone",
  "product_type": "iPhone8,4",
  "ios_version": "15.8.3",
  "build": "19H380",
  "battery_pct": 42,
  "charging": "true"
}
```

---

### The distinction that matters

An Apple Magic Keyboard and an iPhone share a vendor ID, `0x05AC`. A naive monitor cheerfully reports the keyboard as a phone.

This one checks two independent things:

1. **Windows side.** Is there an Apple USB device, and does it look like a phone? A keyboard presents as HID keyboard and mouse collections. A phone presents as a composite device with a WPD child.
2. **usbmux side.** Does `idevice_id -l` actually see anything?

Then it reports the disagreement instead of picking a winner.

#### Four states, not two

| State | What it means |
|---|---|
| no device | unplugged, or no Apple hardware |
| **Apple peripheral only** | there is an Apple device. It is not a phone. |
| **Detected, not queryable** | it is on usbmux but will not answer: locked, not yet Trusted, or still booting |
| Queryable | full device info |

That third state is the one people lose hours to. A phone recovering on the red battery screen enumerates on USB and cannot be queried, which looks exactly like "broken" unless something names it.

---

### How do I use it?

```powershell
# single pass, useful for testing
powershell -File iwhale.ps1 -Once

# continuous, 4 second interval
powershell -File iwhale.ps1 -IntervalMs 4000 -Out path\to\iphone.json
```

| Parameter | Default | Meaning |
|---|---|---|
| `-Bin` | `libimobile` | where `idevice_id.exe` and `ideviceinfo.exe` live |
| `-Out` | `iphone.json` | output snapshot |
| `-IntervalMs` | `4000` | poll interval |
| `-Once` | off | one pass and exit |

This is a PowerShell script, despite the extension being the only part of a filename anyone ever checks.

---

### Requirements

| Component | Why |
|---|---|
| PowerShell 5.1+ | the script |
| [libimobiledevice win-x64](https://github.com/libimobiledevice-win32/imobiledevice-net/releases) | provides `idevice_id.exe` and `ideviceinfo.exe` |
| Apple Mobile Device Support *(optional)* | provides the usbmux transport. `winget install Apple.AppleMobileDeviceSupport` |

---

### How it works under the hood

#### `ideviceinfo` is slow

It takes roughly 0.5 to 1.5 seconds per call. So it is not called every tick. The loop queries only when a device is actually present, and only every third tick, reusing the cached result in between. A monitor that costs a second per poll is a monitor you turn off.

#### Atomic writes

Snapshots go to a temp file and are moved into place. The dashboard never reads a half-written file. Small thing, prevents a whole class of confusing bug reports.

#### The empty answer trap

A monitor is only useful if it can tell "no device" from "I failed to look". An empty result set is ambiguous, so the snapshot carries the evidence alongside the verdict:

```json
"usb": { "total_present_nodes": 214, "usb_devices_present": 13, "matched_count": 0 }
```

214 nodes walked, 13 USB devices seen, 0 matched. That is a measurement. Without those counts, `"phones": []` could equally mean the enumerator silently broke.

---

### What it can and can't do

**Can do:**
- Detect Apple hardware and classify it into four states
- Tell a peripheral apart from a phone
- Report battery percentage and charge state when the device is queryable
- Write atomically so readers never see a partial file
- Run with zero Python packages installed

**Can't do:**
- Read anything from a locked or untrusted phone. That is iOS, and the platform is designed so an untrusted host learns nothing.
- Run on macOS or Linux without changes. The USB enumeration uses Windows PnP.
- Wake a phone that is off, flat, or not enumerating

---

### Project layout

```
iwhale/
├── assets/
│   └── cover.svg
├── iwhale.ps1        the whole monitor
├── LICENSE
└── README.md
```

---

### Credits

- [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice), which does the actual talking
- [imobiledevice-net](https://github.com/libimobiledevice-win32/imobiledevice-net) for the Windows builds
- [Twemoji](https://github.com/twitter/twemoji) for the cover art, CC BY 4.0

---

<div align="center">
	<br/>
	<i>if it has keys on it, this will not call it a phone.</i>
	<br/>
	<sub>read only. it never writes to the device.</sub>
</div>
