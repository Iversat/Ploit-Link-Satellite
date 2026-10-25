"""Validate the archive, bundle metadata and device executable before release."""

import argparse
import json
import plistlib
import stat
import struct
import zipfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_macho(binary):
    """Require ARM64 executable slices built for iOS devices, not Simulator."""
    slices = [(0, len(binary))]
    if binary[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        require(len(binary) >= 8, "Truncated universal Mach-O header")
        count = struct.unpack_from(">I", binary, 4)[0]
        wide = binary[:4] == b"\xca\xfe\xba\xbf"
        size = 32 if wide else 20
        require(0 < count <= 32 and 8 + count * size <= len(binary), "Invalid universal Mach-O table")
        slices = []
        for i in range(count):
            values = struct.unpack_from(">IIQQII" if wide else ">IIIII", binary, 8 + i * size)
            cpu, _, offset, length = values[:4]
            require(cpu == 0x0100000C, "Universal Mach-O contains a non-ARM64 slice")
            require(offset >= 8 + count * size and length >= 32 and offset + length <= len(binary), "Invalid Mach-O slice bounds")
            require(all(offset + length <= a or offset >= a + b for a, b in slices), "Overlapping Mach-O slices")
            slices.append((offset, length))
    signed = False
    for start, length in slices:
        require(length >= 32 and binary[start:start + 4] == b"\xcf\xfa\xed\xfe", "Expected a 64-bit little-endian Mach-O executable")
        _, cpu, _, kind, commands, command_bytes, _, _ = struct.unpack_from("<8I", binary, start)
        require(cpu == 0x0100000C and kind == 2, "Expected an ARM64 MH_EXECUTE binary")
        require(commands > 0 and commands <= command_bytes // 8 and 32 + command_bytes <= length, "Invalid Mach-O load-command bounds")
        offset, end = start + 32, start + 32 + command_bytes
        platforms = []
        for _ in range(commands):
            require(offset + 8 <= end, "Truncated Mach-O load command")
            command, size = struct.unpack_from("<II", binary, offset)
            require(size >= 8 and size % 8 == 0 and offset + size <= end, "Invalid Mach-O load-command size")
            if command == 0x32:  # LC_BUILD_VERSION
                require(size >= 24, "Truncated LC_BUILD_VERSION")
                platform, _, _, tools = struct.unpack_from("<4I", binary, offset + 8)
                require(24 + tools * 8 <= size, "Invalid LC_BUILD_VERSION tools")
                platforms.append(platform)
            if command == 0x1D:  # LC_CODE_SIGNATURE
                require(size >= 16, "Truncated LC_CODE_SIGNATURE")
                data_offset, data_size = struct.unpack_from("<II", binary, offset + 8)
                require(data_offset + data_size <= length, "Invalid code-signature bounds")
                signed |= data_size > 0
            offset += size
        require(offset == end, "Mach-O load-command size mismatch")
        require(platforms == [2], "Executable must target the iOS device platform (2)")
    return signed


def verify_ipa(path):
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        require(entries, "Empty IPA archive")
        names, folded, roots, files = set(), set(), set(), set()
        for entry in entries:
            name = entry.filename
            parts = (name[:-1] if name.endswith("/") else name).split("/")
            require(name and "\\" not in name and "\x00" not in name and all(p not in ("", ".", "..") for p in parts), "Non-canonical ZIP path: " + repr(name))
            canonical = name.rstrip("/")
            require(canonical not in names and canonical.casefold() not in folded, "Duplicate or conflicting ZIP path: " + name)
            names.add(canonical); folded.add(canonical.casefold())
            require(parts[0] == "Payload", "IPA entries must be rooted at Payload/")
            if len(parts) == 1:
                require(entry.is_dir(), "Payload must be a directory")
            else:
                require(parts[1].endswith(".app") and len(parts[1]) > 4, "Expected Payload/<name>.app/")
                roots.add(parts[1])
                require(len(parts) > 2 or entry.is_dir(), "App bundle must be a directory")
            require(not (entry.flag_bits & 1), "Encrypted ZIP entries are unsupported")
            require(not stat.S_ISLNK(entry.external_attr >> 16), "Symbolic links are unsupported")
            if not entry.is_dir():
                files.add(canonical)
        require(len(roots) == 1, "IPA must contain exactly one top-level app bundle")
        for name in names:
            parts = name.split("/")
            require(all("/".join(parts[:i]) not in files for i in range(1, len(parts))), "File is also used as a directory: " + name)
        require(archive.testzip() is None, "IPA CRC verification failed")
        prefix = "Payload/" + next(iter(roots)) + "/"
        require(prefix + "Info.plist" in files, "Missing app Info.plist")
        plist = plistlib.loads(archive.read(prefix + "Info.plist"))
        require(isinstance(plist, dict), "Info.plist must be a dictionary")
        require(plist.get("CFBundleIdentifier") == "ru.ploit.satellite", "Unexpected bundle identifier")
        require(plist.get("CFBundlePackageType") == "APPL", "Bundle is not an application")
        require(plist.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "Info.plist does not target iPhoneOS")
        executable = plist.get("CFBundleExecutable")
        require(isinstance(executable, str) and executable not in ("", ".", "..") and "/" not in executable and "\\" not in executable, "Invalid CFBundleExecutable")
        require(prefix + executable in files, "Missing app executable")
        binary = archive.read(prefix + executable)
        signed = verify_macho(binary)
        signed |= any(name.startswith(prefix + "_CodeSignature/") for name in files)
        for name in ("catalog.json", "seed-tle.json", "satellite.min.js", "orbit.js", "earth-night.jpg", "earth-day.jpg"):
            require(prefix + name in files and len(archive.read(prefix + name)) > 0, "Missing or empty resource: " + name)
        for key in ("NSLocationWhenInUseUsageDescription", "NSMotionUsageDescription"):
            require(isinstance(plist.get(key), str) and plist[key].strip(), "Missing usage description: " + key)
        require(plist.get("CADisableMinimumFrameDurationOnPhone") is True, "Missing ProMotion configuration")
        version = tuple(int(part) for part in str(plist.get("CFBundleShortVersionString", "0")).split("."))
        sky_model = any(name.startswith(prefix + "SkyScene.mlmodelc/") for name in files)
        if version >= (1, 7, 0):
            require(sky_model, "Missing compiled on-device SkyScene model")
            require(any(name.startswith(prefix + "SkyScene.mlmodelc/") and archive.getinfo(name).file_size > 1_000_000
                        for name in files), "Compiled SkyScene model is missing its weights")
            require(isinstance(plist.get("NSCameraUsageDescription"), str), "Missing camera usage description")
            require(prefix + "MMSegmentation-Apache-2.0.txt" in files, "Missing model license")
        return {"ipa_verified": True, "bundle": plist["CFBundleIdentifier"], "version": plist.get("CFBundleShortVersionString"),
                "executable_bytes": len(binary), "platform": "arm64 iOS device", "crc_verified": True,
                "sky_model_bundled": sky_model, "signed": bool(signed)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa")
    args = parser.parse_args()
    try:
        print(json.dumps(verify_ipa(args.ipa)))
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, plistlib.InvalidFileException, struct.error) as error:
        parser.exit(1, "IPA verification failed: " + str(error) + "\n")
