"""Render a wav the way the macOS app renders it, using the Python prototype.

`make_gray.py` answers "what should the cochleagram look like": 1 ms per pixel,
the whole picture normalised to its own maximum, designed at 176.4 kHz.  The
app answers a different question -- what can be drawn live -- and every one of
those three differs.  Comparing the app against a make_gray figure therefore
compares four changes at once, which is how an exposure difference spent an
afternoon impersonating a filter bug.

This renders the app's picture from the prototype's cascade, so the only thing
that differs is the implementation:

  * the design the coefficients were baked from -- 88.2 kHz internal,
    half an octave of lead-in (`export_coeffs.py` defaults), not make_gray's
    176.4 kHz and full octave;
  * 4 ms per column, not 1 ms;
  * auto-gain -- a reference that follows the loudest tap upward instantly and
    decays back over a halflife, rather than the maximum of the whole picture,
    which no live display can know.

    python3 appview.py ../video/thefrequencyscaleislogarithmic.wav

`--cycles` switches on the channel-adaptive amplitude window that
`analysis.rasterise` documents but no longer applies: a one-pole whose time
constant is that many periods of each tap's own best frequency.  0 is the
current behaviour -- pure sample-and-hold, every tap showing the raw height of
its last spike.
"""

import argparse
import os
import sys

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly
from PIL import Image

import cochlea
import analysis
import midear

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'figures')


def auto_gain_reference(amp, col_s, halflife=3.0, floor=1e-7, start=1e-6):
    """The app's auto-gain, column by column: instant attack, slow release.

    An absolute reference leaves the screen blank for anything not near full
    scale, which is most real material -- so the display follows the loudest
    tap up the moment it rises and decays back afterwards.  The consequence,
    and the reason this function exists, is that a quiet passage gets wound up
    until its texture is visible, where a whole-picture normalisation would
    have left it white.

    `amp` is (n_taps, n_columns).  Returns one reference per column.
    """
    decay = np.exp(-np.log(2.0) * col_s / max(halflife, 1e-3))
    loudest = amp.max(axis=0)
    ref = np.empty_like(loudest)
    acc = start
    for i, v in enumerate(loudest):
        acc = v if v > acc else max(acc * decay, floor)
        ref[i] = acc
    return ref


def one_pole_window(amp, cf, col_s, cycles):
    """Smooth each tap over `cycles` periods of its own best frequency.

    Spike amplitudes are not steady: within a single glottal pulse a tap's
    ringing swells and dies, so consecutive peaks differ by a lot.  Sample and
    hold shows that jitter raw -- a tap goes dark, then near-white, one column
    to the next -- which is the white streaking through the picture.  Averaging
    over a few of the tap's own cycles shows the envelope instead, and being
    proportional to CF it stays sharp at the base and smooths at the apex,
    which is how hearing behaves.
    """
    tau = np.maximum(cycles / np.maximum(cf, 1e-9), col_s)
    alpha = np.exp(-col_s / tau)
    out = np.empty_like(amp)
    acc = amp[:, 0].copy()
    for i in range(amp.shape[1]):
        acc = amp[:, i] + alpha * (acc - amp[:, i])
        out[:, i] = acc
    return out


