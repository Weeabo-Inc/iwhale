# iwhale.ps1 - iPhone presence + battery/health monitor.
#
# Companion to phonewatch (which covers the Samsung). Polls libimobiledevice and
# writes a JSON snapshot the dashboard reads, so Samsung and iPhone state show up
# in one place.
#
# Design notes (honest):
#   * Device data (battery %, health) is ONLY available when the iPhone is booted,
#     unlocked, and "Trusted" on this PC. A phone stuck on the red-battery icon
#     cannot be queried - we report its USB presence and say why.
#   * `ideviceinfo` is slow (~0.5-1.5s). We do NOT call it every tick: the loop
#     only queries when a device is actually present, and only every N ticks.
#   * Zero external dependencies beyond the bundled libimobiledevice binaries.

[CmdletBinding()]
param(
    [string]$Bin     = '<REPO_ROOT>\libimobile',
    [string]$Out     = '<REPO_ROOT>\phonewatch\iphone.json',
    [int]$IntervalMs = 4000,
    [switch]$Once
)

$ErrorActionPreference = 'Continue'

$IdeviceId   = Join-Path $Bin 'idevice_id.exe'
$IdeviceInfo = Join-Path $Bin 'ideviceinfo.exe'

function Write-JsonAtomic {
    param([string]$Path, [string]$Json)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Json)
    if (Test-Path $Path) { Remove-Item $Path -Force -ErrorAction SilentlyContinue }
    Move-Item -Path $tmp -Destination $Path -Force -ErrorAction SilentlyContinue
}

function Get-AppleUsbPresence {
    <#
      Windows-side truth: is ANY Apple USB device attached, and is it an iPhone?
      We can distinguish an iPhone from the Magic Keyboard by product string and
      by whether it exposes the Apple "NCM"/mobile device interfaces.
    #>
    $rows = @()
    try {
        $rows = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
                Where-Object { $_.InstanceId -match 'VID_05AC' }
    } catch { }

    if (-not $rows) {
        return [pscustomobject]@{
            present        = $false
            likely_iphone  = $false
            devices        = @()
            note           = 'no Apple USB device attached'
        }
    }

    $out = foreach ($r in $rows) {
        [pscustomobject]@{
            status        = "$($r.Status)"
            class         = "$($r.Class)"
            friendly_name = "$($r.FriendlyName)"
            instance_id   = "$($r.InstanceId)"
        }
    }

    # Heuristic: an iPhone/iPad presents as a USB Composite Device with a WPD
    # (portable device) child, and its friendly name usually names the model.
    # A Magic Keyboard shows up only as HID keyboard/mouse interfaces.
    $names = ($out | ForEach-Object { $_.friendly_name }) -join ' | '
    $isIphone = ($names -match 'iPhone|iPad|iPod') -or
                ($out | Where-Object { $_.class -eq 'WPD' }) -ne $null

    return [pscustomobject]@{
        present       = $true
        likely_iphone = [bool]$isIphone
        devices       = $out
        note          = if ($isIphone) { 'Apple mobile device present' }
                        else { 'Apple device present but looks like a HID peripheral (keyboard/mouse), not an iPhone' }
    }
}

function Get-IphoneInfo {
    <#
      Query libimobiledevice for one device's properties.
      Returns $null when no device is paired/trusted.
    #>
    if (-not (Test-Path $IdeviceInfo)) { return $null }

    $raw = & $IdeviceInfo 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $raw -match 'No device found') {
        return [pscustomobject]@{
            available = $false
            error     = ($raw.Trim() -replace '\s+', ' ')
        }
    }

    # ideviceinfo emits "Key: Value" lines.
    $map = @{}
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match '^\s*([^:]+):\s*(.*)$') {
            $map[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }

    $battery = $null
    if ($map.ContainsKey('BatteryCurrentCapacity')) {
        $battery = [int]$map['BatteryCurrentCapacity']
    }

    return [pscustomobject]@{
        available      = $true
        udid           = $map['UniqueDeviceID']
        name           = $map['DeviceName']
        product_type   = $map['ProductType']
        ios_version    = $map['ProductVersion']
        build          = $map['BuildVersion']
        model          = $map['HardwareModel']
        serial         = $map['SerialNumber']
        battery_pct    = $battery
        charging       = if ($map.ContainsKey('ExternalConnected')) { $map['ExternalConnected'] } else { $null }
        fully_charged  = if ($map.ContainsKey('FullyCharged')) { $map['FullyCharged'] } else { $null }
        battery_keys   = @($map.Keys | Where-Object { $_ -match 'Batter|Charg|External' } | Sort-Object)
        error          = $null
    }
}

function Get-DeviceList {
    $ids = @()
    if (Test-Path $IdeviceId) {
        try { $ids = @(& $IdeviceId -l 2>$null | Where-Object { $_ -match '\S' }) } catch { }
    }
    return $ids
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

$seq = 0
$cachedInfo = $null
$infoAge = 99

while ($true) {
    $seq++
    $usb  = Get-AppleUsbPresence
    $ids  = Get-DeviceList

    $warnings = @()
    $info = $null

    if ($ids.Count -gt 0) {
        # Only spend the expensive call occasionally, and reuse between ticks.
        if ($infoAge -ge 3 -or $null -eq $cachedInfo) {
            $cachedInfo = Get-IphoneInfo
            $infoAge = 0
        } else {
            $infoAge++
        }
        $info = $cachedInfo

        if ($info -and -not $info.available) {
            $warnings += "iPhone detected over usbmux but not queryable: $($info.error). Usually means locked, not yet Trusted on this PC, or still booting."
        }
    } else {
        $cachedInfo = $null
        $infoAge = 99
        if ($usb.present -and $usb.likely_iphone) {
            $warnings += 'Apple mobile device on USB but usbmux has no device - likely still booting or not yet Trusted.'
        }
    }

    if ($info -and $info.available -and $null -ne $info.battery_pct) {
        if ($info.battery_pct -le 5) {
            $warnings += "iPhone battery critically low ($($info.battery_pct)%) - deep-discharge recovery in progress."
        }
    }

    $snap = [ordered]@{
        seq         = $seq
        timestamp   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        usb         = $usb
        usbmux_ids  = $ids
        device      = $info
        device_count = $ids.Count
        warnings    = $warnings
        interval_ms = $IntervalMs
    }

    $json = $snap | ConvertTo-Json -Depth 8
    Write-JsonAtomic -Path $Out -Json $json

    $dev = if ($info -and $info.available) { "$($info.product_type) iOS $($info.ios_version)" } else { '-' }
    $bat = if ($info -and $null -ne $info.battery_pct) { "$($info.battery_pct)%" } else { '-' }
    Write-Host ("[{0,5}] iphone: usbmux={1} dev={2} bat={3} warn={4}" -f $seq, $ids.Count, $dev, $bat, $warnings.Count)

    if ($Once) { break }
    Start-Sleep -Milliseconds $IntervalMs
}
