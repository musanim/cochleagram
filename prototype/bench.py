"""How much CPU does the cascade actually cost?

Reports throughput in stage-updates per second, then converts that into a
real-time budget for the two possible structures:

  FLAT       every stage runs at the full sample rate.  Simple; what this
             prototype does.  Cost = n_taps * fs.

  MULTIRATE  the structure of US 7,076,315 (expired): each octave runs at half
             the rate of the octave above it, so cost is
             taps_per_octave * fs * (1 + 1/2 + 1/4 + ...) -> 2 * taps_per_octave
             * fs, independent of how many octaves you have.  For 10 octaves
             that is a 5x saving, and it is why the original ran on the
             hardware of the day.
"""

import time
import numpy as np

import cochlea


def bench(fs=176400, f_lo=20.0, f_hi=20000.0, taps=60, seconds=2.0):
    d = cochlea.calibrate(fs, f_lo=f_lo, f_hi=f_hi, taps_per_octave=taps)
    n = int(seconds * fs)
    x = np.random.default_rng(0).standard_normal(n) * 0.1

    cochlea.stream_spikes(x[:4096], d)          # warm up the JIT

    t0 = time.perf_counter()
    sp = cochlea.stream_spikes(x, d)
    dt = time.perf_counter() - t0

    n_ch = d['n_ch']
    updates = n_ch * n * 2          # two passes: level scan, then peak scan
    print(f'  {n_ch} stages, {seconds:.0f} s at {fs} Hz')
    print(f'  wall time            {dt*1000:8.1f} ms  '
          f'({seconds/dt:.1f}x real time, single core, two passes)')
    print(f'  throughput           {updates/dt/1e6:8.1f} M stage-updates/s')
    print(f'  spikes emitted       {sp[0].size/1e6:8.2f} M  '
          f'({sp[0].size/seconds/1e6:.2f} M/s)')
    return updates / dt


def budget(rate):
    print(f'\n  Real-time cost at {rate/1e6:.0f} M stage-updates/s, one core:\n')
    print(f'  {"structure":<12}{"input fs":>10}{"taps":>7}{"updates/s":>13}'
          f'{"cores":>8}')
    rows = [
        ('flat',      176400, 600, 176400 * 600),
        ('flat',       96000, 600,  96000 * 600),
        ('flat',       48000, 480,  48000 * 480),
        ('multirate',  44100, 600,  44100 * 60 * 2),
        ('multirate',  96000, 600,  96000 * 60 * 2),
    ]
    for name, sr, tp, cost in rows:
        print(f'  {name:<12}{sr:>10}{tp:>7}{cost/1e6:>12.1f}M{cost/rate:>8.3f}')


if __name__ == '__main__':
    print('\nMeasured (this machine, numba, single thread):')
    r = bench()
    budget(r)
    print('\n  Note: the cascade is a pipeline, not a parallel array -- stage k+1'
          '\n  consumes stage k\'s output, so channels cannot be split across'
          '\n  cores within a sample.  It parallelises by giving each core a'
          '\n  contiguous run of stages and handing off a block at a time, which'
          '\n  costs one block of latency per segment.')
