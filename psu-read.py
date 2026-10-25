#!/usr/bin/env python3
"""Streams a Corsair i-series power supply's readings as one JSON object per line.

The kernel's corsairpsu driver exposes the PSU over USB HID as an hwmon device.
Every value is a USB transaction (about 3 ms each), so reading the whole set
takes roughly 45 ms: far too long to do on the shell's UI thread without
stuttering animations. This helper does the reading in its own process and the
shell only parses the lines it prints.

Lines, by "type":
  info    once at the start: model, rated watts and the driver's protection limits
  sample  every interval (full mode): every rail, both temperatures, fan, line voltage
  bar     every interval (--bar mode): total power, each rail's power and the temperatures,
          six reads, so the chart has history from before the panel was opened
  absent  the device is not there (unplugged, or driver not loaded); retried every 5 s

Run as `python3 -I psu-read.py [--bar] [--interval SECONDS]`. Read-only, no root.
"""

import glob
import json
import os
import re
import sys
import time

HWMON = "/sys/class/hwmon"

# hwmon labels the driver uses -> the short keys everything downstream uses.
RAILS = {"+12v": "12v", "+5v": "5v", "+3.3v": "3v3"}


def read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def read_number(path):
    text = read(path)
    try:
        return int(text)
    except ValueError:
        return None


def find_device():
    for directory in sorted(glob.glob(HWMON + "/hwmon*")):
        if read(directory + "/name") == "corsairpsu":
            return directory
    return ""


def usb_identity(hw):
    """(vendor, product) strings from the USB device above the hwmon node."""
    path = os.path.realpath(hw + "/device")
    for _ in range(8):
        product = os.path.join(path, "product")
        if os.path.exists(product):
            return read(os.path.join(path, "manufacturer")), read(product)
        path = os.path.dirname(path)
    return "", ""


def channels(hw):
    """Map each label ("power total", "v_out +12v", ...) to its hwmon prefix (power1, in1, ...).
    Looked up by label, never by number: hwmon numbering is the driver's business."""
    found = {}
    for label_path in glob.glob(hw + "/*_label"):
        prefix = os.path.basename(label_path)[: -len("_label")]
        found[read(label_path).lower()] = prefix
    return found


def rail_of(label):
    for suffix, key in RAILS.items():
        if label.endswith(suffix):
            return key
    return None


def scaled(hw, prefix, divisor, suffix="_input"):
    if not prefix:
        return None
    raw = read_number("%s/%s%s" % (hw, prefix, suffix))
    return None if raw is None else raw / divisor


def rated_watts(product):
    """1200 from 'HX1200i Power Supply'. 0 when the name carries no rating."""
    match = re.search(r"(\d{3,4})", product or "")
    value = int(match.group(1)) if match else 0
    return value if 300 <= value <= 2400 else 0


def info(hw):
    vendor, product = usb_identity(hw)
    ch = channels(hw)
    limits = {"volts": {}, "amps": {}, "temp": 0}
    for label, prefix in ch.items():
        key = rail_of(label)
        if key and label.startswith("v_out"):
            limits["volts"][key] = {
                "min": scaled(hw, prefix, 1000, "_lcrit"),
                "max": scaled(hw, prefix, 1000, "_crit"),
            }
        elif key and label.startswith("curr"):
            limits["amps"][key] = scaled(hw, prefix, 1000, "_crit")
    limits["temp"] = scaled(hw, ch.get("vrm temp"), 1000, "_crit") or scaled(hw, ch.get("case temp"), 1000, "_crit") or 0
    model = re.sub(r"\s*Power Supply\s*$", "", product or "", flags=re.I).strip()
    return {"type": "info", "vendor": vendor.title()[:24], "model": model[:32], "ratedW": rated_watts(product), "limits": limits}


def sample(hw, ch):
    watts, volts, amps = {}, {}, {}
    for label, prefix in ch.items():
        key = rail_of(label)
        if key and label.startswith("power"):
            watts[key] = scaled(hw, prefix, 1e6)
        elif key and label.startswith("v_out"):
            volts[key] = scaled(hw, prefix, 1000)
        elif key and label.startswith("curr"):
            amps[key] = scaled(hw, prefix, 1000)
    pwm = read_number(hw + "/pwm1")
    return {
        "type": "sample",
        "t": int(time.time() * 1000),
        "vin": scaled(hw, ch.get("v_in"), 1000),
        "w": dict(watts, total=scaled(hw, ch.get("power total"), 1e6)),
        "v": volts,
        "a": amps,
        "vrm": scaled(hw, ch.get("vrm temp"), 1000),
        "case": scaled(hw, ch.get("case temp"), 1000),
        "fan": scaled(hw, ch.get("psu fan"), 1),
        "duty": None if pwm is None else round(pwm * 100 / 255, 1),
    }


def bar(hw, ch):
    rails = {}
    for label, prefix in ch.items():
        key = rail_of(label)
        if key and label.startswith("power"):
            rails[key] = scaled(hw, prefix, 1e6)
    return {
        "type": "bar",
        "t": int(time.time() * 1000),
        "w": scaled(hw, ch.get("power total"), 1e6),
        "r": rails,
        "vrm": scaled(hw, ch.get("vrm temp"), 1000),
        "case": scaled(hw, ch.get("case temp"), 1000),
    }


def emit(obj):
    print(json.dumps(obj, separators=(",", ":")), flush=True)


def main():
    args = sys.argv[1:]
    bar_mode = "--bar" in args
    interval = 1.0
    if "--interval" in args:
        try:
            interval = max(0.25, min(60.0, float(args[args.index("--interval") + 1])))
        except (IndexError, ValueError):
            pass

    hw, ch = "", {}
    announced_absent = False
    while True:
        started = time.time()
        if not hw or not os.path.isdir(hw):
            hw = find_device()
            if hw:
                ch = channels(hw)
                emit(info(hw))
                announced_absent = False
        if hw:
            try:
                emit(bar(hw, ch) if bar_mode else sample(hw, ch))
            except OSError:
                hw = ""
        if not hw:
            if not announced_absent:
                emit({"type": "absent"})
                announced_absent = True
            time.sleep(5)
            continue
        time.sleep(max(0.05, interval - (time.time() - started)))


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
