"""Test signals chosen to expose what a cochleagram shows and an FFT does not."""

import numpy as np


def _t(dur, fs):
    return np.arange(int(dur * fs)) / fs


def modes(fs=48000):
    """Tone, clicks, noise -- separately, then all three together.

    The point of the last section is that an FFT shows one grey smear where the
    ear hears three distinct things.
    """
    seg = 0.6
    t = _t(seg, fs)
    tone = 0.6 * np.sin(2 * np.pi * 330 * t) * _fade(t, seg)

    clicks = np.zeros_like(t)
    for c in np.arange(0.05, seg, 0.12):
        i = int(c * fs)
        clicks[i:i + 8] = 0.9 * np.hanning(16)[:8][::-1]

    rng = np.random.default_rng(0)
    noise = 0.25 * rng.standard_normal(t.size) * _fade(t, seg)

    together = 0.5 * tone + 0.8 * clicks + 0.2 * noise
    gap = np.zeros(int(0.12 * fs))
    x = np.concatenate([tone, gap, clicks, gap, noise, gap, together])
    return x / np.max(np.abs(x)) * 0.9, fs


def vowel(fs=48000, f0=110.0, dur=0.9):
    """A glottal-pulse-driven vowel: the classic time/frequency double bind.

    Low in the cochlea the harmonics of f0 are individually resolved.  High in
    the cochlea the same signal is heard as a train of discrete glottal pulses
    at f0.  No single FFT window shows both -- a short one blurs the harmonics,
    a long one blurs the pulses.  The cochlea shows both at once because its
    time resolution scales with frequency.
    """
    n = int(dur * fs)
    t = np.arange(n) / fs
    # Glottal source: periodic pulse train with a soft rolloff
    src = np.zeros(n)
    period = fs / f0
    k = 0
    while int(k * period) < n:
        i = int(k * period)
        src[i] = 1.0
        k += 1
    # Formants for a schwa-ish /a/
    y = np.zeros(n)
    for fc, bw, g in [(700, 90, 1.0), (1220, 110, 0.6),
                      (2600, 160, 0.35), (3500, 220, 0.18)]:
        y += g * _resonate(src, fs, fc, bw)
    y *= _fade(t, dur)
    return y / np.max(np.abs(y)) * 0.9, fs


def pluck(fs=48000, f0=196.0, dur=1.2):
    """A plucked string: a broadband transient that resolves into harmonics.

    Shows the mode colouring doing something musically meaningful -- the attack
    reads as transient across the whole cochlea, then decays into a stack of
    tonal partials, with the high partials dying first.
    """
    n = int(dur * fs)
    t = np.arange(n) / fs
    y = np.zeros(n)
    for h in range(1, 25):
        f = f0 * h
        if f > fs / 2.5:
            break
        decay = np.exp(-t * (2.0 + 0.55 * h ** 1.4))
        y += (1.0 / h) * decay * np.sin(2 * np.pi * f * t + 0.0)
    # A little pick noise at the very start
    rng = np.random.default_rng(3)
    burst = rng.standard_normal(n) * np.exp(-t * 900.0) * 0.5
    y = y + burst
    return y / np.max(np.abs(y)) * 0.9, fs


def sweep_and_taps(fs=48000, dur=1.6):
    """A slow sweep crossed by regular taps -- tests both axes at once."""
    n = int(dur * fs)
    t = np.arange(n) / fs
    f0, f1 = 120.0, 4000.0
    phase = 2 * np.pi * f0 * dur / np.log(f1 / f0) * ((f1 / f0) ** (t / dur) - 1)
    y = 0.5 * np.sin(phase)
    for c in np.arange(0.15, dur, 0.25):
        i = int(c * fs)
        y[i:i + 6] += 0.9 * np.hanning(12)[:6][::-1]
    return y / np.max(np.abs(y)) * 0.9, fs


# --------------------------------------------------------------------------


def _resonate(x, fs, fc, bw):
    r = np.exp(-np.pi * bw / fs)
    theta = 2 * np.pi * fc / fs
    a1, a2 = -2 * r * np.cos(theta), r * r
    y = np.zeros_like(x)
    y1 = y2 = 0.0
    for i in range(x.size):
        v = x[i] - a1 * y1 - a2 * y2
        y[i] = v
        y2, y1 = y1, v
    return y * (1 - r)


def _fade(t, dur, ms=8.0):
    e = np.ones_like(t)
    k = int(ms * 1e-3 * (t.size / dur))
    if k > 1:
        w = np.hanning(2 * k)
        e[:k] = w[:k]
        e[-k:] = w[k:]
    return e
