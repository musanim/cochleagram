"""Measure the cascade's actual tuning: peak gain, best frequency, bandwidth, delay."""

import sys
import numpy as np
import cochlea


def measure(design, n=1 << 16):
    fs = design['fs']
    imp = np.zeros(n)
    imp[0] = 1.0
    bm = cochlea.run_cascade(imp, design)
    F = np.fft.rfft(bm, axis=0)
    freqs = np.fft.rfftfreq(n, 1 / fs)
    mag = np.abs(F)

    rows = []
    for k in range(design['n_ch']):
        m = mag[:, k]
        i = int(np.argmax(m))
        pk = m[i]
        bf = freqs[i]
        half = pk / np.sqrt(2)
        lo = i
        while lo > 0 and m[lo] > half:
            lo -= 1
        hi = i
        while hi < m.size - 1 and m[hi] > half:
            hi += 1
        bw = freqs[hi] - freqs[lo]
        # group delay at BF from the phase slope
        ph = np.unwrap(np.angle(F[:, k]))
        j0, j1 = max(i - 8, 0), min(i + 8, ph.size - 1)
        gd = -(ph[j1] - ph[j0]) / (2 * np.pi * (freqs[j1] - freqs[j0]))
        # energy-weighted decay time of the impulse response
        e = bm[:, k] ** 2
        tot = e.sum()
        t = np.arange(n) / fs
        centroid = (e * t).sum() / max(tot, 1e-30)
        rows.append((design['cf'][k], bf, pk, bw, gd, centroid))
    return rows


def report(taps_per_octave, min_zeta, fs=48000, f_lo=40.0, f_hi=8000.0):
    d = cochlea.design_cascade(fs, f_lo=f_lo, f_hi=f_hi,
                               taps_per_octave=taps_per_octave,
                               min_zeta=min_zeta)
    rows = measure(d)
    print(f'\n=== taps/oct={taps_per_octave}  min_zeta={min_zeta}  '
          f'n_ch={d["n_ch"]} ===')
    print(f'{"CF":>8} {"BF":>8} {"peak":>9} {"BW":>8} {"BF/BW":>6} '
          f'{"ERB":>8} {"BW/ERB":>7} {"gdly ms":>8} {"cent ms":>8}')
    for k in range(0, d['n_ch'], max(1, d['n_ch'] // 12)):
        cf, bf, pk, bw, gd, cent = rows[k]
        erb = 24.7 * (4.37 * cf / 1000 + 1)
        print(f'{cf:8.0f} {bf:8.0f} {pk:9.2f} {bw:8.1f} {bf/max(bw,1e-9):6.1f} '
              f'{erb:8.1f} {bw/erb:7.2f} {gd*1000:8.1f} {cent*1000:8.1f}')
    return rows


if __name__ == '__main__':
    if len(sys.argv) > 1:
        for z in [float(a) for a in sys.argv[1:]]:
            report(60, z)
    else:
        report(15, 0.10)
        report(60, 0.10)
        report(60, 0.40)
