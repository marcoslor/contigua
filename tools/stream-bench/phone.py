"""Read-only parsers for the phone facts the stream bench records.

Everything here is a pure function over captured `adb shell` output: no adb, no
files, no clock. The bench captures `dumpsys gfxinfo`, `dumpsys display`,
`dumpsys battery`, `dumpsys thermalservice`, `dumpsys cpuinfo`,
`dumpsys meminfo` and `dumpsys wifi` once per run (and once per soak sample)
and feeds the text in. Fixtures invent `com.example.app` and never carry a real
device's names.

Only numeric Wi-Fi facts come out: the SSID, BSSID, IP and MAC never leave the
parser's input.
"""

import math
import re

FRAMESTATS_MARKER = "---PROFILEDATA---"


def _number(pattern, text, flags=0):
    match = re.search(pattern, text, flags)
    return float(match.group(1)) if match else None


def _integer(pattern, text, flags=0):
    value = _number(pattern, text, flags)
    return int(value) if value is not None else None


def gfxinfo_summary(text):
    """`dumpsys gfxinfo <pkg>`: frames rendered, janky frames and their percent."""
    return {
        "frames": _integer(r"Total frames rendered:\s*(\d+)", text),
        "janky_frames": _integer(r"Janky frames:\s*(\d+)", text),
        "janky_pct": _number(r"Janky frames:\s*\d+\s*\(([\d.]+)%\)", text),
    }


def percentile(values, fraction):
    """A nearest-rank percentile, so one outlier is never averaged away."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, int(math.ceil(fraction * len(ordered))))
    return ordered[min(rank, len(ordered)) - 1]


def framestats(text, seconds):
    """`dumpsys gfxinfo <pkg> framestats`: per-frame draw times in ms.

    A row's duration is `FrameCompleted - IntendedVsync`; the `Flags` column is
    ignored because the summary's jank count already applies the platform's
    rule. `fps` is the rows over the run's own seconds.
    """
    header = None
    durations = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("Flags,") and "FrameCompleted" in stripped:
            header = [name.strip() for name in stripped.split(",")]
            continue
        if header is None:
            continue
        if stripped == FRAMESTATS_MARKER:
            continue
        parts = [part.strip() for part in stripped.split(",")]
        if len(parts) < len(header) or not parts[0]:
            continue
        try:
            intended = int(parts[header.index("IntendedVsync")])
            completed = int(parts[header.index("FrameCompleted")])
        except (ValueError, IndexError):
            continue
        if completed <= intended:
            continue
        durations.append((completed - intended) / 1e6)
    return {
        "frames": len(durations),
        "p50_ms": percentile(durations, 0.50),
        "p95_ms": percentile(durations, 0.95),
        "p99_ms": percentile(durations, 0.99),
        "fps": len(durations) / seconds if seconds and seconds > 0 else None,
    }


def display_refresh(text, display_id=None):
    """The device line for one display: refresh rate and pixel size.

    With no `display_id`, the mirror's virtual display (the phone names it
    "contigua-N", uniqueId "virtual:…") is the one measured: that is the
    display whose rate the stream sets. A numeric id keeps the physical
    `local:<id>` lookup.

    `nil` when this `dumpsys display` has no matching line (the bench then
    leaves `vd_hz` empty instead of guessing).
    """
    marker = re.compile(r"DisplayDeviceInfo\{")
    unique = (re.compile(r"uniqueId\s*[=:]\s*\"?local:%d\"?" % display_id)
              if display_id is not None else None)
    for line in text.splitlines():
        if not marker.search(line):
            continue
        if display_id is None:
            if "contigua-" not in line:
                continue
        elif not unique.search(line):
            continue
        size = re.search(r"(\d+)\s*x\s*(\d+)", line)
        hz = _number(r"renderFrameRate\s+([\d.]+)", line)
        if hz is None:
            hz = _number(r"([\d.]+)\s*fps\b", line)
        if hz is None and size is None:
            return None
        return {
            "hz": hz,
            "width": int(size.group(1)) if size else None,
            "height": int(size.group(2)) if size else None,
        }
    return None


def battery(text):
    """`dumpsys battery`: level, temperature °C, voltage mV and charging."""
    level = _integer(r"\blevel:\s*(\d+)", text)
    raw_temp = _number(r"\btemperature:\s*(-?\d+)", text)
    voltage = _integer(r"\bvoltage:\s*(\d+)", text)
    powered = re.search(r"(?:AC|USB|Wireless) powered:\s*true", text) is not None
    if level is None and raw_temp is None and voltage is None and not powered:
        return None
    return {
        "level": level,
        # The platform reports deci-degrees Celsius.
        "temp_c": raw_temp / 10.0 if raw_temp is not None else None,
        "voltage": voltage,
        "charging": powered,
    }


def thermal(text):
    """`dumpsys thermalservice`: the status int and the hottest reported °C."""
    status = _integer(r"Thermal Status:\s*(-?\d+)", text)
    if status is None:
        status = _integer(r"mStatus\s*=\s*(-?\d+)", text)
    temperatures = [float(value) for value in re.findall(r"mValue\s*=\s*(-?[\d.]+)", text)]
    if status is None and not temperatures:
        return None
    return {
        "status": status,
        "max_c": max(temperatures) if temperatures else None,
    }


def cpu(text, packages=("com.example.app", "app.contigua")):
    """`dumpsys cpuinfo`: each package's share of one CPU, summed over its

    processes. A package absent from the dump is `None`, never zero.
    """
    totals = {package: None for package in packages}
    for line in text.splitlines():
        match = re.match(r"\s*([+-]?[\d.]+)%\s+\d+/(\S+)", line)
        if not match:
            continue
        name = match.group(2).rstrip(":")
        for package in packages:
            if name == package or name.startswith(package + ":"):
                value = float(match.group(1))
                totals[package] = value if totals[package] is None else totals[package] + value
    return totals


def meminfo(text):
    """`dumpsys meminfo <pkg>`: the process's TOTAL PSS in kB."""
    value = _integer(r"TOTAL PSS:\s*(\d+)", text)
    if value is None:
        value = _integer(r"^\s*TOTAL\s+(\d+)", text, re.MULTILINE)
    return value


