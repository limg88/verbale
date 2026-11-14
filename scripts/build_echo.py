#!/usr/bin/env python3
"""Build the pinned standalone WebRTC AEC3 and Verbale's C ABI adapter."""
from pathlib import Path
import subprocess

from buildenv import reset_stale_cmake

ROOT = Path(__file__).resolve().parent.parent
PIN = "2cec2f52e26646f93bd2d5498bbabf59cba18da9"

def run(*args):
    subprocess.run([str(x) for x in args], cwd=ROOT, check=True)

def main():
    source = ROOT / "native/webrtc-aec3"
    if not (source / "CMakeLists.txt").exists():
        if (ROOT / ".gitmodules").exists():
            run("git", "submodule", "update", "--init", "native/webrtc-aec3")
        else:
            run("git", "clone", "--no-checkout", "https://github.com/Enaium/webrtc-aec3.git", source)
            run("git", "-C", source, "checkout", PIN)
    revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if revision != PIN:
        raise SystemExit(f"AEC revision differs from lock: {revision}; expected {PIN}")
    reset_stale_cmake(ROOT / ".build/echo", ROOT / "native/echo")
    run("cmake", "-S", ROOT / "native/echo", "-B", ROOT / ".build/echo", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.2", "-DBUILD_TESTS=OFF")
    run("cmake", "--build", ROOT / ".build/echo", "-j", "6")

if __name__ == "__main__":
    main()
