"""Package an unsigned device .app with importer-friendly ZIP metadata."""

import argparse
import os
from pathlib import Path
import plistlib
import stat
import zipfile


def package_app(app: Path, output: Path) -> None:
    app = app.resolve()
    if app.suffix != ".app" or not app.is_dir():
        raise ValueError("Input must be an existing .app directory")
    if (app / "_CodeSignature").exists() or (app / "embedded.mobileprovision").exists():
        raise ValueError("Input must be unsigned; plist conversion invalidates existing signatures")
    plist_path = app / "Info.plist"
    plist = plistlib.loads(plist_path.read_bytes())
    executable = plist["CFBundleExecutable"]
    if Path(executable).name != executable or not (app / executable).is_file():
        raise ValueError("Missing or invalid CFBundleExecutable")
    if plist.get("CFBundlePackageType") != "APPL":
        raise ValueError("Input is not an application bundle")
    if plist.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
        raise ValueError("Expected an iPhoneOS device build")
    entries = sorted(app.rglob("*"))
    if any(path.is_symlink() for path in entries):
        raise ValueError("Symbolic links are not supported by this packager")
    if output.resolve().is_relative_to(app):
        raise ValueError("Output must be outside the app bundle")

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    root = f"Payload/{app.name}/"
    try:
        with zipfile.ZipFile(temporary, "w", allowZip64=False) as archive:
            def write(name, data=b"", *, directory=False, executable=False, stored=False):
                entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                entry.create_system = 3
                mode = (stat.S_IFDIR | 0o755) if directory else (stat.S_IFREG | (0o755 if executable else 0o644))
                entry.external_attr = (mode << 16) | (0x10 if directory else 0)
                entry.compress_type = zipfile.ZIP_STORED if directory or stored else zipfile.ZIP_DEFLATED
                archive.writestr(entry, data, compresslevel=6)

            write("Payload/", directory=True)
            write(root, directory=True)
            # Keep bundle discovery independent of the first file, and expose the
            # XML dictionary before large textures for streaming IPA importers.
            if (app / "PkgInfo").is_file():
                write(root + "PkgInfo", (app / "PkgInfo").read_bytes(), stored=True)
            write(root + "Info.plist", plistlib.dumps(plist, fmt=plistlib.FMT_XML), stored=True)
            for path in entries:
                relative = path.relative_to(app).as_posix()
                if relative in {"Info.plist", "PkgInfo"}:
                    continue
                if path.is_dir():
                    write(root + relative + "/", directory=True)
                else:
                    is_executable = relative == executable or bool(path.stat().st_mode & stat.S_IXUSR)
                    write(root + relative, path.read_bytes(), executable=is_executable)
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    package_app(args.app, args.output)
