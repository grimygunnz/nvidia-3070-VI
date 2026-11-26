# VIctory on an RTX 3070 Ti (8 GB)

A fork of [codec-d/cool_fox](https://github.com/codec-d/cool_fox), itself built on
[avatarmanz/VIctory-7900XTX](https://github.com/avatarmanz/VIctory-7900XTX) and the
[VIctory](https://github.com/Marvisak/VIctory) compatibility layer, which runs an Xbox
Series title natively on Windows from files the user supplies. This fork is about one
kind of PC: **an NVIDIA card with 8 GB of video memory**, tuned and measured on an
RTX 3070 Ti, a Ryzen 9 5900X and 64 GB of RAM.

**This repository contains no game files, code or assets.** You need your own copy of
the game. It is not affiliated with or endorsed by the game's developer or publisher.

## Where it stands (2026-11-26)

Gameplay of the opening (the prologue), Series S profile, mean of every frame from
200 s to 330 s into a run:

| Build | Mean frame | fps | CPU preparing | Waiting for the card |
|---|---|---|---|---|
| cool_fox as published | 327 ms | 3.1 | 69 ms | 245 ms |
| **This fork** | **61 ms** | **16.3** | **50 ms** | **0.3 ms** |

The Series X profile runs at 123 ms (8.1 fps): its render targets push the card's
memory to 8.5 GB of a 6.8 GB budget, and Windows moves resources out to system memory.
Use the Series S profile on 8 GB cards (the launchers do).

What is known to be wrong (most of it upstream's, see [the bug journal](docs/bug-journal.md)):

- Shadowed and indoor areas are too dark: the title's ray-traced light does not run.
- About 350 draws a frame are dropped, mostly shaders the translator cannot build yet.
- Textures stream in late and some look blocky: the card is full, and some 24,000 wait.
- The first run with a new driver or build stutters while pipelines are compiled.

## What is different here

The reasons and every measurement are in [docs/nvidia-8gb.md](docs/nvidia-8gb.md).

- **Title buffers stay in the card's memory** on cards with a budget of 12 GB or less:
  up to 2,048 MB of their copies, where upstream kept 512 MB for that class of card. With
  512 MB, 1,198 copies fit and thousands more were read by the card over PCIe from
  system memory: 245 ms a frame of waiting. This one change is the 327 → 61 ms.
  `VICTORY_CARD_BUFFERS_MB` still sets the limit.
- **Every card copy has 64 KiB past its end** (`VICTORY_CARD_PAD_KB`). With every buffer
  in its own allocation on the card, a shader reading past a buffer's end hit an unmapped
  address and the device was lost (the driver logged MMU faults). In system memory the
  same read had landed in the next allocation.
- **A sampling profiler** (`VICTORY_PROFILE=1`, diagnostics builds): per thread and per
  function, ms a frame, with the waits named. It is how the cause above was found.
- **A stress test of the write tracking** (`cargo test -p victory-gpu watch::stress`):
  title threads write values that only grow into watched and guarded memory while
  submissions refresh overlapping copies on several threads, and no write made before a
  submission may be missing from its copy. 3.8 million checks in 20,000 submissions.
- **A guarded launcher** (`scripts/play-guarded.ps1`) that caps the game's committed
  memory and ends it before the PC runs out, with a memory log every 5 s.

## How to run it

You need Windows 10/11 x64, a CPU with AVX2, a Direct3D 12 GPU with shader model 6.6
and mesh shaders, Rust (the toolchain is pinned), the MSVC build tools, and your own
dump of the title.

```powershell
git clone https://github.com/grimygunnz/nvidia-3070-VI
cd nvidia-3070-VI
cargo build --locked --profile diag -p victory --features diagnostics
```

Translate the shaders once before the first run (a few minutes), with the cache where
the launcher keeps it:

```powershell
$env:VICTORY_CACHE_DIR = "$env:LOCALAPPDATA\victory-coolfox\cache"
target\diag\victory.exe shaders <your dump>\shaders.rpf <your dump>\game_scarlett_master.exe
```

Then play:

```powershell
scripts\play-guarded.ps1 -Game <your dump>\game_scarlett_master.exe
```

`-Console series-x` picks the other profile, `-MaxGB` and `-MinFreeGB` set the memory
guard, `-SkipMenus -Seconds 330 -Tag <name>` makes an unattended benchmark run (the
scripted presses need the diagnostics build). The log goes to
`%TEMP%\victory-coolfox-<tag>-<time>.log.err`, and the frame line in it reads
`<fps> fps, <ms> ms/frame (<ms> preparing ... <ms> on the GPU ...)`.

`Play-VIctory.cmd pareto-residency` is upstream's launcher and works too.

Debugging switches, the frame recorder and upstream's descriptions:
[docs/README-cool_fox.md](docs/README-cool_fox.md), [docs/replay.md](docs/replay.md),
[docs/findings.md](docs/findings.md). Every `VICTORY_...` switch is described in a
comment where it is read.

## Credits

This is a tree of other people's work with a little on top. The history is kept, and
commits taken from elsewhere name the commit and its author.

- **[codec-d/cool_fox](https://github.com/codec-d/cool_fox)**: the base, with its NVIDIA
  Wave32 lowering, residency work, two-plane compose and the Series S fixes.
- **[avatarmanz/VIctory-7900XTX](https://github.com/avatarmanz/VIctory-7900XTX)**: the
  CPU-side work this fork's speed rests on, the frame recorder, and its findings.
- **[VIctory](https://github.com/Marvisak/VIctory)** by Marvisak and its contributors:
  the loader, the runtime services, the Direct3D 12 back end and the shader recompiler.
- **[fxceless/victory-fork](https://github.com/fxceless/victory-fork)** and the people
  whose pull requests it carries, and everyone named in
  [docs/README-cool_fox.md](docs/README-cool_fox.md).
- This fork's changes were made with [Claude Code](https://claude.com/claude-code).

## License

GPL-3.0-or-later, as VIctory. See [LICENSE](LICENSE); the one file that is not covered
is named in [docs/asset-policy.md](docs/asset-policy.md).
