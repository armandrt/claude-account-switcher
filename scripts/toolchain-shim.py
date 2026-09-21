#!/usr/bin/env python3
"""Generate a swiftc shim that repairs an inconsistent Command Line Tools install.

Some CLT installs fail a plain `swift build` in four ways: a duplicate
`module SwiftBridging` modulemap, SDK .swiftinterface files stamped by an older
compiler than the installed one, a stale PackageDescription private interface
beside a current public one, and a Testing cross-import overlay whose module
does not exist.  Each is masked read-only through a clang/swift VFS overlay;
nothing under /Library is touched.  On a healthy toolchain the shim is a plain
pass-through.

Output: .build-toolchain/{shadow,overlay.yaml,swiftc,compiler-version}
"""
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, ".build-toolchain")


def sh(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True).stdout.strip()
    except OSError:
        return ""


def compiler_version():
    """(first line of --version, swift version, swiftlang, clang)."""
    out = sh("xcrun", "swift-frontend", "--version") or sh("swift", "--version")
    m = re.search(r"Apple Swift version ([0-9.]+).*?\(swiftlang-([0-9.]+) clang-([0-9.]+)\)", out)
    if not m:
        sys.exit("toolchain-shim: no Swift compiler found, or its version is unreadable: %r" % out)
    return out.split("\n", 1)[0], m.group(1), m.group(2), m.group(3)


def patched_line(line, ver, swiftlang, clang):
    line = re.sub(r"Apple Swift version [0-9.]+", "Apple Swift version " + ver, line)
    line = re.sub(r"swiftlang-[0-9.]+", "swiftlang-" + swiftlang, line)
    line = re.sub(r"clang-[0-9.]+", "clang-" + clang, line)
    return line


