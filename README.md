# mcla-ios

An iOS build of [mcla-recomp](https://github.com/RenanQueiroz/mcla-recomp), the static recompilation of
*Midnight Club: Los Angeles Complete Edition* (Xbox 360) on the [ReXGlue SDK](https://github.com/rexglue/rexglue-sdk).

**This repository contains no game code, assets or keys.** It holds an iOS patch for the SDK (`patches/`), the app
project (`ios/`) and the build workflow. The recompiled code is generated on your own PC from your own disc image and
reaches the build encrypted; what is built is for you, not for sharing.

Licence: GPL-3.0-or-later, as mcla-recomp. *Midnight Club* is a trademark of Take-Two Interactive; this project is not
affiliated with or endorsed by Rockstar Games or Take-Two.

## Status

Runs on an iPhone 17 Pro Max (iOS 27): boots, plays, saves, survives being sent to the background. It is not fast
yet. The GPU is the limit: about 20 to 26 frames a second in the city with the game's "low" preset (no anti-aliasing),
7 to 12 with 2x MSAA. The renderer begins some 250 render passes a frame for about 31 render target changes, which a
desktop GPU does not notice and a tile-based one pays for with a store and a load each; the settings under
"Renderer experiments" below are aimed at that and are off until they have been verified on a device.

Not there yet: 2x MSAA in one tile (an EDRAM of 4,096 tiles leaves the lower part of the frame blurred on MoltenVK, so
the console's 2,048 is used), any device other than the one above.

## What the app does

- **Controllers.** Any MFi, Xbox or PlayStation controller. With none connected, the system's on-screen controller
  (stick, d-pad, A/B/X/Y, shoulders, triggers) and START and BACK buttons at the top of the screen.
- **Saves.** Kept in the app, and synchronised with a PC and a Steam Deck over the home network by an embedded
  Syncthing, when its three setup files are in `Documents/mcla-sync`.
- **Shaders.** The fork's shader pack is imported on the first start ("Preparing shaders n / total" shows how far it
  is: a minute or two once, seconds afterwards).
- **Defaults by device.** Every device starts at the console's resolution with the "low" preset; the pause menu's
  PERFORMANCE tab and `Documents/mcla.toml` change that.

## Files in the app's Documents folder

Visible in Files under On My iPhone > MCLA, and to a computer.

| Path | What |
|---|---|
| `game/` | `default.xex` and the `.rpf` archives of your own copy of the game |
| `mcla.toml` | Settings (the game writes what the pause menu changes) |
| `mcla-env.txt` | Optional: `NAME=value` lines set as environment variables at start |
| `mcla-console.txt`, `.previous.txt` | Standard output of this run and of the one before |
| `logs/` | The game's own log, a file a run |
| `mcla-sync/` | Save sync setup: `cert.pem`, `key.pem`, `sync.json` |

## Diagnostics (`mcla-env.txt`)

| Variable | Effect |
|---|---|
| `MCLA_METAL_STATS=1` | Counts Metal render, compute and blit passes and the samples loaded and stored a frame |
| `MCLA_PROFILE=1` | Samples the busiest threads' stacks after each performance line |
| `MCLA_EDRAM_TILES=4096` | The fork's larger EDRAM (see Status) |
| `MCLA_USER_ROOT=name` | A user folder of its own, copied from the player's once, and no save sync: for test runs |
| `MCLA_TOUCH=0` | No on-screen controls |
| `MVK_CONFIG_*` | MoltenVK's own settings |

`mcla-console.txt` has a `[mcla-perf]` block every five seconds: frames a second, the time in `vkQueueSubmit`, how
often the command processor waited for the GPU, draws, what was recorded a frame (render passes, copies, barriers), why
render passes ended (uploads, textures, resolves, queries, submissions, target changes, barriers) and the thermal state.
A crash prints `[mcla-crash]` with the call stack by function name.

## Renderer experiments

Settings of the SDK patch, off by default (`mcla.toml`, or `--name=value` on the command line):

| Setting | What it does |
|---|---|
| `vulkan_render_area_from_scissor` | A render pass gets the area its scissors reach, not the whole host render target |
| `shared_memory_hot_page_compare` | Of a hot page, only the bytes that differ from what was uploaded last are uploaded |
| `vulkan_precise_upload_hoisting` | A draw marks the vertices it reads, not its whole vertex buffer, so that more uploads go before the render pass instead of ending it |

## Building

`.github/workflows/ios.yml` builds on a macOS runner: the fork's SDK source archive with `patches/` applied, Syncthing
as a C archive, MoltenVK from its release, the recompiled code from an encrypted archive in a private repository
(`tools/pack_generated.py` makes it), and hands the IPA back to that repository, encrypted. Sign it with your own
identity (SideStore does) with the Increased Memory Limit and Extended Virtual Addressing capabilities enabled on the
App ID.
