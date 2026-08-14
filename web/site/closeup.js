// How the close-up is sized.
//
// A port of the fitting rules in the Mac app's Settings.swift, kept as its own
// file because it is arithmetic with no display and no engine in it, and
// because the two implementations have to agree exactly -- a strip that is one
// column wider in the browser would put the boundary somewhere the engine was
// not expecting.
//
// The spans span two different jobs. 160 ms is about ten frames at 60 Hz and
// is where the *whole* display has something to show: 20 peaks at 125 Hz, 10
// at 64. The short ones are for the top of the picture, where a 20 ms window
// holds 320 cycles at 16 kHz and individual glottal pulses are separate events
// rather than a texture -- at the cost of the lowest two octaves, which hold
// 2.5 peaks at 125 Hz and 1.3 at 64 and say almost nothing. Neither is the
// right setting; they answer different questions.
//
// Span and width are both chosen -- the menu sets one, dragging the line sets
// the other -- and the magnification falls out of them, since
// span = width x ms-per-column.

export const CLOSE_UP_SPANS = [0, 5, 10, 20, 40, 80, 160, 320];

// ---- the Speed detents ----------------------------------------------------
//
// Also from Settings.swift, and here for the same reason: the two apps have to
// offer the same settings or a picture cannot be compared with a picture.
//
// Ten equal *ratios* across the range, not ten equal numbers of milliseconds.
// A time scale is a ratio quantity -- the step from 1 ms to 2 ms is the same
// change as the step from 32 to 64 -- so equal spacing on screen has to mean
// equal spacing in the log.
//
// 0.5 to 64 ms is 128x, seven octaves. Divided fourteen ways each step is
// exactly half an octave, a ratio of root two, which puts 0.5, 1, 2, 4, 8, 16,
// 32 and 64 all on the grid with one detent between each pair.
export const COLUMN_RANGE = [0.5, 64];
export const COLUMN_DIVISIONS = 14;
export const COLUMN_STEPS = Array.from(
    { length: COLUMN_DIVISIONS + 1 },
    (_, i) => COLUMN_RANGE[0]
              * Math.pow(COLUMN_RANGE[1] / COLUMN_RANGE[0], i / COLUMN_DIVISIONS));

/// How a column time is written. Enough digits to tell two detents apart and
/// no more: the half-octave steps are 1.41 and 2.83, not 1 and 3.
export function columnLabel(ms) {
    if (ms < 1) return `${ms.toFixed(2)} mS`;
    if (ms < 10) return `${ms.toFixed(1)} mS`;
    return `${ms.toFixed(0)} mS`;
}

/// Nearest detent, measured in the log -- 3 ms is nearer to 3.48 than to 2.14
/// by ratio even though it is equidistant by subtraction. Used on the way in,
/// so a stored setting from a build with different detents still lands on one.
export function nearestColumnStep(ms) {
    // Not `indexOf(4)`: 128^(6/14) is 7.999999999999999, so the detent that
    // ought to be 4 is 3.9999999999999996 and `indexOf` returns -1 --
    // `COLUMN_STEPS[-1]` is undefined, and the whole close-up chain would then
    // be computing with it. The index is written down instead.
    const kDefault = 6;                       // 0.5 x 2^3 = 4 ms
    if (!(ms > 0)) return kDefault;
    let best = 0, bestD = Infinity;
    for (let i = 0; i < COLUMN_STEPS.length; ++i) {
        const d = Math.abs(Math.log(ms / COLUMN_STEPS[i]));
        if (d < bestD) { bestD = d; best = i; }
    }
    return best;
}

/// The engine's column time cannot go below this. It is columnMs / k for whole
/// k, so it is a ceiling on k -- and it is a real one: on the Mac, at 0.25 ms
/// the display managed one frame in a second.
export const MIN_ENGINE_MS = 0.05;
/// Narrower than this and there is nothing to look at.
export const MIN_CLOSE_UP_COLUMNS = 40;

/// Width in columns for a span at a given divisor.
export function closeUpWidth(spanMs, columnMs, k) {
    return Math.round(spanMs * k / columnMs);
}

/// The range of divisors that gives a legal strip, or null when the span
/// cannot be shown at all -- which is what greys it out on the menu.
export function closeUpDivisors(spanMs, columnMs, maxColumns) {
    if (!(spanMs > 0) || !(columnMs > 0) || maxColumns < MIN_CLOSE_UP_COLUMNS) {
        return null;
    }
    const kCap = Math.floor(columnMs / MIN_ENGINE_MS);
    if (kCap < 2) return null;
    const lo = Math.max(2, Math.ceil(MIN_CLOSE_UP_COLUMNS * columnMs / spanMs));
    const hi = Math.min(kCap, Math.floor(maxColumns * columnMs / spanMs));
    return lo <= hi ? [lo, hi] : null;
}

/// The legal width nearest the one asked for, and the divisor that gives it.
/// Null when the span cannot be shown.
export function closeUpFit(spanMs, columnMs, maxColumns, desiredColumns) {
    const ks = closeUpDivisors(spanMs, columnMs, maxColumns);
    if (!ks) return null;
    let bestK = ks[0], bestErr = Infinity;
    for (let k = ks[0]; k <= ks[1]; k++) {
        const e = Math.abs(closeUpWidth(spanMs, columnMs, k) - desiredColumns);
        if (e < bestErr) { bestErr = e; bestK = k; }
    }
    return { k: bestK, columns: closeUpWidth(spanMs, columnMs, bestK) };
}

/// Whether any close-up at all is possible at this Speed. A divisor of at
/// least two is what makes the strip finer than the main picture, and the
/// engine ceiling caps the divisor, so below 0.1 ms per column there is
/// nothing to be had.
export function closeUpAvailable(columnMs) {
    return Math.floor(columnMs / MIN_ENGINE_MS) >= 2;
}
