// The engine's thread.
//
// Everything expensive happens here and nothing here is on a deadline. If the
// machine is busy this worker falls behind and the picture lags; the audio
// thread carries on regardless, because it is only copying blocks.
//
// Columns leave as transferred buffers, so crossing to the drawing thread
// costs a pointer rather than a copy of a screenful of floats.

import { Cochlea } from './engine.js';

let coch = null;

async function open(msg) {
    if (coch) { coch.destroy(); coch = null; }
    coch = await Cochlea.create(msg.coeff, msg.rate);
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
            if (!coch) return;
            coch.process(m.samples);
            const got = coch.pullColumns();
            if (got) {
                postMessage({ type: 'columns', ...got, ref: coch.currentRefDb },
                            [got.levels.buffer, got.coherence.buffer,
                             got.refs.buffer]);
            }
            break;
        }

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
