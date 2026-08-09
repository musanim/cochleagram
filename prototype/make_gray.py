"""
Native-resolution greyscale cochleagram: one tap = one pixel.

The original display mapped each tap of the cascade to one row of pixels and
level to brightness, with no interpolation anywhere.  That is worth reproducing
exactly, because the fine vertical structure -- individual harmonics sitting one
or two taps apart -- is destroyed by any resampling of the image.

Usage:  python3 make_gray.py ../toych.wav [--scale 2] [--floor -60]
"""

import argparse
import os
import sys

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly, spectrogram
from PIL import Image

import cochlea
import analysis

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'figures')

F_LO = 20.0              # full 10 octaves of the cochlea, 600 taps
F_HI = 20000.0
TAPS_PER_OCT = 60
HOP_S = 0.001            # one pixel per millisecond


def to_gray(a, floor_db, gamma=1.0, invert=True, ref_pct=100.0):
    """Level -> 8-bit grey.

    Reference is a high percentile rather than the maximum: a single bright
    cell should not push everything else into the floor, which is what happens
    on real material with one loud transient in it.
    """
    ref = np.percentile(a, ref_pct) if ref_pct < 100 else np.max(a)
    if ref <= 0:
        ref = np.max(a)
    if ref <= 0:
        return np.zeros(a.shape, dtype=np.uint8)
    db = 20.0 * np.log10(np.maximum(a, 1e-12) / ref)
    v = np.clip((db - floor_db) / (-floor_db), 0.0, 1.0) ** gamma
    # Default is ink-on-paper: white silence, black at full level.
    if invert:
        v = 1.0 - v
    return np.round(v * 255).astype(np.uint8)


def save(img, path, scale=1):
    im = Image.fromarray(img, mode='L')
    if scale != 1:
        im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
    im.save(path)
    print(f'wrote {os.path.abspath(path)}   {im.width} x {im.height}')


def ruler(cf, marks=(50, 100, 200, 500, 1000, 2000, 5000, 10000), width=54):
    """A thin frequency scale, one row per tap, matching the image exactly."""
    from PIL import ImageDraw
    n = cf.shape[0]
    im = Image.new('L', (width, n), 255)
    d = ImageDraw.Draw(im)
    lg = np.log2(cf)
    for f in marks:
        if not (min(cf) <= f <= max(cf)):
            continue
        row = int(np.argmin(np.abs(lg - np.log2(f))))
        d.line([(width - 8, row), (width - 1, row)], fill=0)
        lab = f'{f}' if f < 1000 else f'{f // 1000}k'
        d.text((2, max(0, min(n - 10, row - 5))), lab, fill=40)
    return np.array(im)


def fft_reference(x, fs, nfft, cf, n_bins, floor_db):
    """Same audio, same pixel grid, as an FFT spectrogram on a log axis."""
    f, t, S = spectrogram(x, fs=fs, window='hann', nperseg=nfft,
                          noverlap=nfft - max(1, int(round(0.001 * fs))),
                          mode='magnitude')
    g = to_gray(S, floor_db).astype(float)
    # resample onto the cochleagram's exact tap rows and time columns
    rows = np.interp(np.log2(cf), np.log2(np.maximum(f, 1e-9)),
                     np.arange(f.size))
    cols = np.linspace(0, g.shape[1] - 1, n_bins)
    r = np.clip(np.round(rows).astype(int), 0, g.shape[0] - 1)
    c = np.clip(np.round(cols).astype(int), 0, g.shape[1] - 1)
    return g[np.ix_(r, c)].astype(np.uint8)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('wav')
    ap.add_argument('--scale', type=int, default=2)
    ap.add_argument('--floor', type=float, default=-45.0)
    ap.add_argument('--gamma', type=float, default=1.0)
    ap.add_argument('--f-lo', type=float, default=F_LO)
    ap.add_argument('--deskew', action='store_true')
    ap.add_argument('--cycles', type=float, default=2.0)
    ap.add_argument('--tag', default='')
    ap.add_argument('--hop-ms', type=float, default=HOP_S*1000)
    ap.add_argument('--f-hi', type=float, default=F_HI)
    ap.add_argument('--upsample', type=int, default=0)
    ap.add_argument('--no-compare', action='store_true')
    ap.add_argument('--tau-min-ms', type=float, default=3.0)
    args = ap.parse_args()

    x, fs = sf.read(args.wav)
    if x.ndim > 1:
        x = x.mean(axis=1)
    x = x - np.mean(x)

    # The top tap needs an octave of cascade above it, and that lead needs to
    # sit well below Nyquist -- so reaching 20 kHz from 44.1 kHz material means
    # resampling up.
    up = args.upsample or max(1, int(np.ceil(8.0 * args.f_hi / fs)))
    if up > 1:
        x = resample_poly(x, up, 1)
        fs = fs * up
    f_hi = min(args.f_hi, fs / 8.0)
    print(f'upsample x{up} -> {fs} Hz')

    design, bm, spikes = cochlea.analyse(
        x, fs, f_lo=args.f_lo, f_hi=f_hi, taps_per_octave=TAPS_PER_OCT)
    raster = analysis.rasterise(spikes, design, x.size, hop_s=args.hop_ms/1000.0,
                                cycles=args.cycles)
    if args.deskew:
        raster['amp'] = analysis.deskew(
            raster['amp'], design, raster['hop_s'])
    cf = design['cf']
    print(f'{cf.size} taps, {cf.min():.0f}-{cf.max():.0f} Hz, '
          f'{raster["times"].size} columns at {args.hop_ms:.2f} ms')

    # amp is (n_bins, n_ch) with channel 0 = highest CF, so transposing puts
    # high frequencies at the top -- one tap per row, no interpolation.
    img = to_gray(raster['amp'].T, args.floor, args.gamma)

    os.makedirs(OUT, exist_ok=True)
    base = os.path.splitext(os.path.basename(args.wav))[0]
    if args.deskew:
        base += '_deskew'
    base += args.tag

    save(img, os.path.join(OUT, f'{base}_gray.png'), scale=1)
    save(img, os.path.join(OUT, f'{base}_gray_{args.scale}x.png'),
         scale=args.scale)
    save(to_gray(raster['amp'].T, args.floor, args.gamma, invert=False),
         os.path.join(OUT, f'{base}_gray_onblack.png'), scale=args.scale)

    if args.no_compare:
        return
    # Side-by-side against two FFT windows, same pixel grid, same greyscale
    n_bins = img.shape[1]
    strip = ruler(cf)
    gap = np.full((6, n_bins + strip.shape[1]), 255, dtype=np.uint8)
    panels = [np.hstack([strip, img])]
    for nfft in (512, 8192):
        f_img = fft_reference(x, fs, nfft, cf, n_bins, args.floor)
        panels += [gap, np.hstack([strip, f_img])]
    save(np.vstack(panels), os.path.join(OUT, f'{base}_compare.png'),
         scale=args.scale)


if __name__ == '__main__':
    main()
