#!/usr/bin/env python3
"""Reproducible local build. No Apple account or global tool installation required."""
import argparse
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
PIN = "2eac2e77d9c7ef8899f7a86a46e693ac5ac1a5cd"
GGML = "e705c5fed490514458bdd2eaddc43bd098fcce9b"

def run(args, **kwargs):
    print("+", " ".join(str(x) for x in args), flush=True)
    return subprocess.run([str(x) for x in args], cwd=ROOT, check=True, **kwargs)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--skip-native", action="store_true")
    parser.add_argument("--dmg", action="store_true")
    parser.add_argument("--preview", action="store_true", help="Package an isolated UI preview with separate app data")
    parser.add_argument("--sign", default="-", help="Developer ID identity; default ad-hoc for local use")
    args = parser.parse_args()
    source = ROOT / "native/parakeet.cpp"
    if not (source / "CMakeLists.txt").exists():
        if (ROOT / ".gitmodules").exists():
            run(["git", "submodule", "update", "--init", "native/parakeet.cpp"])
        else:
            run(["git", "clone", "--no-checkout", "https://github.com/mudler/parakeet.cpp.git", source])
            run(["git", "-C", source, "checkout", PIN])
    head = subprocess.check_output(["git", "-C", source, "rev-parse", "HEAD"], text=True).strip()
    if head != PIN:
        raise SystemExit(f"Runtime revision differs from lock: {head}; expected {PIN}")
    if not (source / "third_party/ggml/CMakeLists.txt").exists():
        run(["git", "-C", source, "submodule", "update", "--init", "--depth", "1", "third_party/ggml"])
    sha = subprocess.check_output(["git", "-C", source / "third_party/ggml", "rev-parse", "HEAD"], text=True).strip()
    if sha != GGML:
        raise SystemExit("ggml does not match the lock")
    if not args.skip_native:
        run(["cmake", "-S", source, "-B", ROOT / ".build/parakeet",
             "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.2",
             "-DPARAKEET_SHARED=ON", "-DBUILD_SHARED_LIBS=OFF", "-DPARAKEET_GGML_METAL=ON",
             "-DGGML_METAL_EMBED_LIBRARY=ON", "-DGGML_NATIVE=OFF", "-DPARAKEET_WITH_CED=OFF",
             "-DPARAKEET_WITH_VOICEDETECT=OFF", "-DPARAKEET_BUILD_SERVER=OFF",
             "-DPARAKEET_BUILD_CLI=OFF", "-DPARAKEET_BUILD_TESTS=OFF"])
        run(["cmake", "--build", ROOT / ".build/parakeet", "--target", "parakeet", "-j", "6"])
    config = "debug" if args.debug else "release"
    env = os.environ.copy()
    env["CLANG_MODULE_CACHE_PATH"] = str(ROOT / ".build/clang")
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(ROOT / ".build/clang")
    common = ["swift", "build", "--disable-sandbox", "--cache-path", ".build/cache", "--scratch-path", ".build/swift", "-c", config]
    run(common, env=env)
    binary_dir = Path(subprocess.check_output(common + ["--show-bin-path"], cwd=ROOT, env=env, text=True).strip())
    app = ROOT / ("dist/Verbale Preview.app" if args.preview else "dist/Verbale.app")
    if app.exists():
        shutil.rmtree(app)
    contents = app / "Contents"
    for directory in ["MacOS", "Resources", "Frameworks"]:
        (contents / directory).mkdir(parents=True)
    shutil.copy2(binary_dir / "Verbale", contents / "MacOS/Verbale")
    shutil.copy2(ROOT / "Resources/Info.plist", contents / "Info.plist")
    if args.preview:
        info = plistlib.loads((contents / "Info.plist").read_bytes())
        info["CFBundleIdentifier"] = "io.verbale.preview"
        info["CFBundleName"] = "Verbale Preview"
        info["CFBundleDisplayName"] = "Verbale Preview"
        info["VerbalePreviewDataRoot"] = str(ROOT / ".build/preview-profile")
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    shutil.copy2(ROOT / ".build/parakeet/libparakeet.dylib", contents / "Frameworks/libparakeet.dylib")
    shutil.copy2(ROOT / "Sources/VerbaleCore/Resources/models.json", contents / "Resources/models.json")
    for bundle in binary_dir.glob("*.bundle"):
        shutil.copytree(bundle, contents / "Resources" / bundle.name)
    notices = contents / "Resources/Licenses"
    notices.mkdir()
    for name, path in [("parakeet-MIT.txt", source / "LICENSE"), ("ggml-MIT.txt", source / "third_party/ggml/LICENSE"), ("models.md", source / "docs/licenses.md")]:
        shutil.copy2(path, notices / name)
    shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.md", notices / "NOTICE.md")
    shutil.copy2(source / "third_party/dr_wav.h", notices / "dr_wav-notice.h")
    lock = {"parakeet": PIN, "ggml": GGML, "features": ["CPU", "Accelerate", "Metal embedded shaders"], "excluded": ["CED", "persistent voice identification"]}
    (ROOT / "native/runtime-lock.json").write_text(json.dumps(lock, indent=2) + "\n")
    shutil.copy2(ROOT / "native/runtime-lock.json", contents / "Resources/runtime-lock.json")
    signing = ["--force", "--sign", args.sign]
    if args.sign != "-": signing += ["--options", "runtime", "--timestamp"]
    run(["codesign"] + signing + [contents / "Frameworks/libparakeet.dylib"])
    run(["codesign"] + signing + [app])
    run(["codesign", "--verify", "--deep", "--strict", app])
    if args.dmg:
        if args.preview:
            raise SystemExit("Preview builds are not distributable; omit --dmg")
        version = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]
        dmg = ROOT / f"dist/Verbale-{version}-arm64.dmg"
        if dmg.exists(): dmg.unlink()
        run(["hdiutil", "create", "-volname", "Verbale", "-srcfolder", app, "-ov", "-format", "UDZO", dmg])
    print(f"\nApp: {app}\nFirma: {'locale ad-hoc (non notarizzata)' if args.sign == '-' else args.sign}")

if __name__ == "__main__":
    main()