def main():
    clt = sh("xcode-select", "-p") or "/Library/Developer/CommandLineTools"
    sdk = sh("xcrun", "--show-sdk-path")
    if not sdk or not os.path.isdir(sdk):
        sys.exit("toolchain-shim: no macOS SDK found (xcrun --show-sdk-path)")
    real_sdk = os.path.realpath(sdk)
    stamp, ver, swiftlang, clang = compiler_version()

    shadow = os.path.join(OUT, "shadow")
    os.makedirs(shadow, exist_ok=True)
    roots = []

    # The overlay matches the literal path the compiler was handed, so every
    # symlink to the SDK (MacOSX.sdk -> MacOSX26.2.sdk) needs its own entry.
    sdk_dir = os.path.dirname(real_sdk)
    aliases = [os.path.join(sdk_dir, n) for n in os.listdir(sdk_dir)
               if os.path.islink(os.path.join(sdk_dir, n))
               and os.path.realpath(os.path.join(sdk_dir, n)) == real_sdk]

    # SDK interfaces stamped by a different compiler version.
    patched = 0
    for dirpath, _, files in os.walk(real_sdk):
        for fn in files:
            if not fn.endswith(".swiftinterface"):
                continue
            src = os.path.join(dirpath, fn)
            try:
                with open(src, "r", errors="replace") as f:
                    text = f.read()
            except OSError:
                continue
            lines = text.split("\n")
            hit = False
            for i, line in enumerate(lines[:4]):
                if line.startswith("// swift-compiler-version:"):
                    new = patched_line(line, ver, swiftlang, clang)
                    if new != line:
                        lines[i] = new
                        hit = True
                    break
            if not hit:
                continue
            dst = os.path.join(shadow, os.path.relpath(src, "/"))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, "w") as f:
                f.write("\n".join(lines))
            patched += 1
            for base in [real_sdk] + aliases:
                roots.append({"type": "file",
                              "name": base + src[len(real_sdk):],
                              "external-contents": dst})
    if patched:
        print("toolchain-shim: patched %d SDK interfaces (%s)" % (patched, ver))

    # Two modulemaps defining the same module in the same directory.
    inc = os.path.join(clt, "usr/include/swift")
    mm, bm = os.path.join(inc, "module.modulemap"), os.path.join(inc, "bridging.modulemap")
    if os.path.exists(mm) and os.path.exists(bm):
        empty = os.path.join(OUT, "empty.modulemap")
        with open(empty, "w") as f:
            f.write("// masked by scripts/toolchain-shim.py\n")
        roots.append({"type": "file", "name": mm, "external-contents": empty})
        print("toolchain-shim: masking the duplicate %s" % mm)

    # A stale PackageDescription private interface beside a current public one.
    pm = os.path.join(clt, "usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule")
    if os.path.isdir(pm):
        for fn in sorted(os.listdir(pm)):
            if not fn.endswith(".private.swiftinterface"):
                continue
            pub = os.path.join(pm, fn.replace(".private.swiftinterface", ".swiftinterface"))
            if os.path.exists(pub):
                roots.append({"type": "file", "name": os.path.join(pm, fn),
                              "external-contents": pub})
                print("toolchain-shim: redirecting stale %s" % fn)

    # A cross-import overlay declared by Testing.framework whose module is missing.
    frameworks = os.path.join(clt, "Library/Developer/Frameworks")
    if os.path.isdir(frameworks):
        empty_overlay = os.path.join(OUT, "empty.swiftoverlay")
        with open(empty_overlay, "w") as f:
            f.write("version: 1\nmodules: []\n")
        for dirpath, _, files in os.walk(frameworks):
            if not dirpath.endswith(".swiftcrossimport"):
                continue
            for fn in files:
                if not fn.endswith(".swiftoverlay"):
                    continue
                decl = os.path.join(dirpath, fn)
                with open(decl) as f:
                    names = re.findall(r"^\s*-\s*name:\s*(\S+)", f.read(), re.M)
                missing = [n for n in names if not os.path.isdir(
                    os.path.join(frameworks, n + ".framework/Versions/A/Modules/" + n + ".swiftmodule"))]
                if not missing:
                    continue
                # Reachable through the framework's Modules symlinks as well.
                variants = {decl}
                if "/Versions/A/Modules/" in decl:
                    variants.add(decl.replace("/Versions/A/Modules/", "/Modules/"))
                    variants.add(decl.replace("/Versions/A/Modules/", "/Versions/Current/Modules/"))
                for variant in sorted(variants):
                    roots.append({"type": "file", "name": variant,
                                  "external-contents": empty_overlay})
                print("toolchain-shim: masking cross-import overlay %s (no module for %s)"
                      % (os.path.basename(decl), ", ".join(missing)))

    swiftc = sh("xcrun", "-f", "swiftc") or "/usr/bin/swiftc"
    shim = os.path.join(OUT, "swiftc")
    if roots:
        overlay = os.path.join(OUT, "overlay.yaml")
        with open(overlay, "w") as f:
            json.dump({"version": 0, "case-sensitive": False, "roots": roots}, f, indent=1)
        # The frontend keeps only the last -vfsoverlay, so ours goes after SwiftPM's flags.
        body = 'exec "%s" "$@" -vfsoverlay "%s" -Xcc -ivfsoverlay -Xcc "%s"\n' % (swiftc, overlay, overlay)
        print("toolchain-shim: %s (%d overlay entries)" % (shim, len(roots)))
    else:
        body = 'exec "%s" "$@"\n' % swiftc
        print("toolchain-shim: toolchain looks consistent, %s is a pass-through" % shim)
    with open(shim, "w") as f:
        f.write("#!/bin/sh\n# generated by scripts/toolchain-shim.py\n" + body)
    os.chmod(shim, 0o755)
    with open(os.path.join(OUT, "compiler-version"), "w") as f:
        f.write(stamp)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        if sys.argv[1] in ("-h", "--help"):
            print("usage: scripts/toolchain-shim.py\n")
            print(__doc__.strip())
            raise SystemExit(0)
        raise SystemExit("toolchain-shim: unknown argument: %s (try --help)" % sys.argv[1])
    main()
