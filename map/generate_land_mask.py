#!/usr/bin/env python3
"""
Convert world_map_bw.png to a bitmask for the Mondeto smart contract.

Land (black pixels) = 1, Water (white pixels) = 0.
Outputs 235 uint256 values covering 60,000 pixels (300x200).

Pixel ID = y * 300 + x, matching the contract's pixelId() function.
"""

import json
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("Error: Pillow is required. Install with: pip install Pillow", file=sys.stderr)
    sys.exit(1)

WIDTH = 300
HEIGHT = 200
TOTAL_PIXELS = WIDTH * HEIGHT
WORDS = 235  # ceil(60000 / 256)
THRESHOLD = 128  # below this = land (black), above = water (white)


def generate_land_mask(image_path: str) -> list[int]:
    img = Image.open(image_path).convert("L")  # grayscale

    # Resize to 300x200 if needed
    if img.size != (WIDTH, HEIGHT):
        img = img.resize((WIDTH, HEIGHT), Image.LANCZOS)

    pixels = img.load()
    mask = [0] * WORDS

    for y in range(HEIGHT):
        for x in range(WIDTH):
            pixel_id = y * WIDTH + x
            brightness = pixels[x, y]

            if brightness < THRESHOLD:  # black = land
                word_index = pixel_id // 256
                bit_index = pixel_id % 256
                mask[word_index] |= 1 << bit_index

    return mask


def main():
    script_dir = Path(__file__).parent
    image_path = script_dir / "world_map_bw.png"

    if not image_path.exists():
        print(f"Error: {image_path} not found", file=sys.stderr)
        sys.exit(1)

    mask = generate_land_mask(str(image_path))

    # Count land pixels
    land_count = sum(bin(w).count("1") for w in mask)
    print(f"Land pixels: {land_count} / {TOTAL_PIXELS}", file=sys.stderr)

    # Output as JSON array of hex strings (for easy use in deploy scripts)
    hex_values = [hex(w) for w in mask]
    print(json.dumps(hex_values, indent=2))

    # Also output Solidity-compatible format
    sol_path = script_dir / "land_mask.json"
    with open(sol_path, "w") as f:
        json.dump(mask, f)
    print(f"\nSolidity-compatible mask written to {sol_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
