#!/usr/bin/env python3
"""Shared build environment checks for build.py and test.sh.

Run directly, it prints the SDK path to export as SDKROOT (empty when the
default SDK works or SDKROOT is already set).
"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

PROBE = 'import SwiftUI\nstruct Probe: View { @State private var value = 0\n var body: some View { Text("\\(value)") } }\n'


def _typechecks(sdk):
    """True when SwiftUI property-wrapper macros resolve against this SDK."""
    with tempfile.TemporaryDirectory(prefix="verbale-sdk-probe-") as directory:
        source = Path(directory) / "probe.swift"
        source.write_text(PROBE)
        command = ["swiftc", "-typecheck", str(source)] + (["-sdk", str(sdk)] if sdk else [])
        return subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def _version(sdk):
    return tuple(int(part) for part in re.findall(r"\d+", sdk.name))


def sdkroot():
    """Return an SDK to use instead of the default one, or None.

    Command Line Tools can ship a default SDK whose SwiftUI needs the
    SwiftUIMacros compiler plugin, which only Xcode provides. In that case
    fall back to the newest installed SDK that still compiles SwiftUI code.
    An explicit SDKROOT is always respected.
    """
    if os.environ.get("SDKROOT") or sys.platform != "darwin":
        return None
    if _typechecks(None):
        return None
    try:
        default = Path(subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()).resolve()
    except (OSError, subprocess.CalledProcessError):
        return None
    candidates = {path.resolve() for path in default.parent.glob("MacOSX*.sdk")} - {default}
    for candidate in sorted(candidates, key=_version, reverse=True):
        if _typechecks(candidate):
            print(f"Nota: l'SDK predefinito {default.name} non compila SwiftUI con questa toolchain "
                  f"(plugin SwiftUIMacros assente); uso {candidate.name}. "
                  "Installa Xcode o imposta SDKROOT per scegliere diversamente.", file=sys.stderr)
            return candidate
    raise SystemExit(f"Nessun SDK installato compila SwiftUI: {default.name} richiede il plugin SwiftUIMacros. "
                     "Installa Xcode oppure un SDK macOS precedente dei Command Line Tools.")


def apply_sdkroot(env=None):
    """Set SDKROOT in env (default: os.environ) when a fallback is needed."""
    env = os.environ if env is None else env
    sdk = sdkroot()
    if sdk:
        env["SDKROOT"] = str(sdk)
    return env


if __name__ == "__main__":
    print(sdkroot() or "")
