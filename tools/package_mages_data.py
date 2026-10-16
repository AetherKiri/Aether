"""Pack the embedded engine's read-only data for Godot exports."""
import pathlib
import sys
import tempfile
import zipfile

source, destination = map(pathlib.Path, sys.argv[1:])
destination.parent.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as file:
    temporary = pathlib.Path(file.name)
try:
    with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED) as archive:
        def add(path, name):
            # Checkout timestamps differ between platforms; package identity
            # depends only on names and content so the extraction cache is stable.
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes())

        add(source / "gamedefinitions.lua", "gamedefinitions.lua")
        for directory, prefix in (("profiles", "profiles"), ("resources", "resources"),
                                  ("src/shaders", "shaders")):
            root = source / directory
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    add(path, str(pathlib.PurePosixPath(prefix) / path.relative_to(root)))
    temporary.replace(destination)
finally:
    temporary.unlink(missing_ok=True)
