#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Unified macOS recovery image fetcher.
# Derived from:
#   - kholia/OSX-KVM (fetch-macOS-v2.py) — macrecovery upstream by vit9696
#   - foxlet/macOS-Simple-KVM (tools/FetchMacOS)
#   - sickcodes/Docker-OSX (fetch-macOS.py)

"""
Download macOS recovery/installer images from Apple CDN.

Usage:
    python3 fetch-macos.py --version sequoia
    python3 fetch-macos.py --version sonoma
    python3 fetch-macos.py --version ventura
    python3 fetch-macos.py --version monterey
    python3 fetch-macos.py --version bigsur
    python3 fetch-macos.py --version catalina
    python3 fetch-macos.py --version mojave
    python3 fetch-macos.py --version high-sierra
    python3 fetch-macos.py --list
"""

import argparse
import hashlib
import os
import random
import string
import sys

try:
    from urllib.request import Request, HTTPError, urlopen
    from urllib.parse import urlparse
except ImportError:
    print("ERROR: Python 2 is not supported, please use Python 3")
    sys.exit(1)

# Apple CDN constants

RECENT_MAC = "Mac-27AD2F918AE68F61"
MLB_ZERO = "00000000000000000"
MLB_VALID = "F5K105303J9K3F71M"
MLB_PRODUCT = "F5K00000000K3F700"

TYPE_SID = 16
TYPE_K = 64
TYPE_FG = 64

INFO_PRODUCT = "AP"
INFO_IMAGE_LINK = "AU"
INFO_IMAGE_HASH = "AH"
INFO_IMAGE_SESS = "AT"
INFO_SIGN_LINK = "CU"
INFO_SIGN_HASH = "CH"
INFO_SIGN_SESS = "CT"
INFO_REQUIRED = [
    INFO_PRODUCT, INFO_IMAGE_LINK, INFO_IMAGE_HASH, INFO_IMAGE_SESS,
    INFO_SIGN_LINK, INFO_SIGN_HASH, INFO_SIGN_SESS,
]

# macOS version → (board_id, mlb)
VERSIONS = {
    "sequoia":    ("Mac-937A206F2EE63C01", "00000000000000000"),
    "sonoma":     ("Mac-53FE2BB2B746A6A3", "00000000000000000"),
    "ventura":    ("Mac-4B682C642B45593E", "00000000000000000"),
    "monterey":   ("Mac-FFE5EF870D7BA81A", "00000000000000000"),
    "bigsur":     ("Mac-2BD1B31983FE1663", "00000000000000000"),
    "catalina":   ("Mac-CFF7D910A743CAAF", "00000000000000000"),
    "mojave":     ("Mac-7BA5B2DFE22DDD8C", "00000000000000000"),
    "high-sierra":("Mac-BE088AF8C5EB4FA2", "00000000000000000"),
}

BOARD_ID_URL = "https://osrecovery.apple.com/InstallationPayload/RecoveryImage"


def generate_id(id_type, id_value=None):
    return id_value or "".join(
        random.choices(string.hexdigits[:16].upper(), k=id_type)
    )


def run_query(url, headers, post=None):
    data = None
    if post is not None:
        data = "\n".join(f"{k}={v}" for k, v in post.items()).encode()
    req = Request(url=url, headers=headers, data=data)
    try:
        response = urlopen(req)
        return dict(response.info()), response.read()
    except HTTPError as e:
        print(f"ERROR: {e} when connecting to {url}")
        sys.exit(1)


def get_image_info(board_id, mlb=MLB_ZERO, diag=False):
    headers = {
        "Content-Type": "text/plain",
        "User-Agent": "InternetRecovery/1.0",
    }
    post = {
        "cid": generate_id(TYPE_SID),
        "sn": mlb,
        "bid": board_id,
        "k": generate_id(TYPE_K),
        "fg": generate_id(TYPE_FG),
        "os": "default",
    }
    if diag:
        post["diag"] = ""
    _, body = run_query(BOARD_ID_URL, headers, post)
    info = {}
    for line in body.decode().splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            info[k.strip()] = v.strip()
    return info


def download_image(url, dest, chunk=1 << 20):
    req = Request(url, headers={"User-Agent": "InternetRecovery/1.0"})
    with urlopen(req) as resp:
        total = int(resp.headers.get("Content-Length", 0))
        downloaded = 0
        with open(dest, "wb") as f:
            while True:
                block = resp.read(chunk)
                if not block:
                    break
                f.write(block)
                downloaded += len(block)
                if total:
                    pct = downloaded * 100 // total
                    mib_done = downloaded >> 20
                    mib_total = total >> 20
                    print(
                        f"\r  {pct:3d}%  {mib_done} / {mib_total} MiB",
                        end="",
                        flush=True,
                    )
    print()


def main():
    parser = argparse.ArgumentParser(description="Fetch macOS recovery images")
    parser.add_argument(
        "--version", choices=list(VERSIONS.keys()), help="macOS version to fetch"
    )
    parser.add_argument("--list", action="store_true", help="List available versions")
    parser.add_argument("--outdir", default=".", help="Output directory (default: .)")
    args = parser.parse_args()

    if args.list:
        print("Available versions:")
        for v in VERSIONS:
            print(f"  {v}")
        return

    if not args.version:
        parser.print_help()
        sys.exit(1)

    board_id, mlb = VERSIONS[args.version]
    print(f"Fetching {args.version} (board_id={board_id}) ...")
    info = get_image_info(board_id, mlb)

    for key in INFO_REQUIRED:
        if key not in info:
            print(f"ERROR: missing key {key!r} in Apple response")
            sys.exit(1)

    image_url = info[INFO_IMAGE_LINK]
    image_hash = info[INFO_IMAGE_HASH]
    filename = os.path.basename(urlparse(image_url).path)
    dest = os.path.join(args.outdir, filename)

    print(f"Downloading {filename} ...")
    download_image(image_url, dest)

    print("Verifying SHA-256 ...")
    sha = hashlib.sha256()
    with open(dest, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            sha.update(block)
    if sha.hexdigest().upper() != image_hash.upper():
        print("ERROR: checksum mismatch — download may be corrupt")
        sys.exit(1)

    print(f"OK: {dest}")


if __name__ == "__main__":
    main()
