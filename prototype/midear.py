"""Human middle-ear transfer function, as three biquads.

Source: the digital implementation in Ibrahim (2012, Appendix), after Pascal
et al. (JASA 1998), as distributed in the Auditory Modeling Toolbox under
`middleearfilter(..., 'zilany2009')`.  Three second-order sections, obtained
by bilinear transform of analogue prototypes with pre-warping at 1 kHz.

The first section carries a zero at z = 1, so the DC gain of the chain is
exactly zero -- which is the property we are after.

Also included for comparison: the Puria (2003) M1 approximation used by
Verhulst et al., which is nothing more than a first-order Butterworth
bandpass; and a plain DC blocker.
"""
import numpy as np
from scipy.signal import butter, freqz, lfilter


def zilany2009_human(fs, fp=1000.0):
    """Returns a list of (b, a) biquads."""
    C = 2.0 * np.pi * fp / np.tan(np.pi * fp / fs)
    C2 = C * C

    m11 = 1.0 / (C2 + 5.9761e3 * C + 2.5255e7)
    m12 = -2.0 * C2 + 2 * 2.5255e7
    m13 = C2 - 5.9761e3 * C + 2.5255e7
    m14 = C2 + 5.6665e3 * C
    m15 = -2.0 * C2
    m16 = C2 - 5.6665e3 * C

    m21 = 1.0 / (C2 + 6.4255e3 * C + 1.3975e8)
    m22 = -2.0 * C2 + 2 * 1.3975e8
    m23 = C2 - 6.4255e3 * C + 1.3975e8
    m24 = C2 + 5.8934e3 * C + 1.7926e8
    m25 = -2.0 * C2 + 2 * 1.7926e8
    m26 = C2 - 5.8934e3 * C + 1.7926e8

    m31 = 1.0 / (C2 + 2.4891e4 * C + 1.2700e9)
    m32 = -2.0 * C2 + 2 * 1.27e9
    m33 = C2 - 2.4891e4 * C + 1.27e9
    m34 = 3.1137e3 * C + 6.9768e8
    m35 = 2 * 6.9768e8
    m36 = -3.1137e3 * C + 6.9768e8

    megainmax = 2.0
    return [
        (np.array([m14, m15, m16]) * m11, np.array([1.0, m11 * m12, m11 * m13])),
        (np.array([m24, m25, m26]) * m21, np.array([1.0, m21 * m22, m21 * m23])),
        (np.array([m34, m35, m36]) * m31 / megainmax,
         np.array([1.0, m31 * m32, m31 * m33])),
    ]


def puria_m1(fs, f_lo=600.0, f_hi=4000.0):
    b, a = butter(1, [f_lo / (fs / 2), f_hi / (fs / 2)], btype='bandpass')
    return [(b, a)]


def dc_block(fs, f_c=8.0):
    b, a = butter(1, f_c / (fs / 2), btype='highpass')
    return [(b, a)]


def response(sections, fs, f):
    w = 2.0 * np.pi * f / fs
    H = np.ones_like(f, dtype=complex)
    for b, a in sections:
        _, h = freqz(b, a, worN=w)
        H = H * h
    return H


def apply(sections, x):
    for b, a in sections:
        x = lfilter(b, a, x)
    return x


def normalise_at(sections, fs, f0=1000.0):
    """Scale so the chain is unity at f0 -- the display's exposure should not
    change just because a filter was inserted."""
    g = np.abs(response(sections, fs, np.array([f0])))[0]
    b, a = sections[0]
    return [(b / g, a)] + list(sections[1:])


if __name__ == '__main__':
    FS = 88200.0
    for name, sec in [('Ibrahim/Pascal human', zilany2009_human(FS)),
                      ('Puria M1 (600-4000)', puria_m1(FS)),
                      ('plain DC block 8 Hz', dc_block(FS))]:
        sec = normalise_at(sec, FS)
        f = np.array([0.0, 1.0, 5.0, 10.0, 20.0, 40.0, 80.0, 125.0, 250.0,
                      500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0])
        H = 20 * np.log10(np.maximum(np.abs(response(sec, FS, f)), 1e-30))
        print('\n%s  (normalised to 0 dB at 1 kHz)' % name)
        print('  ' + '  '.join('%6.0f' % v for v in f))
        print('  ' + '  '.join('%6.1f' % v for v in H))
        # exact DC
        dc = sum(b.sum() / a.sum() for b, a in [(b, a) for b, a in sec])
        prod = 1.0
        for b, a in sec:
            prod *= b.sum() / a.sum()
        print('  gain at exactly DC: %.3e' % abs(prod))
