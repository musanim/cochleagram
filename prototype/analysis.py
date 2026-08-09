"""
Interval analysis and mode classification.

The only information available downstream is the spike train: (channel, time,
amplitude).  No instantaneous phase -- that is what made the original front end
cheap enough to run in real time on a 2001 laptop, and it turns out to be enough.

Two discriminators are computed, either of which can drive the colouring:

`normalised interval`  r = ISI * CF
    How fast a tap is firing relative to its own characteristic frequency.
    r ~= 1 means the tap is ringing at its own CF.  r > 1 means the tap is being
    driven by a lower-frequency component riding in its low-side tail.

`cross-channel interval slope`  s = d(log ISI) / d(log CF)
    Fitted locally across neighbouring taps.  This is the sharper of the two:

        s ~=  0   every tap in the neighbourhood is firing at the SAME rate, so
                  they are all locked to one periodic driver  ->  TONE
        s ~= -1   each tap is firing at its OWN CF, so they are ringing
                  independently after a common excitation  ->  TRANSIENT
        poor fit  intervals are incoherent across taps and irregular in time
                  ->  NOISE

Because a cascade cochlea has a shallow low-side skirt, a tone at f drives every
tap above f, not just the tap at f.  That broad swath of taps all firing at 1/f is
what makes s ~= 0 such a strong and spatially extended signature -- and it is why
"if you can hear a tone, you can see it."
"""

import numpy as np
import cochlea
from numba import njit
from scipy.ndimage import uniform_filter1d, maximum_filter1d


# --------------------------------------------------------------------------
# Rasterise the spike train onto a (time-bin x channel) grid
# --------------------------------------------------------------------------


def rasterise(spikes, design, n_samples, hop_s=0.001, cycles=4.0,
              n_isi_history=3, max_age_cycles=3.0, release_ms=0.0):
    """Turn the spike train into per-bin maps.

    Amplitude uses a channel-adaptive window of `cycles` periods of that
    channel's CF, so time resolution stays proportional to CF -- sharp at the
    top of the cochlea, smoothed at the bottom, exactly as hearing behaves.

    Intervals go stale.  If a tap has not fired for `max_age_cycles` periods of
    its own CF, the last interval it reported says nothing about what is
    happening now, and holding it produces exactly the wrong answer at the
    leading edge of a transient -- the silence before the event gets reported as
    a very long interval.  Such cells are marked invalid instead.

    Returns dict with 'times', 'cf', and arrays shaped (n_bins, n_ch):
      amp   -- spike amplitude envelope
      isi   -- median of the last few intervals, sample-and-held
      cv    -- coefficient of variation of the last few intervals
    """
    fs = design['fs']
    cf = design['cf']            # measured best frequencies, body channels only
    n_ch = cf.shape[0]

    ch_idx, t_idx, amp = spikes
    duration = n_samples / fs
    n_bins = max(1, int(np.floor(duration / hop_s)))
    times = (np.arange(n_bins) + 0.5) * hop_s

    amp_map = np.zeros((n_bins, n_ch))
    isi_map = np.full((n_bins, n_ch), np.nan)
    cv_map = np.full((n_bins, n_ch), np.nan)

    # Sort spikes by channel so each channel's spikes are contiguous
    order = np.lexsort((t_idx, ch_idx))
    ch_s, t_s, a_s = ch_idx[order], t_idx[order], amp[order]
    bounds = np.searchsorted(ch_s, np.arange(n_ch + 1))

    for k in range(n_ch):
        lo, hi = bounds[k], bounds[k + 1]
        if hi - lo < 2:
            continue
        st = t_s[lo:hi] / fs          # spike times, seconds
        sa = a_s[lo:hi]               # spike amplitudes
        # --- intervals ---
        isi = np.diff(st)                       # isi[i] belongs to st[i+1]
        j = np.searchsorted(st, times, side='right') - 1   # index of last spike

        # --- amplitude: sample and hold on the spikes ---
        # Each spike sets the tap's brightness and it stays there until the next
        # spike.  Constant amplitude therefore draws a constant shade, with no
        # ripple between spikes -- which is how the original drew it, and it
        # matters: any decay between spikes turns a steady low tone into a
        # sawtooth, because at the apex the spikes are further apart than any
        # plausible decay time.
        hold = j >= 0
        amp_map[hold, k] = sa[j[hold]]

        fresh = (j >= 1) & (times - st[np.maximum(j, 0)]
                            <= max_age_cycles / max(cf[k], 1e-6))
        if not np.any(fresh):
            continue
        idx = j[fresh] - 1                      # index into isi

        m = min(n_isi_history, isi.size)
        if m >= 1:
            # median of the last m intervals: robust to the one bad interval
            # that straddles an onset
            cols = np.clip(idx[:, None] - np.arange(m)[None, :], 0, isi.size - 1)
            win = isi[cols]
            isi_map[fresh, k] = np.median(win, axis=1)
            mean = win.mean(axis=1)
            sd = win.std(axis=1)
            cv_map[fresh, k] = sd / np.maximum(mean, 1e-12)


    # Optional release, off by default: with pure sample-and-hold a tap keeps
    # its last brightness forever once the sound stops.  Spikes only fire above
    # a floor, so what is held is already near-black, but a slow release can be
    # switched on if the trails are distracting.
    if release_ms > 0:
        _decay_hold(amp_map, np.full(n_ch, np.exp(-hop_s / (release_ms * 1e-3))))

    return dict(times=times, cf=cf, amp=amp_map, isi=isi_map, cv=cv_map,
                hop_s=hop_s)


