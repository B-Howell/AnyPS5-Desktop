"""Package the qualified Windows SwanStation checkpoint core."""

import argparse
import hashlib
from pathlib import Path
from zipfile import ZipFile, ZipInfo


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("core", type=Path)
    parser.add_argument("packages", type=Path)
    args = parser.parse_args()

    data = args.core.read_bytes()
    if hashlib.sha256(data).hexdigest() != "5ef8eba64119146e405a90c5e9243a249c9d57c405fd75415fb4234d5b6080eb":
        parser.error("The DLL is not the qualified PS1 checkpoint core.")
    args.packages.mkdir(parents=True, exist_ok=True)
    output = args.packages / "swanstation-netplay.zip"
    entry = ZipInfo("swanstation_libretro.dll")
    entry.create_system = 3
    entry.external_attr = 0o100644 << 16
    with ZipFile(output, "x") as package:
        package.writestr(entry, data)
    print(f"{hashlib.sha256(output.read_bytes()).hexdigest()}  {output}")


if __name__ == "__main__":
    main()
