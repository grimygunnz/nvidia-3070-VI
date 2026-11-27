# The submitting thread as a pipeline (plan, 2026-11-26)

The frame is bound by one thread: the one that prepares each submission of the
title's lists and sends it to the card (`Host::submit`, under the submission lock,
some 16 submissions a frame, 42-47 ms of a 55 ms frame; `docs/nvidia-8gb.md`). Its
work splits in two:

- **A, the CPU side of the title's memory** (about 31 ms a frame): the steps given
  to the card, waiting for flights the lists read from, the sweep, the write
  watch's one asking, the title's bytes under flights' writes, the refreshes in
  front, the lists' steps (refreshes, copies and fills into title memory, steps of
  ours), the last refreshes, the snapshots.
- **B, the card's side** (about 16 ms): copies in the card's memory (what changed
  goes up, the compares after), what shaders write through views they pick, the
  heaps' records waited for, the slots waiting for textures, sending the lists,
  noting what is in the air, and (`send_late`) the line, its settles and the
  landed lists given back.

The plan: A of submission N+1 on the submitting thread while B of submission N runs
on a thread of its own (the sender), one submission behind. With the two fully
overlapped the submitting side is the longer of them, some 31 ms, not 47.

## What must hold

1. **B runs in order**: one sender thread, a queue, the title's order. The queue's
   numbering (`QUEUE_ORDER`, `card_dirty`'s send numbers) stays the queue's order.
2. **A treats a submission handed to B as in the air** for everything that asks
   what flights may write: `late_blocked` (lists that read what flights write),
   `stale_under_flights` (title bytes under flights' writes), the sweep (nothing
   in the air), `flying()`. A submission's writes are known at A's start (its
   declared writes, its read-backs, its bottom-of-pipe values: the record
   `AIR_AHEAD` of the refreshes-ahead experiment, which put them there before any
   refresh or snapshot of the submission) and must count as in the air from then
   until the line notes them after B sends it.
3. **The submission a declared write belongs to is the one being prepared on that
   thread**: `shadow::PREPARED` becomes per thread; B sets it to its submission's
   number before it declares the writes of views picked by index.
4. **A list is never touched by two threads while it moves**: the lists of a
   submission (`Detached`, owned by `send_late`) go to B with it and are not
   looked at by A again (the refreshes-ahead hang: a list moved while its steps'
   lock was held).
5. **A waits for B only through the line**: a settle in A (flights it reads from,
   `WHY_SYNC`) waits until nothing is in the air, which includes what is queued for
   B. B never waits for A.
6. **What crosses from A to B**: the lists and their order and parts, the command
   lists recorded so far (`lists`, `firsts`), the batch's placed copies, the
   heaps' sync guard, the steps taken for the card (`own`), the submission's
   number, the times for the frame line.

## Steps

1. Split `submit` into `prepare` (A) and `finish` (B) on the same thread, the
   state between them a value of its own. No change in behaviour (a run, the same
   frame time and picture).
2. `PREPARED` per thread; the record of what is in the air (`AIR_AHEAD`, as a queue
   of submissions' writes) consulted by `late_blocked`, `stale_under_flights`,
   `flying` and the sweep.
3. B on a sender thread behind `VICTORY_PIPELINE=1`: `send_late` pushes the
   prepared submission and returns; the sender runs `finish` and the rest of
   `send_late`. Presents and the present-time settles go through the same queue.
4. Runs: crashes, hangs (stack dumps with registers, `VICTORY_STACKS`), the
   picture at 170 s and 250 s, and the frame time against the switch off.
