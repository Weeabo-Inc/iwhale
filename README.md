# iwhale

**An iPhone presence and battery monitor for Windows.** Companion to
[phonewatch](https://github.com/Weeabo-Inc/phonewatch) — that one watches Android, this one
watches iOS, and [klabsat](https://github.com/Weeabo-Inc/klabsat) renders both.

Polls [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) and writes a
JSON snapshot the dashboard can read. No third-party Python packages, no iTunes.

---

## What it reports

```json
{
  "seq": 12,
  "timestamp": "2026-10-03T04:08:03.738Z",
  "usb": {
    "present": true,
    "likely_iphone": false,
    "devices": [ ... ],
    "note": "Apple device present but looks like a HID peripheral (keyboard/mouse), not an iPhone"
  },
  "usbmux_ids": [],
  "device": null,
  "device_count": 0,
  "warnings": [],
  "interval_ms": 4000
}
```

When a real iPhone is booted *and trusted*, `device` fills in:

```json
{
  "available": true,
  "name": "iPhone", "product_type": "iPhone8,4",
  "ios_version": "15.8.3", "build": "19H380",
  "battery_pct": 42, "charging": "true"
}
```

---

## The distinction that matters

**An Apple Magic Keyboard and an iPhone share a vendor ID (`0x05AC`).** A naive monitor
cheerfully reports a keyboard as a phone.

This one doesn't, because it checks two independent things:

1. **Windows-side truth** — is there an Apple USB device, and does it look like a phone?
   A keyboard presents only as HID keyboard/mouse collections; a phone presents as a
   composite device with a WPD child.
2. **usbmux-side truth** — does `idevice_id -l` actually see a device?

Then it reports the *disagreement* rather than picking a winner:

```
Apple device present but looks like a HID peripheral (keyboard/mouse), not an iPhone
```

### Four states, not two

| State | What it means |
|---|---|
| no device | unplugged, or no Apple hardware |
| **Apple peripheral only** | there *is* an Apple device — it is not a phone |
| **Detected, not queryable** | it's on usbmux but won't answer: **locked, not yet Trusted, or still booting** |
| Queryable | full device info |

That third state is the one people lose hours to. A phone on the red-battery-icon recovery
screen enumerates on USB and **cannot be queried** — which looks identical to "broken"
unless something names it.

---

## Design notes

**`ideviceinfo` is slow** (~0.5–1.5 s). It is therefore **not** called every tick: the loop
queries only when a device is actually present, and only every third tick, reusing the
cached result in between. A monitor that costs a second per poll is a monitor you turn off.

**Windows-side enumeration needs no driver.** Reading USB presence via PnP requires nothing
installed. Full device data needs Apple's Mobile Device Support stack *or* a libimobiledevice
build — see below.

---

## Requirements

| Component | Why |
|---|---|
| Python 3.8+ | the script; **stdlib only** |
| [libimobiledevice win-x64](https://github.com/libimobiledevice-win32/imobiledevice-net/releases) | provides `idevice_id.exe` / `ideviceinfo.exe` |
| Apple Mobile Device Support *(optional)* | provides the usbmux transport; `winget install Apple.AppleMobileDeviceSupport` |

Point it at your libimobiledevice directory:

```console
$ python iwhale.ps1 -Bin C:\path\to\libimobile -Once
```

*(PowerShell script — run with `powershell -File`, not `python`.)*

---

## Usage

```powershell
# single pass, useful for testing
powershell -File iwhale.ps1 -Once

# continuous, 4s interval
powershell -File iwhale.ps1 -IntervalMs 4000 -Out path\to\iphone.json
```

| Parameter | Default | Meaning |
|---|---|---|
| `-Bin` | `<REPO_ROOT>\libimobile` | where `idevice_id.exe` / `ideviceinfo.exe` live |
| `-Out` | `phonewatch\iphone.json` | output snapshot |
| `-IntervalMs` | `4000` | poll interval |
| `-Once` | off | one pass and exit |

Writes are **atomic** (temp file + move), so the dashboard never reads a half-written
snapshot. That's a small thing that prevents a whole class of confusing bug reports.

---

## The empty-answer trap

A monitor is only useful if it can tell *"no device"* from *"I failed to look"*. An empty
result set is ambiguous, so this reports the evidence alongside the verdict:

```json
"usb": { "total_present_nodes": 214, "usb_devices_present": 13, "matched_count": 0 }
```

**214 nodes walked, 13 USB devices seen, 0 matched.** That is a *measurement*. Without
those counts, `"phones": []` could equally mean the enumerator silently broke.

---

## Scope, honestly

**Solid:** Apple device detection, the four-state classification, peripheral-vs-phone
discrimination, battery and charge state when queryable, atomic writes, stdlib-only.

**Requires the phone to be unlocked and Trusted** for full data. There is no way around
this — it's iOS, and the whole design of the platform is that an untrusted host learns
nothing.

**Windows-focused.** The USB enumeration uses PnP; the libimobiledevice side is portable.

## License

MIT
