// The engine's thread.
//
// Everything expensive happens here and nothing here is on a deadline. If the
// machine is busy this worker falls behind and the picture lags; the audio
// thread carries on regardless, because it is only copying blocks.
//
// Falling behind was written as though it were a transient. It is not: the
// queue in front of this thread has no bound and draining it needs the machine
// to run *faster* than real time, which a device that could do that would not
// have needed to. So a shortfall integrates and stays. `consumed` below is what
// lets the main thread see it; the recovery is on that side, because the only
// thing that discards a message queue is terminating the worker that owns it.
//
// Columns leave as transferred buffers, so crossing to the drawing thread
// costs a pointer rather than a copy of a screenful of floats.

import { Cochlea } from './engine.js?v=DEV';

let coch = null;

/// Samples this worker has taken off its message queue, ever.
///
/// The main thread posts a block every few milliseconds whatever else is
/// happening -- the audio thread cannot be slowed -- and this worker takes them
/// at whatever rate the machine allows. Nothing anywhere bounds the difference,
/// so on a device that cannot sustain the cascade the queue grows for as long
/// as the page is open. Subtracted from the main thread's `samplesSent`, this
/// is that queue's length, exactly, and it is the only number that separates
/// "the display is slow" from "the display is behind".
///
/// Counted for blocks arriving with no engine open as well. Those are dropped
/// on the next line, and not counting them would leave the main thread reading
/// every reload as permanent backlog.
///
/// It is a total since this worker started, not since the engine opened, and
/// the main thread's counter is reset in step whenever the worker is replaced.
let consumed = 0;

/// Which open is the current one.
///
/// Opening nulls the engine and then waits -- a coefficient fetch and a cascade
/// build, some two hundred milliseconds. A second 'open' arriving inside that
/// window finds `coch` already null, so the destroy below is skipped, and both
/// builds then finish and both claim the variable: the loser's engine and the
/// six WASM allocations it holds are never freed. Reachable by changing ERB
/// twice quickly, and now also by pressing Catch up and then changing ERB.
let openGen = 0;

/// What share of real time the cascade is to be made to consume, and the rate
/// needed to turn a block length into a duration. See `SLOW_FACTOR` on the
/// page. 0 is off, and is what every visitor gets.
let slow = 0, slowRate = 0;

/// When the block being handled is due to be finished, on the wall clock.
///
/// A schedule rather than a per-block stopwatch, and it has to be, because two
/// costs sit outside any window drawn around the cascade alone and both of them
/// push the same way. `pullColumns` and the `postMessage` that follows it are
/// real work done after the spin. And `performance.now()` in a worker is
/// clamped -- a tenth of a millisecond in Chrome, against a block that lasts
/// under three -- so a spin cannot stop *at* its target, only at the first tick
/// past it, overshooting by up to four per cent of the block every time.
///
/// Neither is large. Both are one-directional, which is what matters: they made
/// `slow=1.0` creep upward at a few tens of milliseconds a second instead of
/// holding still, so the one value that should have meant "exactly real time"
/// was the one value that meant something else.
///
/// Carrying the due time forward absorbs both. Each block adds exactly its own
/// duration to the schedule whatever the last one actually cost, so an
/// overshoot shortens the next spin instead of accumulating, and the work after
/// the spin comes out of the following block's budget rather than out of
/// nowhere.
let slowDue = 0;

/// How far behind its own schedule the engine may fall before the schedule is
/// abandoned and restarted from now.
///
/// Without this, an interruption that is not the engine's fault -- the two
/// hundred milliseconds of a cascade rebuild, a page in the background -- would
/// be banked as credit and spent running flat out afterwards, which is neither
/// what was asked for nor a thing a slow machine can do.
const SLOW_RESYNC_MS = 50;

