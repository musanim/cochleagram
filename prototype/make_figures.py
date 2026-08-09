"""Generate the side-by-side comparison figures."""

import os
import sys
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

import cochlea
import analysis
import render
import signals

OUT = os.path.join(os.path.dirname(__file__), '..', 'figures')
F_LO, F_HI = 50.0, 6000.0
TAPS_PER_OCT = 60


def build(x, fs, hop_s=0.001):
    x = x - np.mean(x)                      # keep DC out of the apex
    design, bm, spikes = cochlea.analyse(
        x, fs, f_lo=F_LO, f_hi=F_HI, taps_per_octave=TAPS_PER_OCT)
    raster = analysis.rasterise(spikes, design, x.size, hop_s=hop_s)
    s_tone, s_trans = analysis.agreement(raster, taps_per_octave=TAPS_PER_OCT)
    onset = analysis.onset_strength(raster, taps_per_octave=TAPS_PER_OCT)
    tone, trans, noise = analysis.classify(raster, s_tone, s_trans, onset)
    return design, raster, (tone, trans, noise), (s_tone, s_trans, onset)


def figure(name, x, fs, title, subtitle, hop_s=0.001, short=512, long=8192):
    design, raster, modes, _ = build(x, fs, hop_s)
    tone, trans, noise = modes

    fig, axes = plt.subplots(4, 1, figsize=(11, 11.5), sharex=True)
    fig.patch.set_facecolor('white')

    render.fft_panel(axes[0], x, fs, short, F_LO, F_HI,
                     f'FFT spectrogram, {short}-point window '
                     f'({1000*short/fs:.0f} ms) — sharp in time, blurred in frequency')
    render.fft_panel(axes[1], x, fs, long, F_LO, F_HI,
                     f'FFT spectrogram, {long}-point window '
                     f'({1000*long/fs:.0f} ms) — sharp in frequency, blurred in time')
    render.cochleagram_panel(axes[2], raster,
                             'Cochleagram — resolution follows the ear: '
                             'fine in frequency below, fine in time above')
    render.mode_panel(axes[3], raster, tone, trans, noise,
                      'Cochleagram, mode-coloured from spike intervals alone')
    render.mode_legend(axes[3])

    axes[-1].set_xlabel('seconds', fontsize=8)
    fig.suptitle(title, fontsize=13, x=0.012, ha='left', y=0.985)
    fig.text(0.012, 0.958, subtitle, fontsize=9, color='#555555', ha='left')
    fig.tight_layout(rect=[0, 0, 1, 0.95])

    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name + '.png')
    fig.savefig(path, dpi=140, facecolor='white')
    plt.close(fig)
    print('wrote', os.path.abspath(path))
    return path


def main():
    which = sys.argv[1:] or ['vowel', 'modes', 'pluck', 'sweep']

    if 'vowel' in which:
        x, fs = signals.vowel()
        figure('vowel', x, fs,
               'Resolved harmonics and resolved glottal pulses, at the same time',
               'A 110 Hz voiced vowel. Below ~1 kHz the individual harmonics are '
               'separate; above it, the same signal is a train of discrete pulses. '
               'No single FFT window shows both.')

    if 'modes' in which:
        x, fs = signals.modes()
        figure('modes', x, fs,
               'Tone, transient and noise, classified from spike intervals',
               'A 330 Hz tone, a click train, a noise burst — then all three at '
               'once. In the last section the FFT shows one smear; the ear hears '
               'three things, and so does the cochleagram.')

    if 'pluck' in which:
        x, fs = signals.pluck()
        figure('pluck', x, fs,
               'A plucked string: attack, then partials',
               'The attack reads as transient across the whole cochlea, then '
               'resolves into tonal partials that decay from the top down.',
               hop_s=0.0008)

    if 'sweep' in which:
        x, fs = signals.sweep_and_taps()
        figure('sweep', x, fs,
               'A sweep crossed by taps',
               'Both axes exercised at once: a continuous frequency glide and '
               'repeated broadband impulses.')


if __name__ == '__main__':
    main()
