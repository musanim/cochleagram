"""Rendering: cochleagrams and FFT spectrograms for side-by-side comparison."""

import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap
from scipy.signal import spectrogram


# --------------------------------------------------------------------------
# Level mapping
# --------------------------------------------------------------------------


def to_db(a, floor_db=-60.0):
    ref = np.max(a)
    if ref <= 0:
        return np.zeros_like(a)
    db = 20.0 * np.log10(np.maximum(a, 1e-12) / ref)
    return np.clip((db - floor_db) / (-floor_db), 0.0, 1.0)


# --------------------------------------------------------------------------
# Panels
# --------------------------------------------------------------------------


def fft_panel(ax, x, fs, nfft, flo, fhi, title, floor_db=-70.0):
    f, t, S = spectrogram(x, fs=fs, window='hann', nperseg=nfft,
                          noverlap=int(nfft * 0.875), mode='magnitude')
    keep = (f >= flo) & (f <= fhi)
    img = to_db(S[keep], floor_db)
    ax.pcolormesh(t, f[keep], img, cmap='magma', shading='nearest',
                  rasterized=True, vmin=0, vmax=1)
    ax.set_yscale('log')
    ax.set_ylim(flo, fhi)
    ax.set_title(title, fontsize=9, loc='left')
    _tidy(ax, flo, fhi)


def cochleagram_panel(ax, raster, title, floor_db=-70.0):
    cf = raster['cf']
    img = to_db(raster['amp'], floor_db).T          # (n_ch, n_bins)
    ax.pcolormesh(raster['times'], cf, img, cmap='magma', shading='nearest',
                  rasterized=True, vmin=0, vmax=1)
    ax.set_yscale('log')
    ax.set_ylim(cf.min(), cf.max())
    ax.set_title(title, fontsize=9, loc='left')
    _tidy(ax, cf.min(), cf.max())


def mode_panel(ax, raster, tone, trans, noise, title, floor_db=-70.0,
               gamma=0.75):
    """Mode-coloured cochleagram.

    Hue is the three-way classification -- transient red, tone blue, noise
    green -- and brightness is level.  Mixtures blend, so a struck string reads
    as a red edge resolving into blue harmonics, which is what you hear.
    """
    cf = raster['cf']
    v = to_db(raster['amp'], floor_db).T ** gamma
    r = np.clip(trans, 0, 1).T
    g = np.clip(noise, 0, 1).T
    b = np.clip(tone, 0, 1).T

    s = np.maximum(r + g + b, 1e-9)
    rgb = np.dstack([r / s, g / s, b / s])
    # Push toward full saturation so the classification stays legible, then
    # modulate by level.
    rgb = rgb / np.maximum(rgb.max(axis=2, keepdims=True), 1e-9)
    rgb = rgb * v[:, :, None]

    ax.pcolormesh(raster['times'], cf,
                  np.zeros_like(v), cmap='gray', vmin=0, vmax=1,
                  shading='nearest', rasterized=True)
    ax.imshow(rgb, origin='lower', aspect='auto',
              extent=[raster['times'][0], raster['times'][-1],
                      np.log10(cf.min()), np.log10(cf.max())],
              interpolation='nearest')
    ax.set_ylim(np.log10(cf.min()), np.log10(cf.max()))
    ax.set_title(title, fontsize=9, loc='left')
    _log_ticks(ax, cf.min(), cf.max(), already_log=True)


def _tidy(ax, flo, fhi):
    _log_ticks(ax, flo, fhi, already_log=False)


def _log_ticks(ax, flo, fhi, already_log):
    decades = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
    ticks = [d for d in decades if flo <= d <= fhi]
    labels = [(f'{d}' if d < 1000 else f'{d // 1000}k') for d in ticks]
    ax.set_yticks([np.log10(t) for t in ticks] if already_log else ticks)
    ax.set_yticklabels(labels)
    ax.set_ylabel('Hz', fontsize=8)
    ax.tick_params(labelsize=7)


def mode_legend(ax):
    from matplotlib.patches import Patch
    ax.legend(handles=[Patch(color=(1, 0.15, 0.15), label='transient'),
                       Patch(color=(0.2, 0.5, 1.0), label='tone'),
                       Patch(color=(0.2, 0.9, 0.3), label='noise')],
              loc='upper right', fontsize=7, framealpha=0.75,
              labelcolor='white', facecolor='#222222', edgecolor='none')
