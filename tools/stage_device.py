#!/usr/bin/env python3
"""Lay out what goes into the app's Documents folder, ready for one push.

    python tools/stage_device.py --game E:/MCLA/mcla-recomp/game --sync signing/sync-ios --out E:/MCLA/ios-stage

<out>/game       the game's files, as hard links (no copy) when <out> is on the
                 same drive as the game; otherwise copied
<out>/mcla-sync  cert.pem, key.pem, sync.json: the save sync's setup (the app
                 moves them out of Documents at its first start)

Then, with the phone on USB and the app installed:

    bg3-ios/.venv/Scripts/python.exe bg3-ios/tools/deploy.py push-data <bundle id> <out> ""
"""

import argparse
import os
import pathlib
import shutil
import sys

REQUIRED = ["default.xex", "xarchive_audio.rpf", "xarchive_audlo.rpf", "xarchive_cache.rpf",
            "xarchive_music.rpf"]
SYNC_FILES = ["cert.pem", "key.pem", "sync.json"]


def place(src: pathlib.Path, dst: pathlib.Path) -> str:
    if dst.exists():
        if dst.stat().st_size == src.stat().st_size:
            return "kept"
        dst.unlink()
    try:
        os.link(src, dst)
        return "linked"
    except OSError:
        shutil.copy2(src, dst)
        return "copied"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--game", type=pathlib.Path, required=True)
    parser.add_argument("--sync", type=pathlib.Path, help="folder with cert.pem, key.pem, sync.json")
    parser.add_argument("--out", type=pathlib.Path, required=True)
    args = parser.parse_args()

    missing = [n for n in REQUIRED if not (args.game / n).is_file()]
    if missing:
        sys.exit(f"{args.game} lacks {', '.join(missing)}")

    game_out = args.out / "game"
    game_out.mkdir(parents=True, exist_ok=True)
    total = 0
    for src in sorted(args.game.iterdir()):
        if src.is_file():
            how = place(src, game_out / src.name)
            total += src.stat().st_size
            print(f"  game/{src.name}  {src.stat().st_size / 1e6:9.1f} MB  {how}")
    print(f"game: {total / 1e9:.2f} GB")

    if args.sync:
        sync_out = args.out / "mcla-sync"
        sync_out.mkdir(parents=True, exist_ok=True)
        for name in SYNC_FILES:
            src = args.sync / name
            if not src.is_file():
                sys.exit(f"{src} is missing")
            shutil.copy2(src, sync_out / name)
            print(f"  mcla-sync/{name}  copied")
    print(f"staged in {args.out}")


if __name__ == "__main__":
    main()
