"""Archive regression tests using small structural IPA fixtures, no Xcode required."""

import io
from pathlib import Path
import plistlib
import runpy
import struct
import tempfile
import unittest
import warnings
import zipfile

verify = runpy.run_path(str(Path(__file__).with_name("verify-ipa.py")))["verify_ipa"]
package = runpy.run_path(str(Path(__file__).with_name("package-ipa.py")))["package_app"]
ROOT = "Payload/PloitSatellite.app/"


def macho(platform=2, cpu=0x0100000C):
    return struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0) + struct.pack("<6I", 0x32, 24, platform, 0x110000, 0x1A0000, 0)


def fixture(fmt=plistlib.FMT_XML):
    info = {"CFBundleIdentifier": "ru.ploit.satellite", "CFBundleExecutable": "PloitSatellite",
            "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "CFBundleShortVersionString": "1.3.8", "NSLocationWhenInUseUsageDescription": "Position",
            "NSMotionUsageDescription": "Aim", "CADisableMinimumFrameDurationOnPhone": True}
    entries = [(ROOT + "Info.plist", plistlib.dumps(info, fmt=fmt)), (ROOT + "PloitSatellite", macho())]
    entries += [(ROOT + name, b"resource") for name in ("catalog.json", "seed-tle.json", "satellite.min.js", "orbit.js", "earth-night.jpg", "earth-day.jpg")]
    return entries


def archive(entries):
    data = io.BytesIO()
    with warnings.catch_warnings(), zipfile.ZipFile(data, "w", compression=zipfile.ZIP_STORED) as output:
        warnings.simplefilter("ignore", UserWarning)
        for name, content in entries:
            output.writestr(name, content)
    data.seek(0)
    return data


class IPATests(unittest.TestCase):
    def test_xml_and_binary_plists_are_valid(self):
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            with self.subTest(format=fmt):
                result = verify(archive(fixture(fmt)))
                self.assertTrue(result["ipa_verified"])
                self.assertTrue(result["crc_verified"])
                self.assertFalse(result["signed"])

    def test_missing_files_are_rejected(self):
        for missing in ("Info.plist", "PloitSatellite", "orbit.js"):
            with self.subTest(missing=missing), self.assertRaises(ValueError):
                verify(archive([(n, c) for n, c in fixture() if n != ROOT + missing]))

    def test_duplicate_plist_and_case_collisions_are_rejected(self):
        for name in (ROOT + "Info.plist", ROOT + "info.plist"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "Duplicate"):
                verify(archive(fixture() + [(name, b"ambiguous metadata")]))

    def test_noncanonical_paths_and_extra_apps_are_rejected(self):
        for name in ("../escape", "/Payload/extra", "Payload\\extra", "Payload/PloitSatellite.app/../outside",
                     "Payload/PloitSatellite.app//extra", "Payload/PloitSatellite.app/extra//",
                     "__MACOSX/extra", "Payload/Other.app/Info.plist", ROOT + "orbit.js/child"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                verify(archive(fixture() + [(name, b"data")]))

    def test_crc_damage_is_rejected(self):
        data = bytearray(archive(fixture()).getvalue())
        offset = data.index(b"resource")
        data[offset] ^= 1
        with self.assertRaisesRegex(ValueError, "CRC"):
            verify(io.BytesIO(data))

    def test_truncated_zip_is_rejected(self):
        with self.assertRaises(zipfile.BadZipFile):
            verify(io.BytesIO(archive(fixture()).getvalue()[:-32]))

    def test_simulator_wrong_cpu_and_malformed_commands_are_rejected(self):
        bad_size = bytearray(macho()); struct.pack_into("<I", bad_size, 36, 0)
        binaries = [macho(platform=7), macho(platform=1), macho(cpu=0x01000007), macho()[:12], bytes(bad_size)]
        for binary in binaries:
            with self.subTest(binary=binary.hex()), self.assertRaises(ValueError):
                verify(archive([(n, binary if n == ROOT + "PloitSatellite" else c) for n, c in fixture()]))

    def test_bundle_executable_path_cannot_escape(self):
        entries = fixture()
        info = plistlib.loads(entries[0][1]); info["CFBundleExecutable"] = "../Other.app/executable"
        entries[0] = (entries[0][0], plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "CFBundleExecutable"):
            verify(archive(entries))

    def test_corrupt_plist_is_rejected(self):
        entries = fixture(); entries[0] = (entries[0][0], b"not a plist")
        with self.assertRaises(plistlib.InvalidFileException):
            verify(archive(entries))

    def test_packaging_preserves_bundle_and_nested_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            app = folder / "PloitSatellite.app"
            entries = fixture(plistlib.FMT_BINARY) + [(ROOT + "en.lproj/help.txt", b"nested resource")]
            for name, content in entries:
                path = app / name.removeprefix(ROOT)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            output = folder / "test.ipa"
            package(app, output)
            self.assertTrue(verify(output)["ipa_verified"])
            with zipfile.ZipFile(output) as result:
                for name, content in entries:
                    if name == ROOT + "Info.plist":
                        self.assertEqual(plistlib.loads(content), plistlib.loads(result.read(name)))
                        self.assertTrue(result.read(name).startswith(b"<?xml"))
                        self.assertLess(result.getinfo(name).header_offset, 1024)
                        self.assertEqual(result.getinfo(name).compress_type, zipfile.ZIP_STORED)
                    else:
                        self.assertEqual(content, result.read(name))
                self.assertEqual((result.getinfo(ROOT + "PloitSatellite").external_attr >> 16) & 0o777, 0o755)
            second = folder / "second.ipa"
            package(app, second)
            self.assertEqual(output.read_bytes(), second.read_bytes())

    def test_packaging_refuses_existing_signature(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            app = folder / "PloitSatellite.app"
            (app / "_CodeSignature").mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, "unsigned"):
                package(app, folder / "test.ipa")


if __name__ == "__main__":
    unittest.main()