async function open(msg) {
    const gen = ++openGen;
    slow = msg.slow > 0 ? msg.slow : 0;
    slowRate = msg.rate;
    slowDue = 0;                       // a new engine starts a new schedule
    if (coch) { coch.destroy(); coch = null; }
    const built = await Cochlea.create(msg.coeff, msg.rate);
    // Overtaken while building. The engine is finished and correct; it is
    // simply not the one wanted, and dropping it without destroying it would
    // leak the whole cascade.
    if (gen !== openGen) { built.destroy(); return; }
    coch = built;
    coch.setColumnMs(msg.columnMs);
    coch.setDeskew(msg.deskew);
    postMessage({
        type: 'ready',
        taps: coch.tapCount,
        internalRate: coch.internalRate,
        // Copied out so the display can lay out its frequency scale without
        // asking across a thread boundary every frame.
        frequencies: coch.frequencies,
        delays: coch.delays,
    });
}

self.onmessage = async (ev) => {
    const m = ev.data;
    try {
        switch (m.type) {
        case 'open':
            await open(m);
            break;

        case 'audio': {
            consumed += m.samples.length;
            if (!coch) return;
            // Book this block's slot on the schedule *before* doing its work,
            // so what the schedule measures is the whole cost of a block and
            // not the part of it that happens to fall inside a stopwatch.
            //
            // `slow` then means what it says: the share of real time the engine
            // consumes. 1 is exactly real time and the backlog holds still,
            // above 1 it grows, below 1 it drains -- on any machine, without
            // knowing anything about the machine. An earlier version added
            // `(slow - 1)` block-durations after the cascade, which assumes the
            // cascade already costs one; on a desktop it costs a fraction of
            // one, so the point of balance sat wherever the real cost put it
            // and every value below that did nothing at all.
            let due = 0;
            if (slow > 0 && slowRate > 0) {
                const now = performance.now();
                // The `!slowDue` is the first block after an open, where there
                // is no schedule yet -- and a bare comparison against zero
                // would only start one if the worker had already been alive for
                // `SLOW_RESYNC_MS`. The same branch catches every later gap:
                // a rebuild, a backgrounded page, a pause, all of which stop
                // feeding this thread for longer than a block.
                if (!slowDue || now - slowDue > SLOW_RESYNC_MS) slowDue = now;
                slowDue += m.samples.length / slowRate * 1000 * slow;
                due = slowDue;
            }
            coch.process(m.samples);
            // Deliberately a spin and not a sleep, and here rather than after
            // the columns are posted. What is being reproduced is a cascade
            // that takes too long, and a cascade that takes too long holds this
            // thread while the queue grows behind it, then delivers. An awaited
            // timer would hand the thread back and let the queue drain, which
            // is the opposite of the fault.
            if (due) while (performance.now() < due) { /* a slow phone */ }
            const got = coch.pullColumns();
            if (got) {
                postMessage({ type: 'columns', ...got, ref: coch.currentRefDb,
                              consumed },
                            [got.levels.buffer, got.coherence.buffer,
                             got.refs.buffer,
                             got.inLo.buffer, got.inHi.buffer]);
            }
            break;
        }

        // A sentinel, for the end of a file. Messages are handled in order,
        // so a reply to this one means every audio block posted before it has
        // already been turned into columns and sent back. The Mac app gets
        // the same guarantee by draining the ring synchronously; here the
        // engine is a hop further away and has to be asked.
        case 'flush':
            postMessage({ type: 'flushed', token: m.token });
            break;

        // The engine is safe to reconfigure between process() calls, and every
        // call into it happens on this thread, so there is no moment at which
        // one of these can land in the middle of one.
        case 'columnMs':  coch?.setColumnMs(m.value); break;
        case 'deskew':    coch?.setDeskew(m.value); break;
        case 'autoGain':  coch?.setAutoGainHalflife(m.value); break;

        case 'close':
            coch?.destroy();
            coch = null;
            break;
        }
    } catch (err) {
        postMessage({ type: 'error', message: String(err && err.message || err) });
    }
};
