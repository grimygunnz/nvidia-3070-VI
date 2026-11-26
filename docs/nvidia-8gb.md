# On an NVIDIA card with 8 GB: what was measured (2026-11-25 to 26)

One PC: RTX 3070 Ti 8 GB (a video-memory budget of about 6.8-7.2 GB as Windows counts
it), Ryzen 9 5900X (12 cores, 24 threads, all of one kind), 64 GB RAM, Windows 11.
Diagnostics builds (`--profile diag --features diagnostics`).

## How runs are measured

`scripts/play-guarded.ps1 -SkipMenus -Seconds 330`: scripted presses take the title
through its menus into the opening's gameplay, and the run ends at 330 s. The score is
taken from the frame line the host logs every few seconds (`<fps> fps, <ms> ms/frame`)
from 200 s on: the mean frame is 1000 times the number of lines over the sum of their
fps (every frame weighted alike), with the line's preparing time and its time waiting
for the card. Gameplay frames vary from run to run by about 5 %: changes smaller than
that were not kept.

## The card waited for buffers in system memory

cool_fox as published, Series S:

| | |
|---|---|
| Mean frame | 327 ms (3.1 fps) |
| CPU preparing | 69 ms |
| Waiting for the card | 245 ms |
| Card busy | 95 % (`the card's clock per frame` line) |

The card was the limit, not the CPU. The host log's `card buffer limits` line said
`card_buffers_max_mb=512`: for a video-memory budget of 12 GiB or less, at most 512 MB of
title buffers' copies go to the card's memory (`shadow::default_card_limits_mb`). The
`host copies in the card's memory` line had 1,198 copies (591 MB); the log named
buffers turned down. Every other title buffer stayed in system memory, and every load,
store and atomic a shader does on it crosses PCIe.

With `VICTORY_CARD_BUFFERS_MB=2048`: 3,596 copies (1,009 MB), **67.0 ms**, the card
waited 0.2 ms. Made the default for budgets up to 12 GiB (`d7ba623`), with 64 KiB past
each copy's end (below): **61.2 ms (16.3 fps)**, CPU preparing 49.5 ms, the card waited
0.3 ms. The card's memory peaked at 7.0 GB.

## Why the padding

In the tree this fork's changes were first made in, putting every buffer's copy on the
card brought device losses: four in nineteen runs, each with `0x887A0006`, and the
driver's event log had `Graphics SM Warp Exception ... MMU Fault` at them: a shader
reading an address with nothing mapped. A read past a buffer's end through a root view
(which has no bounds) found the next allocation's bytes in system memory, and nothing on
the card once each buffer had an allocation of its own. With 64 KiB past every copy's
end: three runs in a row with no device loss and no driver event. Here: none in every
run since. `VICTORY_CARD_PAD_KB=0` turns it off.

## Series X does not fit

Same build, `-Console series-x`: 123.4 ms (8.1 fps), CPU preparing 35.8 ms, waiting
for the card 75.9 ms. The card had 8,522 MB in use of a budget of 6,816 MB, 608 buffer
copies were turned down, and 31,000 textures waited. Its render targets are larger, and
past the budget Windows moves resources to system memory. Not pursued: the Series S
profile is the one to use on 8 GB.

## Where the 61 ms frame goes (Series S)

The host's own per-frame lines and the sampling profiler (`VICTORY_PROFILE=1`):

- The submitting thread (`victory-submit`) works 59 of 61 ms: it is the limit.
  Of its time: the lists' steps 25 ms (refreshes of host copies 18, of 10,500 refreshes
  9,400 copy nothing), copies in the card's memory 11 (some 650 hash and compare passes a
  frame), waiting for the heaps' records 5-7, the write-watch asking 5, planning the
  steps done on the card 5.
- Translating the title's 37,600 list calls a frame (`VICTORY_THIN`): 215 ms on eight
  threads, each about a third busy.
- The relay (copy-back): 24 ms a frame on its own thread.
- The card is about 70 % busy.

## Tried and not kept

Each one run of 330 s against the 61.2 ms baseline:

| Change | Mean frame | Why it was not kept |
|---|---|---|
| Wave32 lowering off (`VICTORY_WAVE_WIDE=0`), before the buffer fix | 327 → 293 | Not the cause of the card's time |
| 10 refresh threads and 6 landing threads (`VICTORY_WIDE_THREADS`) | 69.6 | Slower: more threads, more contention |
| The texture queue's lock skipped where there is nothing to queue | 62.3 | The lock slowed only the translating threads, which are not the limit |
| The guards asked once per submission for view memory (guard ahead) | 62.2 | The refresh threads' waits at the guards' lock are hidden behind other work |

The frame recorder (`docs/replay.md`) records on this card, but every replay of a
gameplay frame ended in a timeout reset of the driver (event 153), with or without
`--no-restore` and `--pace`: per-pass times of the card are not to be had here yet.

## What is next

1. The submitting thread: the refreshes that copy nothing, and the card copies' hash and
   compare passes (one pass per copy and range).
2. Series X on 8 GB: a cap on textures' share of the card (`VICTORY_TEXTURE_BUDGET_MB`)
   so the render targets fit.
3. The replay on 8 GB cards, to see the card's time by pass.

## One core die (2026-11-26): measured, left off

The Ryzen 9 5900X has two core dies, each with its own 32 MB L3. `VICTORY_ONE_L3=1`
keeps the process to the logical processors of the first last-level cache
(`cores::keep_on_one_l3`); `scripts/play-guarded.ps1 -Affinity <mask>` does it from
outside. The title reads how many processors there are and pins its threads across all of
them with `SetThreadGroupAffinity`, which widened the process back to every processor: the
runtime now keeps that call inside the process's mask (`victory-hle` `kernel`). Earlier
runs "on one die" were on both, and their gain was noise.

Runs one after another, pinned and not:

| | Runs | Mean | Waiting for the heaps' records |
|---|---|---|---|
| The first die (12 threads) | 74.0, 75.5 ms | 74.8 ms | 11-14 ms |
| Every processor (24) | 68.6, 68.9 ms | 68.8 ms | 6-7 ms |

Twelve threads are too few for the title's, ours and the pools': off by default. (These
four runs are slower than the evening's first ones, 61-65 ms: the PC's state drifts over
a session, which is why the two sides were run in turn.)

Also tried in this round, each one run: heap-sync rounds every 1 ms instead of 4
(`VICTORY_HEAP_SYNC_EARLY=1`, 68.7 ms) and up to 16 submission parts joined
(`VICTORY_JOIN_PARTS=16`, 72.7 ms, no more joined than with 8). Not kept.

Ray tracing does not run: without `VICTORY_BVH_BUILDER=1` every stage of the structure
builder is dropped and the ray resolve and activation passes are left out; there is no
ray-tracing work of the card's to take away.
