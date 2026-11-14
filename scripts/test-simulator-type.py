#!/usr/bin/env python3
"""Pick a device type and runtime for the test simulator.

Reads `simctl list runtimes -j` on stdin and prints "<deviceTypeId> <runtimeId>",
or nothing when no available runtime offers an iPhone.

Why this and not `simctl list devicetypes` or the existing devices:

  * `devicetypes` lists types whose runtime has since been removed, and
    `simctl create` refuses those ("Could not find an available runtime"). Its
    line format also wraps the identifier in parentheses, which a naive capture
    keeps.
  * A list of existing DEVICES is empty on a machine that has never booted one,
    which is exactly the fresh checkout this lookup exists for, and still counts
    orphans on removed runtimes.

So the answer comes from an available runtime's own `supportedDeviceTypes`, and
the runtime is printed with it so `simctl create` receives the pair that was
actually chosen rather than resolving either half again.
"""
import json
import sys


def version_key(runtime):
    parts = []
    for piece in str(runtime.get("version", "")).split("."):
        parts.append(int(piece) if piece.isdigit() else 0)
    return parts


def main():
    try:
        runtimes = json.load(sys.stdin).get("runtimes", [])
    except (json.JSONDecodeError, ValueError):
        # Unreadable input is "nothing to offer", not a crash: the caller prints a
        # clear error naming the device it could not create, which is more useful
        # than a stack trace from here.
        return 0
    available = [
        r for r in runtimes
        if r.get("isAvailable") and "iOS" in r.get("identifier", "")
    ]
    # Newest runtime first: an old one may be installed but unable to host the
    # types the installed Xcode expects.
    available.sort(key=version_key, reverse=True)
    for runtime in available:
        for device_type in runtime.get("supportedDeviceTypes", []):
            if device_type.get("productFamily") == "iPhone":
                print(f"{device_type['identifier']} {runtime['identifier']}")
                return
    return 0


if __name__ == "__main__":
    sys.exit(main())