def _wifi_field(patterns, text):
    for pattern in patterns:
        value = _number(pattern, text, re.IGNORECASE)
        if value is not None:
            return value
    return None


def wifi(text):
    """`dumpsys wifi`: numeric link facts only, never a name or address.

    `pass` says at least one numeric fact parsed; the bench marks Wi-Fi absent
    when no link data was readable. `Link speed` excludes the Tx/Rx variants.
    """
    rssi = _wifi_field([r"\bRSSI:\s*(-?\d+)", r"\brssi\s*=\s*(-?\d+)"], text)
    mbps = None
    for match in re.finditer(r"(\b(?:Tx |Rx )?Link speed:\s*(\d+)\s*Mbps)", text,
                              re.IGNORECASE):
        if not re.match(r"(?:Tx |Rx )", match.group(1), re.IGNORECASE):
            mbps = float(match.group(2))
            break
    mhz = _wifi_field([r"\bFrequency:\s*(\d+)\s*MHz", r"\bfrequency\s*=\s*(\d+)"], text)
    retries = _wifi_field([r"\btx[_ ]?retries\s*[=:]\s*(\d+)",
                           r"\bretries\s*[=:]\s*(\d+)"], text)
    bad = _wifi_field([r"\btx[_ ]?bad\s*[=:]\s*(\d+)",
                       r"\bbad\s*[=:]\s*(\d+)"], text)
    values = {
        "rssi_dbm": int(rssi) if rssi is not None else None,
        "mbps": mbps,
        "mhz": int(mhz) if mhz is not None else None,
        "retries": int(retries) if retries is not None else None,
        "bad": int(bad) if bad is not None else None,
    }
    if all(value is None for value in values.values()):
        return None
    values["pass"] = True
    return values


def first_frame_ms(logtext, stream):
    """The app's `stream N … first frame … <ms>` line, or None.

    The Mac's line is being extended to carry the elapsed milliseconds; an
    older line without a number is no measurement.
    """
    pattern = re.compile(
        r"\bstream\s+%d\b[^\n]*?\bfirst frame\b[^\n]*?(\d+(?:\.\d+)?)\s*ms" % stream)
    match = pattern.search(logtext)
    return float(match.group(1)) if match else None


def resize_ack_ms(logtext, stream):
    """The app's resize line's own milliseconds, or None.

    Accepts the `window.resize` answer (an ack or the config that settles it)
    and the note form, as long as the app logged the number on that line.
    """
    pattern = re.compile(
        r"\bstream\s+%d\b[^\n]*?\bresize\b[^\n]*?(\d+(?:\.\d+)?)\s*ms" % stream)
    match = pattern.search(logtext)
    return float(match.group(1)) if match else None
