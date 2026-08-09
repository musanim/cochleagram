"""Measure the classifier's features against known ground truth."""

import numpy as np
import cochlea
import analysis
import signals
import make_figures as mf

REGIONS = [('tone', 0.05, 0.55), ('clicks', 0.78, 1.30),
           ('noise', 1.50, 2.00), ('mixture', 2.25, 2.70)]


def main():
    x, fs = signals.modes()
    design, raster, modes, feats = mf.build(x, fs)
    d_tone, d_trans, spread, onset = feats
    tone, trans, noise = modes
    t = raster['times']
    act = analysis._activity(raster['amp'])
    cv = np.nan_to_num(raster['cv'], nan=np.nan)

    print(f'spread (var of log2 CF across window) = {spread:.4f}'
          f'   sd = {np.sqrt(spread):.3f}\n')
    hdr = (f'{"region":>9}{"cells":>8}{"d_tone":>9}{"d_trans":>9}'
           f'{"cv":>8}{"onset":>7}{"ons90":>7}{"tone":>7}{"trans":>7}{"noise":>7}')
    print(hdr)
    for name, a, b in REGIONS:
        m = (t >= a) & (t <= b)
        sub = act[m] > 0.35
        if not sub.any():
            continue
        sel = lambda A: np.nanmedian(A[m][sub])
        p90 = lambda A: np.nanpercentile(A[m][sub], 90)
        print(f'{name:>9}{sub.sum():8d}{sel(d_tone):9.4f}{sel(d_trans):9.4f}'
              f'{sel(cv):8.3f}{sel(onset):7.2f}{p90(onset):7.2f}'
              f'{sel(tone):7.2f}{sel(trans):7.2f}{sel(noise):7.2f}')

    print('\nCV percentiles by region (the tone/transient vs noise cue):')
    for name, a, b in REGIONS:
        m = (t >= a) & (t <= b)
        sub = act[m] > 0.35
        v = cv[m][sub]
        v = v[np.isfinite(v)]
        if v.size == 0:
            continue
        q = np.percentile(v, [10, 25, 50, 75, 90])
        print(f'{name:>9}  ' + '  '.join(f'{p:.3f}' for p in q))


if __name__ == '__main__':
    main()
