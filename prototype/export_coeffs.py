"""Export a calibrated cascade as a binary coefficient file for the C++ core.

Calibration is a design-time step, not a runtime one: it takes a few seconds and
a dozen iterations of measuring the analytic cascade response.  The real-time
app has no business doing that at launch, so we bake the result here and ship it
as a resource.

    python3 export_coeffs.py --fs 88200 --out ../xcode/Cochleagram/Sources/CochleagramApp/Resources

The files this writes are **version 1**, and are not finished.  The `gdelay`
they carry is the analytic group delay -- what the poles say -- and the engine
measures its own replacement at load, which costs about 200 ms per engine build
and gives each machine a slightly different answer.  Follow every export with

    xcode/Cochleagram/tools/bakeall.sh

on the machine whose arithmetic should be canonical.  That runs the engine's
measurement once and writes the result in, stamping version 2, after which no
machine measures anything.  See OPEN-QUESTIONS.md.

File layout (little-endian):

    char[4]   'COCH'
    int32     version = 1
    float64   fs                 -- internal (post-upsample) sample rate
    int32     n_ch               -- total stages, including lead-in
    int32     n_lead             -- lead-in stages, not displayed
    int32     taps_per_octave
    float64   a0[n_ch], c0[n_ch], h[n_ch], r[n_ch], g[n_ch], norm[n_ch]
    float64   bf[n_body]         -- best frequency of each displayed tap
    float64   gdelay[n_body]     -- group delay, seconds (display de-skew)
    float64   idelay[n_body]     -- impulse-peak delay, seconds (alternative)
"""

import argparse
import os
import struct

import numpy as np

import cochlea


def export(path, fs, f_lo, f_hi, taps_per_octave, lead_octaves, erb_scale):
    d = cochlea.calibrate(fs, f_lo=f_lo, f_hi=f_hi,
                          taps_per_octave=taps_per_octave, erb_scale=erb_scale,
                          lead_octaves=lead_octaves, iters=20, verbose=True)
    n_ch, n_lead = d['n_ch'], d['n_lead']
    cf = d['cf']

    with open(path, 'wb') as f:
        f.write(b'COCH')
        f.write(struct.pack('<i', 1))
        f.write(struct.pack('<d', float(fs)))
        f.write(struct.pack('<iii', n_ch, n_lead, taps_per_octave))
        for k in ('a0', 'c0', 'h', 'r', 'g', 'norm'):
            f.write(np.ascontiguousarray(d[k], dtype='<f8').tobytes())
        f.write(np.ascontiguousarray(cf, dtype='<f8').tobytes())
        f.write(np.ascontiguousarray(d['gdelay'], dtype='<f8').tobytes())
        f.write(np.ascontiguousarray(d['delay'], dtype='<f8').tobytes())

    err = np.abs(np.log2(d['bw'] / (erb_scale * cochlea.erb(cf))))
    print(f'\nwrote {os.path.abspath(path)}')
    print(f'  {n_ch} stages ({n_lead} lead-in, {cf.size} displayed)')
    print(f'  best frequency {cf.min():.1f} - {cf.max():.0f} Hz')
    print(f'  bandwidth {erb_scale:.2f} x ERB: rms log2 error '
          f'{np.sqrt((err**2).mean()):.4f}')
    print(f'  group delay {d["gdelay"].min()*1000:.2f} - '
          f'{d["gdelay"].max()*1000:.1f} ms')
    print(f'  cost at {fs} Hz: {n_ch*fs/1e6:.1f} M stage-updates/s')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--fs', type=float, default=88200.0,
                    help='internal rate; 2x 44.1k reaches 20 kHz comfortably')
    ap.add_argument('--f-lo', type=float, default=20.0)
    ap.add_argument('--f-hi', type=float, default=20000.0)
    ap.add_argument('--taps', type=int, default=60)
    # The tuning sharpness, as a multiple of one ERB. 1.0 is the
    # psychoacoustic standard; below it the filters are sharper than human
    # hearing and resolve more harmonics, which is legible rather than
    # faithful. See the note in the app's README.
    ap.add_argument('--erb-scale', type=float, action='append', default=None,
                    help='repeatable; one file is written per value')
    ap.add_argument('--lead-octaves', type=float, default=0.5)
    # Where the app actually reads it from, resolved against this script
    # rather than the shell's working directory. It used to default to '.',
    # which quietly wrote the file next to wherever you happened to be
    # standing: the export succeeded, said so, and the app went on using the
    # old coefficients.
    ap.add_argument('--out', default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        '..', 'xcode', 'Cochleagram', 'Sources', 'CochleagramApp', 'Resources'))
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    scales = args.erb_scale or [1.0]
    for scale in scales:
        # The scale is in the filename, two decimals, so the app can find a
        # tuning by name and so a directory listing says what is in it.
        name = f'cochlea_{int(args.fs)}_erb{round(scale * 100):03d}.coch'
        export(os.path.join(args.out, name), args.fs, args.f_lo, args.f_hi,
               args.taps, args.lead_octaves, scale)

    # Said every time, because a version-1 file works -- it just measures its
    # de-skew curve at every engine build, on every machine, which is the thing
    # baking exists to stop. Nothing downstream complains, so the reminder has
    # to be here.
    print('\nThese are version 1. Run xcode/Cochleagram/tools/bakeall.sh on '
          'the\ncanonical machine to bake the de-skew curves in.')


if __name__ == '__main__':
    main()