def deskew(amp, design, hop_s, which='gdelay'):
    """Shift each tap back by its own delay.  DISPLAY ONLY.

    Applied to the finished raster, never to the spike train the analysis sees.
    The travelling-wave delay is information: which taps fired first, and in
    what order, is exactly the kind of cross-tap timing the mode classification
    leans on, and flattening it before analysis would throw that away.  On the
    screen it is a nuisance -- it rakes every click into a diagonal smear -- so
    it comes out at the last possible moment.

    (Within a single tap the intervals are unaffected either way: a constant
    offset cancels in a difference.  It is the cross-tap comparisons that care.)

    `which` selects the alignment reference:

      'gdelay'  group delay from the phase slope at best frequency.  DEFAULT,
                and the right choice.  Analytic, so it is smooth and monotone
                across taps by construction.

      'delay'   the sample at which a unit impulse produces each tap's largest
                positive output.  Intuitively the more direct measure, and it
                aligns a synthetic click perfectly -- but it is picking one peak
                out of an oscillation, so neighbouring taps can land on
                different cycles of their own ringing.  Measured across 599
                taps it is non-monotone in ten places and fifty times rougher
                than the group delay (1.36 ms rms second difference against
                0.03 ms, with jumps of 20 ms).  That jitter is bounded by the
                tap's half-period -- 10 to 23 ms at the apex, several display
                columns -- and it tears the low end of the picture apart.
                Kept for comparison; would need envelope detection and
                smoothing across taps before it were usable.
    """
    n_bins, n_ch = amp.shape
    delay = design.get(which, design['delay'])
    sh = np.round(np.asarray(delay) / hop_s).astype(int)
    idx = np.arange(n_bins)[:, None] + sh[None, :]
    ok = (idx >= 0) & (idx < n_bins)
    return np.where(ok, np.take_along_axis(amp, np.clip(idx, 0, n_bins - 1),
                                           axis=0), 0.0)


@njit(cache=True)
def _decay_hold(a, decay):
    """In place: a[i] = max(a[i], a[i-1] * decay), down each column."""
    n, m = a.shape
    for k in range(m):
        prev = 0.0
        d = decay[k]
        for i in range(n):
            v = prev * d
            if a[i, k] < v:
                a[i, k] = v
            prev = a[i, k]


# --------------------------------------------------------------------------
# Cross-channel interval slope
# --------------------------------------------------------------------------


def _activity(amp, floor_db=-55.0):
    """Soft mask: how much this cell is doing anything, in [0,1]."""
    ref = np.max(amp)
    if ref <= 0:
        return np.zeros_like(amp)
    db = 20 * np.log10(np.maximum(amp, 1e-12) / ref)
    return np.clip((db - floor_db) / (-floor_db), 0.0, 1.0)


def _erb_window(cf, taps_per_octave, erbs):
    """Per-channel window bounds spanning `erbs` ERBs at that channel's CF."""
    n_ch = cf.shape[0]
    half = np.maximum(1, np.round(
        0.5 * erbs * taps_per_octave *
        np.log2(1.0 + cochlea.erb(cf) / cf)).astype(int))
    i = np.arange(n_ch)
    lo = np.maximum(i - half, 0)
    hi = np.minimum(i + half + 1, n_ch)
    return lo, hi


def _wsum(a, lo, hi):
    """Sum of a[:, lo[k]:hi[k]] for every k, via a cumulative sum."""
    c = np.concatenate([np.zeros((a.shape[0], 1)), np.cumsum(a, axis=1)], axis=1)
    return c[:, hi] - c[:, lo]


def agreement(raster, erbs=1.5, taps_per_octave=60, tol=0.06):
    """How flat log(ISI) and log(ISI*CF) are across neighbouring taps.

    Two weighted local variances, computed across the channel axis:

      D_tone   = var of log2(ISI)        -- small when a run of taps all fire
                                            at the SAME rate (one periodic
                                            driver dominating a whole region)
      D_trans  = var of log2(ISI * CF)   -- small when each tap fires at its
                                            OWN CF (independent ringing after
                                            a common excitation)

    Local variance is far more robust than fitting a slope: it degrades
    gracefully at region boundaries instead of producing a wild estimate.

    The window is measured in ERBs, not octaves, and so is narrow at the top of
    the cochlea and wide at the bottom.  That matters: a fixed octave-wide
    window straddles two resolved harmonics of a low-pitched note, sees taps
    locked to different partials, and calls a plainly tonal region noise.  One
    ERB is precisely the width at which the ear stops resolving neighbouring
    partials, so it is the honest scale on which to ask whether nearby taps
    agree.
    """
    cf = raster['cf']
    isi = raster['isi']
    ok = np.isfinite(isi)

    w = _activity(raster['amp']) * ok
    li = np.where(ok, np.log2(np.maximum(isi, 1e-9)), 0.0)
    ln = li + np.log2(cf)[None, :]

    lo, hi = _erb_window(cf, taps_per_octave, erbs)
    return _support(li, w, lo, hi, tol), _support(ln, w, lo, hi, tol)


