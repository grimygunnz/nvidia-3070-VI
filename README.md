# VIctory on an RTX 3070 Ti (8 GB)

A fork of [codec-d/cool_fox](https://github.com/codec-d/cool_fox), itself built on
[avatarmanz/VIctory-7900XTX](https://github.com/avatarmanz/VIctory-7900XTX) and the
[VIctory](https://github.com/Marvisak/VIctory) compatibility layer, which runs an Xbox
Series title natively on Windows from files the user supplies. This fork is about one
kind of PC: **an NVIDIA card with 8 GB of video memory**, tuned and measured on an
RTX 3070 Ti, a Ryzen 9 5900X and 64 GB of RAM.

**This repository contains no game files, code or assets.** You need your own copy of
the game. It is not affiliated with or endorsed by the game's developer or publisher.

## Where it stands (2026-11-27)

Gameplay of the opening (the prologue), Series S profile (`-Profile br`), late frames
of an unattended run (`-SkipMenus -Seconds 260`, mean of the last 15 frame lines):

| Build | Mean frame | fps | CPU preparing |
|---|---|---|---|
| cool_fox as published (2026-11-26) | 327 ms | 3.1 | 69 ms |
| This fork, card-buffer floor (2026-11-26) | 61 ms | 16.3 | 50 ms |
| **This fork (br, bus + prepare)** | **41 ms** | **24.3** | **31 ms** |

Still short of 30 fps. The remaining prepare wall is mostly real title→copy refreshes
(~11 ms / ~23 MB read a frame) and write-watch asking (~4 ms). `VICTORY_PAGE_TABLE`
stays off here.

The Series X profile still does not fit 8 GB: use Series S (the launchers do).

What is known to be wrong (most of it upstream's, see [the bug journal](docs/bug-journal.md)):

- Shadowed and indoor areas are too dark: the title's ray-traced light does not run.
- About 250–350 draws a frame are dropped, mostly shaders the translator cannot build yet.
- Textures stream in late and some look blocky: the card is full, and some wait.
- The first run with a new driver or build stutters while pipelines are compiled.

## What is different here

The reasons and every measurement are in [docs/nvidia-8gb.md](docs/nvidia-8gb.md).

- **Title buffers stay in the card's memory** on cards with a budget of 12 GB or less:
  up to 2,048 MB of their copies (the 327 → 61 ms step). `VICTORY_CARD_BUFFERS_MB`
  still sets the limit; every copy has 64 KiB past its end (`VICTORY_CARD_PAD_KB`).
- **Discrete / non-unified bus**: placed title copies skip PCIe land waits when the
  title wrote the page (`VICTORY_PLACED_TITLE`); ReBAR / `WINDOWS_BAR` keeps shader
  window reads in card memory when the bar is large enough; large high-heap
  fetch-only copies stay on the card (`VICTORY_HIGH_NO_BACK=1` in the `br` profile)
  so ~21 MB/frame of fetch-only traffic is not pulled back.
- **Prepare CPU**: empty-refresh looks are batched (`VICTORY_LOOKS_APART`, on with
  light refresh); a title write flushes only pending refreshes that overlap that
  range (`title_written_at`, `VICTORY_WRITE_FLUSH=all` restores the old full flush);
  heap-record sync is kicked before flight settle so its work overlaps that wait.
  Differing bytes only go up (`VICTORY_COPY_CHANGED`), quiet 1 MiB blocks are asked
  once a frame (`VICTORY_ASK_QUIET`), and copy-back pages stay quiet
  (`VICTORY_QUIET_BACK`).
- **Residency batched** before each submit (was ~11 ms/frame of `MakeResident` waits).
- **On-picture panel** (`VICTORY_PANEL=1`, F3): RAM / VRAM / commit, resolution, RT,
  lighting, shaders and textures.
- **A sampling profiler** (`VICTORY_PROFILE=1`, diagnostics builds) and a write-watch
  stress test (`cargo test -p victory-gpu watch::stress`).
- **A guarded launcher** (`scripts/play-guarded.ps1`) that caps committed memory and
  ends the game before the PC runs out. `-Profile br` is the measured Series S path
  above; `VICTORY_PAGE_TABLE` and `VICTORY_TEARING` stay off / opt-in (tearing smeared
  here).

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
scripts\play-guarded.ps1 -Game <your dump>\game_scarlett_master.exe -Profile br
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
- This fork's changes were made with [Claude Code](https://claude.com/claude-code)
  and [Cursor](https://cursor.com).

## License

GPL-3.0-or-later, as VIctory. See [LICENSE](LICENSE); the one file that is not covered
is named in [docs/asset-policy.md](docs/asset-policy.md).
