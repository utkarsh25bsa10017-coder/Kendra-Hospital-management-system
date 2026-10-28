#!/usr/bin/env python3
"""Draws the Kendra app icon (teal tile, white cross) for every platform.

Pure Python, no image libraries. Run from the project root:
    python3 tool/make_icons.py
"""
import struct
import zlib

TEAL = (13, 110, 118)
TEAL_DARK = (9, 84, 91)
WHITE = (255, 255, 255)


def png(width, height, rgba_rows):
    raw = b''.join(b'\x00' + bytes(row) for row in rgba_rows)

    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 9))
            + chunk(b'IEND', b''))


def in_rrect(x, y, x0, y0, x1, y1, r):
    if x < x0 or x > x1 or y < y0 or y > y1:
        return False
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def render(size, margin, radius):
    """margin/radius are fractions of the icon size."""
    ss = 4 if size <= 256 else 2
    arm_w = 0.17
    arm_l = 0.50
    a0, a1 = 0.5 - arm_w / 2, 0.5 + arm_w / 2
    l0, l1 = 0.5 - arm_l / 2, 0.5 + arm_l / 2
    cr = 0.035
    rows = []
    for py in range(size):
        row = []
        for px in range(size):
            tile = cross = 0
            shade = 0.0
            for sy in range(ss):
                for sx in range(ss):
                    x = (px + (sx + 0.5) / ss) / size
                    y = (py + (sy + 0.5) / ss) / size
                    if in_rrect(x, y, margin, margin, 1 - margin, 1 - margin, radius):
                        tile += 1
                        shade += y
                        if in_rrect(x, y, a0, l0, a1, l1, cr) or in_rrect(x, y, l0, a0, l1, a1, cr):
                            cross += 1
            n = ss * ss
            if tile == 0:
                row += [0, 0, 0, 0]
                continue
            t = (shade / tile - margin) / (1 - 2 * margin)  # 0 top → 1 bottom
            base = [int(TEAL[i] + (TEAL_DARK[i] - TEAL[i]) * t) for i in range(3)]
            f = cross / tile
            rgb = [int(base[i] * (1 - f) + WHITE[i] * f) for i in range(3)]
            row += rgb + [int(255 * tile / n)]
        rows.append(row)
    return png(size, size, rows)


def ico(images):
    """images: list of (size, png_bytes). PNG-in-ICO, supported since Vista."""
    header = struct.pack('<HHH', 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries = b''
    data = b''
    for size, blob in images:
        dim = 0 if size >= 256 else size
        entries += struct.pack('<BBBBHHII', dim, dim, 0, 0, 1, 32, len(blob), offset + len(data))
        data += blob
    return header + entries + data


def main():
    # macOS: Apple's grid leaves a transparent margin around the tile.
    for s in [16, 32, 64, 128, 256, 512, 1024]:
        with open(f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{s}.png', 'wb') as f:
            f.write(render(s, 0.098, 0.18))
    # Android launcher icons (the launcher applies its own mask).
    for folder, s in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
        with open(f'android/app/src/main/res/mipmap-{folder}/ic_launcher.png', 'wb') as f:
            f.write(render(s, 0.04, 0.22))
    # Windows .ico with the sizes Explorer and the taskbar use.
    with open('windows/runner/resources/app_icon.ico', 'wb') as f:
        f.write(ico([(s, render(s, 0.03, 0.2)) for s in [16, 24, 32, 48, 64, 128, 256]]))
    print('icons written')


if __name__ == '__main__':
    main()