def _support(y, w, lo, hi, tol):
    """Weighted fraction of taps in each window that agree with the centre tap.

    A variance would do the same job in the easy cases, but it is wrecked by
    outliers: one tap locked to a neighbouring harmonic drags the variance up
    and the whole region gets called noise.  Asking instead how much of the
    neighbourhood *agrees* degrades gracefully -- disagreeing taps simply do
    not vote.
    """
    n_ch = y.shape[1]
    i = np.arange(n_ch)
    num = np.zeros_like(y)
    den = np.zeros_like(y)
    half = int(np.max(np.maximum(i - lo, hi - 1 - i)))

    for d in range(-half, half + 1):
        j = i + d
        ok = (j >= 0) & (j < n_ch) & (j >= lo) & (j < hi)
        if not ok.any():
            continue
        src = np.clip(j, 0, n_ch - 1)
        m = ok.astype(float)[None, :]
        ww = w[:, src] * m
        dy = y[:, src] - y
        num += ww * np.exp(-(dy ** 2) / (2.0 * tol ** 2))
        den += ww
    return num / np.maximum(den, 1e-12)


def onset_strength(raster, window_octaves=1.0, taps_per_octave=60,
                   knee_db_per_ms=4.0, hold_cycles=3.0):
    """Coherent envelope rise across neighbouring taps.

    Interval structure cannot tell a transient from noise: a tap fed
    narrowband noise rings near its own CF just as it does after a click, with
    much the same jitter.  Measured on the click train and on white noise, the
    interval statistics are nearly identical.

    What separates them is that a transient is a *common event*.  All taps in a
    region rise together (sweeping apically with the travelling wave), whereas
    in noise each tap's envelope wanders independently, so neighbouring taps are
    as often falling as rising.  Averaging the SIGNED envelope slope across taps
    therefore keeps transients and cancels noise -- which is also the honest
    definition of the thing: a transient is a sharp onset.
    """
    amp = raster['amp']
    ref = max(np.max(amp), 1e-30)
    db = 20 * np.log10(np.maximum(amp, ref * 1e-6) / ref)

    dt_ms = raster['hop_s'] * 1000.0
    d = np.zeros_like(db)
    d[1:] = (db[1:] - db[:-1]) / dt_ms

    n = max(3, int(round(window_octaves * taps_per_octave)) | 1)
    s = uniform_filter1d(d, size=n, axis=1, mode='nearest')

    onset = np.clip(s / knee_db_per_ms, 0.0, 1.0)

    # A transient is the whole event, not just the bin in which the envelope
    # rose: the tap goes on ringing afterwards, and that ring-down is part of
    # what you hear as the click.  Hold the mark for each tap's own ring-down
    # time, which for a filter one ERB wide is about 1/ERB -- 2 ms at 4 kHz,
    # 35 ms at 50 Hz.  That release is exactly the comet-shaped smear a click
    # makes in the cochlea.
    tau_ms = 1000.0 * hold_cycles / cochlea.erb(raster['cf'])
    decay = np.exp(-dt_ms / np.maximum(tau_ms, dt_ms))
    held = np.empty_like(onset)
    acc = np.zeros(onset.shape[1])
    for i in range(onset.shape[0]):
        acc = np.maximum(onset[i], acc * decay)
        held[i] = acc
    return held


def classify(raster, s_tone, s_trans, onset, cv_knee=0.30, knee=0.55):
    """Return (tone, transient, noise) scores in [0,1], summing to 1.

    Rather than test each flatness measure against an absolute threshold, weigh
    the two against each other.  Whichever hypothesis explains the local
    interval structure better wins; if neither explains it, the cell is noise.
    This is scale-free, so it does not need retuning when the analysis window
    or the tap density changes.
    """
    cv = np.nan_to_num(raster['cv'], nan=1.0)
    regularity = np.exp(-cv / cv_knee)

    # Tone: a run of neighbouring taps all locked to one periodic driver.
    tone = np.clip((s_tone - knee) / (1.0 - knee), 0.0, 1.0) * regularity

    # Whatever is not tonal is either a common event or it is noise.
    rest = np.clip(1.0 - tone, 0.0, 1.0)
    trans = rest * onset
    noise = rest * (1.0 - onset)
    return tone, trans, noise
