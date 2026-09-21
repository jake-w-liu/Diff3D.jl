"""Reject machine-specific filesystem paths in the published package tree.

Diff3D is a registered package: every tracked file, including the compressed
release evidence archives, ships to anyone who installs it. A home directory or
a private temporary directory from the machine that produced a file is neither
reproducible nor meaningful to a consumer, and a relative path must be used for
anything the build or documentation actually depends on.
"""

import argparse
from pathlib import Path
import re
import subprocess
import sys
import tarfile

# This guard states the forbidden patterns and its tests exercise them, so both
# files necessarily contain example paths as data. They are the only exemptions.
SELF = ("test/check_no_local_paths.py", "test/test_check_no_local_paths.py")

# Home directories and per-machine temporary roots on the supported platforms.
# A trailing component is required so that the bare mount points, which appear
# in prose such as "files under /home", are not reported.
PATTERN = re.compile(
    r"/Users/[^\s\"'`,;:)\]}<>]+"
    r"|/home/[^\s\"'`,;:)\]}<>/]+/[^\s\"'`,;:)\]}<>]*"
    r"|[A-Za-z]:\\\\?Users\\\\?[^\s\"'`,;:)\]}<>]+"
    r"|/private/(?:tmp|var)/[^\s\"'`,;:)\]}<>]+")


def findings(name: str, data: bytes) -> list[tuple[str, int, str]]:
    """Return (file, line number, matched text) for every machine-specific path."""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return []  # Binary payloads such as images carry no readable paths.
    return [(name, number, match.group(0))
            for number, line in enumerate(text.splitlines(), 1)
            for match in PATTERN.finditer(line)]


def scan(root: Path) -> list[tuple[str, int, str]]:
    listing = subprocess.run(["git", "ls-files", "-z"], cwd=root, check=True,
                             stdout=subprocess.PIPE).stdout
    results = []
    for name in sorted(entry for entry in listing.decode().split("\0") if entry):
        if name in SELF:
            continue
        path = root / name
        if not path.is_file():
            continue  # A submodule or a deleted-but-staged entry has no contents.
        data = path.read_bytes()
        results.extend(findings(name, data))
        if name.endswith((".tar.gz", ".tgz")):
            with tarfile.open(path, "r:gz") as archive:
                for member in archive:
                    if not member.isfile():
                        continue
                    stream = archive.extractfile(member)
                    if stream is None:
                        continue
                    results.extend(findings(f"{name}:{member.name}", stream.read()))
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    arguments = parser.parse_args()
    results = scan(arguments.root)
    for name, number, matched in results:
        print(f"{name}:{number}: machine-specific path {matched}", file=sys.stderr)
    if results:
        print(f"Found {len(results)} machine-specific paths in the published tree", file=sys.stderr)
        return 1
    print("No machine-specific paths in the published tree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
