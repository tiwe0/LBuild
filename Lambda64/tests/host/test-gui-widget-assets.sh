#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
widget_source=${WIDGET_SOURCE:-"$repo_root/gui/widgets.lisp"}
asset_root=${WIDGET_ASSET_ROOT:-"$repo_root/gui"}

python3 - "$repo_root" "$widget_source" "$asset_root" <<'PY'
from pathlib import Path
import hashlib
import re
import struct
import sys
import zlib

root = Path(sys.argv[1])
source_path = Path(sys.argv[2])
asset_root = Path(sys.argv[3])
source = source_path.read_text(encoding="utf-8")


def require(pattern, description):
    if not re.search(pattern, source, re.DOTALL):
        raise SystemExit(f"widget asset contract missing: {description}")


require(
    r"\(defvar \*close-button\*\s*"
    r"\(mezzano\.gui\.image:load-image \"LOCAL:>Icons>close-button\.png\"\)\)",
    "normal close button is loaded from the image copied into LOCAL:>Icons>",
)
require(
    r"\(defvar \*close-button-hover\*\s*"
    r"\(mezzano\.gui\.image:load-image "
    r"\"LOCAL:>Icons>close-button-hover\.png\"\)\)",
    "hover close button is loaded from the image copied into LOCAL:>Icons>",
)

asset_section = source[source.index("(defvar *close-button*"):
                       source.index("(defvar *close-button-x*")]
if "make-surface-from-array" in asset_section or "#x" in asset_section:
    raise SystemExit("widget close-button pixels are still embedded in Lisp source")
if "TODO" in asset_section or "FIXME" in asset_section:
    raise SystemExit("widget close-button asset section still carries a debt marker")


def paeth(left, up, upper_left):
    estimate = left + up - upper_left
    left_distance = abs(estimate - left)
    up_distance = abs(estimate - up)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= up_distance and left_distance <= upper_left_distance:
        return left
    if up_distance <= upper_left_distance:
        return up
    return upper_left


def decode_rgba_png(path):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path} is not a PNG file")
    position = 8
    compressed = bytearray()
    width = height = colour_type = bit_depth = interlace = None
    while position < len(data):
        length = struct.unpack(">I", data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        payload = data[position + 8:position + 8 + length]
        position += 12 + length
        if kind == b"IHDR":
            width, height, bit_depth, colour_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            break
    if (width, height, bit_depth, colour_type, interlace) != (14, 14, 8, 6, 0):
        raise SystemExit(
            f"{path} must be a non-interlaced 14x14 8-bit RGBA PNG; got "
            f"{width}x{height}, depth={bit_depth}, type={colour_type}, "
            f"interlace={interlace}"
        )

    encoded = zlib.decompress(bytes(compressed))
    stride = width * 4
    rows = []
    cursor = 0
    previous = bytearray(stride)
    for _ in range(height):
        filter_type = encoded[cursor]
        cursor += 1
        filtered = encoded[cursor:cursor + stride]
        cursor += stride
        row = bytearray(stride)
        for index, value in enumerate(filtered):
            left = row[index - 4] if index >= 4 else 0
            up = previous[index]
            upper_left = previous[index - 4] if index >= 4 else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = up
            elif filter_type == 3:
                predictor = (left + up) // 2
            elif filter_type == 4:
                predictor = paeth(left, up, upper_left)
            else:
                raise SystemExit(f"{path} uses invalid PNG filter {filter_type}")
            row[index] = (value + predictor) & 0xFF
        rows.append(row)
        previous = row
    if cursor != len(encoded):
        raise SystemExit(f"{path} contains unexpected decompressed image data")
    return b"".join(rows)


expected = {
    "close-button.png": "d1e50639663fce279a1d72b45a0635178f21022688ce1f504ef9d64d8ece677f",
    "close-button-hover.png": "c063c9ece065d24632e906fe820ab9a9850a115a9591b8acecf5842dd438e46c",
}
for name, expected_digest in expected.items():
    path = asset_root / name
    if not path.is_file():
        raise SystemExit(f"missing widget image asset: {path}")
    digest = hashlib.sha256(decode_rgba_png(path)).hexdigest()
    if digest != expected_digest:
        raise SystemExit(
            f"{path} pixel digest changed: expected {expected_digest}, got {digest}"
        )

# The cold-image loader establishes the existing resource boundary: it loads
# the image decoder, copies every GUI PNG into LOCAL:>Icons>, then loads widgets.
ipl = (root / "ipl.lisp").read_text(encoding="utf-8")
image_load = ipl.index('(sys.int::cal "sys:source;gui;image.lisp")')
png_copy = ipl.index('(directory "sys:source;gui;*.png")')
widget_load = ipl.index('(sys.int::cal "sys:source;gui;widgets.lisp")')
if not image_load < png_copy < widget_load:
    raise SystemExit("cold-image widget asset loading order is no longer valid")

print("GUI widget file-backed asset contract passed")
PY
