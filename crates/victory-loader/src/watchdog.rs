//! The title's hang watchdog, kept from ending the run.
//!
//! A thread of the title's (`+0x2215a60` in the build this was read from)
//! wakes every second and ends the process on purpose (a store to address
//! 0, after a handler that a waiting thread may have installed) when either
//! of two things holds:
//!
//! - a thread has been inside one of the title's watched scopes too long:
//!   each thread keeps a small stack of the times it entered them
//!   (`+0xb5b6b0` pushes, `+0xb5b6f0` pops), and the watchdog compares their
//!   age with a limit, through a check (`+0x9d3e70`, key `0x89aee1d6`) not
//!   read yet;
//! - nothing has told it of progress for 30 of its wakes.
//!
//! While the title waits for its GPU at the start of the opening cutscene
//! (`+0x23cf6a0`), the handler is one that names "GPU Loc Sig" and stores
//! to 0 itself (`+0x23cf620`). With extra work of ours on other threads at
//! that moment (refreshes ahead of the submitting thread, even a pass that
//! only looked at what they would refresh) the title ended there every run,
//! 3 s into a frame that the same build without that work got through: the
//! watchdog's limits are the console's, and the timing here is not.
//!
//! The three conditional jumps to the ends (`+0x2215bdc` the age, `+0x2215c70`
//! and `+0x2215d84` the 30 wakes, one in each form of its loop) become 2-byte
//! no-ops, each only where the bytes are those of that build. A title that
//! truly hangs then hangs, and does not end. `VICTORY_TITLE_WATCHDOG=1`
//! leaves it as it is.

/// The places (offsets from the image's base) and the bytes there.
const JUMPS: [(usize, [u8; 2]); 3] = [(0x2215bdc, [0x73, 0x2e]), (0x2215c70, [0x74, 0x04]), (0x2215d84, [0x74, 0x04])];

/// `66 90`: a 2-byte no-op.
const NOP: [u8; 2] = [0x66, 0x90];

/// Bytes after the jumps, read with them: the build is known by them too.
const AFTER: [(usize, &[u8]); 3] = [
    // mov dword ptr [0], 4D8BD421h: the handler's own store.
    (0x23cf683, &[0xc7, 0x04, 0x25, 0x00, 0x00, 0x00, 0x00, 0x21, 0xd4, 0x8b, 0x4d]),
    // mov dword ptr [0], 0 behind each form's call of the handler.
    (0x2215c35, &[0xc7, 0x04, 0x25, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
    (0x2215da9, &[0xc7, 0x04, 0x25, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
];

/// Neutralizes the watchdog in the image mapped at `base`, `size` bytes, if
/// it is that build's. Whether it did. Before any of the title's code runs.
///
/// # Safety
/// `base..base + size` is a mapped image of the title's that no thread runs yet.
pub(crate) unsafe fn neutralize(base: usize, size: usize) -> bool {
    use windows_sys::Win32::System::Diagnostics::Debug::FlushInstructionCache;
    use windows_sys::Win32::System::Memory::{PAGE_EXECUTE_READWRITE, VirtualProtect};
    use windows_sys::Win32::System::Threading::GetCurrentProcess;
    if std::env::var_os("VICTORY_TITLE_WATCHDOG").is_some_and(|v| v == "1") {
        return false;
    }
    let inside = |at: usize, len: usize| at.checked_add(len).is_some_and(|end| end <= size);
    // SAFETY: each read lies inside the mapped image (checked).
    let bytes = |at: usize, len: usize| unsafe { std::slice::from_raw_parts((base + at) as *const u8, len) };
    let known = JUMPS.iter().all(|&(at, was)| inside(at, 2) && bytes(at, 2) == was)
        && AFTER.iter().all(|&(at, was)| inside(at, was.len()) && bytes(at, was.len()) == was);
    if !known {
        return false;
    }
    for (at, _) in JUMPS {
        let place = (base + at) as *mut u8;
        let mut old = 0u32;
        // SAFETY: two bytes of the image's code (checked above), made
        // writable for the store and put back; no thread runs them yet.
        unsafe {
            if VirtualProtect(place.cast(), 2, PAGE_EXECUTE_READWRITE, &mut old) == 0 {
                return false;
            }
            std::ptr::copy_nonoverlapping(NOP.as_ptr(), place, 2);
            VirtualProtect(place.cast(), 2, old, &mut old);
            FlushInstructionCache(GetCurrentProcess(), place.cast(), 2);
        }
    }
    true
}