def to_bytes(amp, ref, floor_db, inverted=False):
    """`levelToByte` from cochlea.cpp, applied to a whole picture at once."""
    db = 20.0 * np.log10(np.maximum(amp, 1e-12) / np.maximum(ref, 1e-12))
    u = np.clip((db - floor_db) / (-floor_db), 0.0, 1.0)
    if not inverted:
        u = 1.0 - u                      # white paper, dark ink
    return np.round(u * 255).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('wav')
    ap.add_argument('--column-ms', type=float, default=4.0,
                    help="app's Time slider; 0.5 to 64")
    ap.add_argument('--column-samples', type=float, default=0.0,
                    help='set the column width in input samples instead of '
                         'milliseconds; 1 gives one column per sample of the '
                         'file. Overrides --column-ms. Note the cascade runs '
                         'at twice the file rate, so 0.5 is the finest grid '
                         'that carries any new information.')
    ap.add_argument('--floor', type=float, default=-35.0,
                    help="app's Level slider, negated")
    ap.add_argument('--cycles', type=float, default=0.0,
                    help='amplitude window, in periods of each tap CF; '
                         '0 = pure sample-and-hold, as now')
    ap.add_argument('--middle-ear', action='store_true',
                    help='insert the human middle-ear transfer function ahead '
                         'of the cascade (see midear.py). Its DC gain is '
                         'exactly zero, which is what stops a constant input '
                         'painting the apex taps dark')
    ap.add_argument('--no-auto-gain', action='store_true',
                    help='use a fixed reference of --ref-db instead')
    ap.add_argument('--ref-db', type=float, default=0.0)
    ap.add_argument('--halflife', type=float, default=3.0)
    ap.add_argument('--no-deskew', action='store_true')
    ap.add_argument('--invert', action='store_true')
    ap.add_argument('--scale', type=int, default=1)
    ap.add_argument('--center', type=float, default=1.0,
                    help='keep only this fraction of columns, from the middle. '
                         'A fine grid makes a picture too wide to read whole; '
                         'cropping after the cascade has run means the auto-'
                         'gain and the filter state are still those of the '
                         'whole recording, not of an excerpt.')
    ap.add_argument('--mark-tap', default='',
                    help='comma-separated tap indices to rule in red, for '
                         'counting taps in a zoom; tap 0 is the highest CF')
    ap.add_argument('--mark-edges', action='store_true',
                    help='draw the marks as short ticks at the two edges '
                         'rather than all the way across, so the marked tap '
                         'is still visible')
    ap.add_argument('--tag', default='')
    ap.add_argument('--out', default=None)
    args = ap.parse_args()

    x, fs = sf.read(args.wav)
    if x.ndim > 1:
        x = x.mean(axis=1)
    x = x - np.mean(x)
    input_rate = fs

    # The app's internal rate, reached the same way: 2x the host rate.
    x = resample_poly(x, 2, 1)
    fs = fs * 2

    if args.middle_ear:
        sections = midear.normalise_at(midear.zilany2009_human(fs), fs)
        x = midear.apply(sections, x)

    if args.column_samples > 0:
        args.column_ms = 1000.0 * args.column_samples / input_rate

    # The design the shipped coefficient file was baked from.
    design, _, spikes = cochlea.analyse(x, fs, f_lo=20.0, f_hi=20000.0,
                                        taps_per_octave=60, lead_octaves=0.5)
    col_s = args.column_ms / 1000.0
    raster = analysis.rasterise(spikes, design, x.size, hop_s=col_s)
    if not args.no_deskew:
        raster['amp'] = analysis.deskew(raster['amp'], design, col_s)

    amp = raster['amp'].T                # (n_taps, n_columns), tap 0 highest CF
    cf = design['cf']

    if args.cycles > 0:
        amp = one_pole_window(amp, cf, col_s, args.cycles)

    if args.no_auto_gain:
        ref = np.full(amp.shape[1], 10.0 ** (args.ref_db / 20.0))
    else:
        ref = auto_gain_reference(amp, col_s, args.halflife)

    # Crop before the level mapping, not after. The mapping allocates two more
    # arrays the size of the picture, and at one column per sample the picture
    # is 88,200 columns; cropping first is the difference between 400 MB and
    # 2.5 GB. The result is identical -- auto-gain is causal and has already
    # been run over the whole recording above.
    n_full = amp.shape[1]
    if 0 < args.center < 1.0:
        keep = max(1, int(round(n_full * args.center)))
        lo = (n_full - keep) // 2
        amp, ref = amp[:, lo:lo + keep], ref[lo:lo + keep]
        print(f'  cropped to columns {lo}-{lo + keep} of {n_full}  '
              f'({lo * col_s:.4f} to {(lo + keep) * col_s:.4f} s)')

    img = to_bytes(amp, ref[None, :], args.floor, args.invert)

    # Fiducials. Drawn before any --scale resize, which is NEAREST, so a mark
    # stays exactly one tap thick however far the picture is magnified.
    marks = [int(t) for t in args.mark_tap.split(',') if t.strip()]
    if marks:
        rgb = np.repeat(img[:, :, None], 3, axis=2)
        for t in marks:
            if not 0 <= t < rgb.shape[0]:
                print(f'  tap {t} is outside 0..{rgb.shape[0] - 1}, skipped')
                continue
            if args.mark_edges:
                w = max(6, rgb.shape[1] // 60)
                rgb[t, :w] = rgb[t, -w:] = (255, 0, 0)
            else:
                rgb[t, :] = (255, 0, 0)
            print(f'  marked tap {t}: CF {cf[t]:.1f} Hz, '
                  f'group delay {design["gdelay"][t] * 1000:.1f} ms, '
                  f'de-skew shift {round(design["gdelay"][t] / col_s)} columns')
        img = rgb

    base = os.path.splitext(os.path.basename(args.wav))[0]
    name = (f'{base}_appview_{args.column_ms:g}ms'
            f'_{"hold" if args.cycles <= 0 else f"win{args.cycles:g}"}'
            f'{args.tag}.png')
    path = args.out or os.path.join(OUT, name)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    im = Image.fromarray(img, mode='RGB' if img.ndim == 3 else 'L')
    if args.scale != 1:
        im = im.resize((im.width * args.scale, im.height * args.scale),
                       Image.NEAREST)
    im.save(path)

    stat = img if img.ndim == 2 else img[:, :, 0]
    d = np.abs(np.diff(stat.astype(float), axis=1))
    print(f'{amp.shape[0]} taps x {n_full} columns at '
          f'{args.column_ms:.5g} ms '
          f'({args.column_ms * input_rate / 1000:.3g} input samples per '
          f'column), {cf.min():.0f}-{cf.max():.0f} Hz')
    print(f'  reference {"auto-gain" if not args.no_auto_gain else f"{args.ref_db} dB"}, '
          f'floor {args.floor} dB, '
          f'window {"off" if args.cycles <= 0 else f"{args.cycles:g} cycles"}')
    print(f'  mean {img.mean():.1f}, roughness |dt| {d.mean():.2f}, '
          f'hard jumps >60 {(d > 60).mean():.4f}')
    print(f'  wrote {os.path.abspath(path)}')


if __name__ == '__main__':
    main()
