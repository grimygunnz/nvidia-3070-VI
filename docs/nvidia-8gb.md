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

## Later on 2026-11-26: where the frame stands, and what did not move it

After a restart the unchanged build gives 58.2-59.4 ms (about 17 fps) in eight runs.
The host's card-clock line explains why CPU cuts elsewhere did nothing: the card is
about 64 % busy and idle **21 ms a frame behind the submitting thread**, which worked
55.9 ms of each 58 ms frame. Its parts (the `preparing per frame` line): the lists' steps
23.5 ms (refreshes of host copies 16.1, of 10,500 refreshes 9,400 known to copy
nothing), copies in the card's memory 10.6, the write watch 5.5, planning the card's
steps 4.8, title bytes under flights' writes 3.5. Across threads the guards cost 12 ms
of waiting and 6.4 ms of protection changes a frame.

Measured this round, two runs a side, taking turns:

| Change | Mean frame | Against |
|---|---|---|
| The console told it is on a 1080p set (`VICTORY_DISPLAY_MODE=1920x1080`) | 59.1 ms | 59.0 ms: the title renders its fixed Series S size |
| Release build (no `diagnostics`) | 58.6 ms | 58.9 ms: the counters cost nothing that shows |
| Guards rest 16 ms instead of 3 (`VICTORY_GUARD_REST=16000`) | 62.4 ms | 58.4 ms: worse |

`scripts/play-guarded.ps1` clears every `VICTORY_` variable before it starts the game,
so a variable set in the shell never reaches it: pass settings with
`-Set NAME=value,...` (added now).

## Rendering

- **Dropped draws.** Of the 840 dispatches a frame dropped "without a host pipeline",
  836 are the ray-tracing structure builder and its resolve and ray activation, left out
  on purpose with ray tracing off (the log called the last two "being made"; it now
  names them). One a frame is a real loss: `CS_DefragHeap_ComputeRelocations`, a
  64-lane program (a wave walking a list of blocks lane by lane, `v_readlane` of lane
  63, `v_mbcnt` over the 64 lanes) that has no 32-lane form yet on a card with 32-lane
  waves only. The title's GPU heap is not defragmented. Three more 64-lane programs
  (`CS_TransmissionVolumetrics_Tiled*`, `CS_CollectTriangles_Meshlets`) do not
  translate either but did not run in the opening.
- **Textures.** The frame line's "25,000 waiting" are mostly slots not due yet: the
  queue's census has about 1,000 due at a time (the oldest written 8 frames before) and
  106 waiting for memory. Leaving the largest level of large textures out to make room
  was tried; with `VICTORY_LEVELS_ON_DEMAND=0` (which the held-levels path needs) the
  device was lost 40 s in, and it is not kept.
- **Bands in the light the ambient stand-in gives.** With `VICTORY_AMBIENT` on (the
  launcher's 0.8) every surface it lights showed bands, each step about 1.2 times the
  next: the dark interior in rings around the window, and the sky and ground seen through
  the window's glass in steps of 5-10 of 255. With the stand-in off the sky is smooth
  (steps of 1-2) and the room black. The light it writes has 9-bit mantissas; the
  bands come from the title keeping it coarsely further on, where the traced light it
  stands in for is noisy enough to hide them. Grain on the estimate (a fixed per-pixel
  pattern, up to 40 % either way; 12 % was smoothed away by the title's filters before
  the coarse step) takes the bands away: sky in steps of 1-3, the room falling off
  evenly. Same frame time.

## Evening of 2026-11-26: waits, spins, and device method 0x218

Runs are now 200 s scored from 120 s (loading ends near 49 s, the cutscene about 30 s
later, frame times settle by 130 s), one pair per change.

- **Where the submitting thread waits** (a timeline at 240 s, `VICTORY_TIMELINE`): of
  its time in submissions about a quarter is waiting: for the last refreshes of a
  flush on the other threads (the long ones are waits for the guards' lock inside
  `watch::writes`), and 4-5 ms a frame for the heaps' records at the end.
- **The guards' lock** is held 8 ms a frame in all (about 1,800 holds of 6 us; the
  longest, a write fault opening aliased blocks, up to 4 ms), yet threads waited
  48-64 ms a frame for it: the time a thread put to sleep takes to run again. The
  log's lock line now says who holds it, by `watch.rs` line, in diagnostics builds.
  `VICTORY_GUARD_SPIN=<us>` spins before sleeping: 40 us halved the waits (23-27 ms)
  and left the frame where it was (57.3/57.8 vs 57.4/57.6 ms). Off by default.
