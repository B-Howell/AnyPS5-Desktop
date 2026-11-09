"""Package a qualified Windows SwanStation netplay core."""

import argparse
import hashlib
from pathlib import Path
from zipfile import ZipFile, ZipInfo

PACKAGES = {
    "staged": ("swanstation-netplay.zip", "5ef8eba64119146e405a90c5e9243a249c9d57c405fd75415fb4234d5b6080eb"),
    "ordinary": ("swanstation-netplay-ordinary.zip",
                 "d1619715fe11db0faa280890c741aff876fd5fd682f3cd00fbcafaa04732b7ac"),
    "rollback": ("swanstation-netplay-rollback.zip",
                 "9e72d4ded35ed5308916e16448edc1c3c39651969c2f6fde68b4e3293eea6347"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("core", type=Path)
    parser.add_argument("packages", type=Path)
    parser.add_argument("--profile", choices=PACKAGES, default="staged")
    args = parser.parse_args()

    data = args.core.read_bytes()
    name, digest = PACKAGES[args.profile]
    if hashlib.sha256(data).hexdigest() != digest:
        parser.error("The DLL is not the qualified core for this PS1 netplay profile.")
    args.packages.mkdir(parents=True, exist_ok=True)
    output = args.packages / name
    entry = ZipInfo("swanstation_libretro.dll")
    entry.create_system = 3
    entry.external_attr = 0o100644 << 16
    with ZipFile(output, "x") as package:
        package.writestr(entry, data)
    print(f"{hashlib.sha256(output.read_bytes()).hexdigest()}  {output}")


if __name__ == "__main__":
    main()
