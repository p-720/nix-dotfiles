#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p "python3.withPackages (ps: [ ps.evdev ])"

import sys
from evdev import InputDevice, UInput, AbsInfo, ecodes as e

import sys
from evdev import InputDevice, list_devices, ecodes as e

def find_touch_device():
    # 1. Allow passing path via command line: sudo ./remap.py /dev/input/eventX
    if len(sys.argv) > 1:
        return sys.argv[1]

    # 2. Otherwise scan /dev/input/ for the exact physical Sunshine device
    for path in list_devices():
        try:
            dev = InputDevice(path)
            # Match the raw Sunshine device name, but ignore our own virtual uinput device
            if "touch passthrough" in dev.name.lower() and "calibrated" not in dev.name.lower():
                print(f"Found dynamic Sunshine input node: {dev.name} at {path}")
                return path
        except (PermissionError, OSError):
            continue
    return None

DEV_PATH = find_touch_device()

if not DEV_PATH:
    print("Error: Could not find raw 'Touch passthrough' device.")
    sys.exit(1)

# Measured raw physical touch bounds
RAW_MIN_X = 42
RAW_MAX_X = 7626
RAW_MIN_Y = 5
RAW_MAX_Y = 5350

# Target display/compositor resolution
TARGET_MAX_X = 19200
TARGET_MAX_Y = 10800

try:
    dev = InputDevice(DEV_PATH)
except FileNotFoundError:
    print(f"Error: Could not open {DEV_PATH}.")
    sys.exit(1)

# Grab device capabilities
cap = {
    e.EV_KEY: [e.BTN_TOUCH, e.BTN_LEFT],
    e.EV_ABS: [
        (e.ABS_X, AbsInfo(value=0, min=0, max=TARGET_MAX_X, fuzz=0, flat=0, resolution=0)),
        (e.ABS_Y, AbsInfo(value=0, min=0, max=TARGET_MAX_Y, fuzz=0, flat=0, resolution=0)),
        (e.ABS_MT_POSITION_X, AbsInfo(value=0, min=0, max=TARGET_MAX_X, fuzz=0, flat=0, resolution=0)),
        (e.ABS_MT_POSITION_Y, AbsInfo(value=0, min=0, max=TARGET_MAX_Y, fuzz=0, flat=0, resolution=0)),
        (e.ABS_MT_SLOT, AbsInfo(value=0, min=0, max=9, fuzz=0, flat=0, resolution=0)),
        (e.ABS_MT_TRACKING_ID, AbsInfo(value=0, min=0, max=65535, fuzz=0, flat=0, resolution=0)),
    ]
}

# Grab physical device grabbing to prevent duplicate touches
try:
    dev.grab()
    print(f"Successfully grabbed physical input device {DEV_PATH}")
except OSError:
    print(f"Warning: Could not grab {DEV_PATH}. Duplicate touch events may register.")

ui = UInput(cap, name="Calibrated Touch Passthrough")
print(f"Remapping raw touches from {dev.name}...")

def scale_axis(val, raw_min, raw_max, target_max):
    # Normalized ratio (0.0 to 1.0)
    norm = (val - raw_min) / (raw_max - raw_min)
    # Clamp ratio between 0.0 and 1.0 to prevent out-of-bounds overflow
    norm_clamped = max(0.0, min(1.0, norm))
    return int(norm_clamped * target_max)

try:
    for event in dev.read_loop():
        if event.type == e.EV_ABS:
            if event.code in (e.ABS_X, e.ABS_MT_POSITION_X):
                event.value = scale_axis(event.value, RAW_MIN_X, RAW_MAX_X, TARGET_MAX_X)
            elif event.code in (e.ABS_Y, e.ABS_MT_POSITION_Y):
                event.value = scale_axis(event.value, RAW_MIN_Y, RAW_MAX_Y, TARGET_MAX_Y)

        ui.write_event(event)
except KeyboardInterrupt:
    print("\nExiting and ungrabbing device...")
    dev.ungrab()