- **Spinning helpers** of the copy threads (`VICTORY_WIDE_SPIN`, there already) and of
  the landing, records and views pools (`VICTORY_POOL_SPIN`, new): 50 us 57.1/56.0 vs
  57.9/57.1 ms, 200 us 57.6 vs 56.7 ms: noise. Both off by default.
- **Device method 0x218** is the title's compute pipeline made of its own code: the
  description's pieces are an FSPX part's entries (registers 0x1c bytes, hash 0x14,
  code, metadata 0x403 with the code's dword count), and `VICTORY_RAW_COMPUTE=1` makes
  them as an `ACCC` container the translator already reads. Off by default: once the
  first succeed, the title makes all its compute pipelines that way and uses them in
  place of the ones it makes of containers. 821 then do not translate (482 for FSPX
  resources of root types not known yet; the rest for addresses not from a root
  parameter, image stores of some channels, addresses of two computed terms, ...) and
  their dispatches are dropped: 40 ms a frame, for a frame missing that work. Method
  0x1c8 is the graphics counterpart (a 388-byte register block, an input layout of
  POSITION, COLOR, TEXCOORD): not written.
- **Device method 0x218, followed further.** The FSPX reader now takes root
  constants (the one resource record of an unknown root type: a CBV of 4 dwords in
  user data from dword 5, root slot 1), and an address may hold two computed terms
  (`Address::dynamic2`: an SGPR address holding one, read with a VGPR offset holding
  the other). Still 803 fail, now first for a descriptor the code loads and remakes as
  a raw view of the same memory (stride cleared, bounds in bytes, read by byte offset
  or with a format), then addresses not from a root parameter. **Not worth finishing
  for speed:** 662 of the 1,019 compute programs the title makes this way have a
  container program of the same group size and nearly the same code length; they are
  the title's precompiled forms of shaders it otherwise makes of containers, which
  translate and run now. Made this way the work is the same; the 40 ms frames were the
  work dropped (the screen grey but for the prompts). `VICTORY_RAW_COMPUTE` stays off.
- **Refreshes ahead of the submitting thread, tried and taken out.** The threads that
  translate the title's lists brought each list's host copies up to date once it was
  translated (`VICTORY_PREFETCH=1`), while the submitting thread was on the ones
  before. The title crashed 35 s into the run (a write to null in its code at frame
  1269, just after a read-back): a refresh from title memory can come between a
  flight's shader writes (a texture copied into a buffer the title reads back) and
  their landing in title memory, and the title then reads what was there before. The
  submitting thread settles such flights, under the submission lock, before it
  refreshes what they write (`stale_under_flights`); a thread outside the lock cannot
  know that nothing is sent between its look and its refresh, and with the relay
  something is nearly always in the air. Moving the refreshes off that thread needs
  the flights' bookkeeping to say, per range, what is still to land, from before the
  lists are sent.
- **Refreshes ahead, second try, also taken out.** The ranges a submission may write
  were put in a record from the start of its preparation (before any refresh or
  snapshot of it) until the line noted them, under a lock that a refresh ahead held
  from its look to the end of its refresh; copies in the card's memory were left to
  the submission. The title still crashed at the cutscene's start (frame ~1265, a
  write to null in its code, `+0x23cf683` or `+0x2215c35`), with the refreshes on
  their own thread, and also with the pass not refreshing at all (`nothing_new` and
  the checks alone), and with only the checks of what is in the air. A pass that
  only counts the list's steps ran clean, as did the record on the submitting thread
  alone, and every run without the pass. Nothing the crashing passes did writes
  anything the title or the card read; they took locks (a copy's pending writes, the
  line's, the record's) in the moments the title's first cutscene frames come
  together. The title has something there that depends on when the flights land, and
  finding it means following its code at that address. Until then the submitting
  thread keeps the refreshes.
