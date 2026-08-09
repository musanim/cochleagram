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
