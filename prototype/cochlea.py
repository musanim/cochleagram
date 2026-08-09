"""
Cochlea filter cascade + spike extraction.

Structure follows the classic cascade-filterbank cochlea model (Lyon & Mead 1988;
Lyon, "Human and Machine Hearing", 2017; Google CARFAC, Apache-2.0), parameterised
the way Audience's Fast Cochlea Transform was: log-spaced taps at 60 per octave.
US 7,076,315 (the FCT patent) lapsed in 2018; the cascade design itself is
public-domain prior art going back to the 1980s.  See ../IP-landscape.md.

Signal flow: audio enters at the basal (high-CF) end and ripples down the cascade.
Each stage is a two-pole/two-zero asymmetric resonator with unity DC gain, so low
frequencies pass through untouched while each stage progressively removes content
above its own characteristic frequency.  The cascade output at stage k is therefore
bandpass with a peak at CF_k, a steep high-side skirt (the accumulated cascade) and
a shallow low-side tail -- the asymmetric shape real cochlear tuning curves have,
and the reason a low-frequency tone still drives every tap above it.

DAMPING CALIBRATION.  Tuning in a cascade is a *cumulative* property: bandwidth at
a given place depends on every stage basal to it.  Put 60 stages in an octave
instead of the ~15 a conventional design uses and each stage must contribute
proportionally less, or the cascade runs away -- at the textbook damping of
zeta=0.1, 60 taps/octave gives peak gains around 1e19 and 400 ms of group delay at
the apex.  Rather than hand-tune, `calibrate` measures the realised bandwidth of
every channel from the cascade's own impulse response and iteratively adjusts
per-channel damping until each channel's bandwidth matches one ERB at its best
frequency (Glasberg & Moore 1990).  Result is a filterbank whose tuning matches
human tuning by construction, at whatever tap density you ask for.

Hair-cell output is reduced to spikes: positive local maxima of each tap's
waveform, recorded as (time, amplitude).  That is all the downstream analysis gets
-- no instantaneous phase -- matching the original real-time system.
"""

import hashlib
import os
import numpy as np
from numba import njit

CACHE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.cache')


def erb(f):
    """Glasberg & Moore (1990) equivalent rectangular bandwidth, Hz."""
    return 24.7 * (4.37 * np.asarray(f) / 1000.0 + 1.0)


# --------------------------------------------------------------------------
# Filterbank design
# --------------------------------------------------------------------------


def design_cascade(fs, f_lo=40.0, f_hi=None, taps_per_octave=60,
                   zeta=0.35, lead_octaves=1.0, zero_ratio=np.sqrt(2.0),
                   poles=None):
    """Design a log-spaced cascade of asymmetric resonators.

    `lead_octaves` of extra stages are placed above `f_hi`.  They are not
    displayed; they exist so the topmost displayed channel has some cascade
    above it and is properly bandpass rather than wide open.

    Channels are ordered basal (high CF) to apical (low CF) -- the order the
    signal traverses.  `n_lead` of them are lead-in.
    """
    if f_hi is None:
        f_hi = fs / 8.0

    n_lead = int(round(lead_octaves * taps_per_octave))
    n_body = int(round(np.log2(f_hi / f_lo) * taps_per_octave)) + 1
    n_ch = n_lead + n_body

    top = f_hi * 2.0 ** (lead_octaves)
    if poles is None:
        cf_all = top * 2.0 ** (-np.arange(n_ch) / taps_per_octave)
    else:
        cf_all = np.asarray(poles, dtype=float)
        n_ch = cf_all.shape[0]

    zeta = np.broadcast_to(np.asarray(zeta, dtype=float), (n_ch,)).copy()

    theta = cf_all * (2.0 * np.pi / fs)
    a0 = np.cos(theta)
    c0 = np.sin(theta)
    h = c0 * (zero_ratio ** 2 - 1.0)
    r = np.clip(1.0 - zeta * theta, 0.05, 0.9999)
    g = (1.0 - 2.0 * r * a0 + r ** 2) / (1.0 - 2.0 * r * a0 + h * r * c0 + r ** 2)

    return dict(fs=fs, cf_all=cf_all, cf=cf_all[n_lead:], n_ch=n_ch,
                target=top * 2.0 ** (-np.arange(n_ch) / taps_per_octave),
                n_lead=n_lead, taps_per_octave=taps_per_octave, zeta=zeta,
                zero_ratio=zero_ratio, a0=a0, c0=c0, h=h, r=r, g=g,
                norm=np.ones(n_ch))


def _respec(design):
    """Rebuild coefficients after zeta has been changed in place."""
    return design_cascade(design['fs'], f_lo=design['cf'][-1],
                          f_hi=design['cf'][0],
                          taps_per_octave=design['taps_per_octave'],
                          zeta=design['zeta'], lead_octaves=0.0,
                          zero_ratio=design['zero_ratio'])


# --------------------------------------------------------------------------
# Cascade runner  (per-sample ripple down the chain -- no delay between stages)
# --------------------------------------------------------------------------


@njit(cache=True, fastmath=True)
def _run_cascade(x, a0, c0, h, r, g, norm, out):
    n_ch = a0.shape[0]
    z1 = np.zeros(n_ch)
    z2 = np.zeros(n_ch)
    for n in range(x.shape[0]):
        in_out = x[n]
        for k in range(n_ch):
            nz1 = r[k] * (a0[k] * z1[k] - c0[k] * z2[k])
            nz2 = r[k] * (c0[k] * z1[k] + a0[k] * z2[k])
            nz1 += in_out
            zY = h[k] * nz2
            in_out = g[k] * (in_out + zY)
            z1[k] = nz1
            z2[k] = nz2
            out[n, k] = in_out * norm[k]
    return out


def run_cascade(x, design, include_lead=False):
    """Run audio through the cascade. Returns (n_samples, n_ch) float array."""
    x = np.ascontiguousarray(x, dtype=np.float64)
    out = np.empty((x.shape[0], design['n_ch']), dtype=np.float64)
    _run_cascade(x, design['a0'], design['c0'], design['h'],
                 design['r'], design['g'], design['norm'], out)
    return out if include_lead else out[:, design['n_lead']:]


# --------------------------------------------------------------------------
# Automatic damping calibration
# --------------------------------------------------------------------------


def _stage_response(z, r, a0, c0, h, g):
    """Exact transfer function of one CAR stage, evaluated on the unit circle.

        H(z) = g * (z^2 - 2 r a0 z + r^2 + h r c0 z) / (z^2 - 2 r a0 z + r^2)

    Two poles at radius r and angle theta, two zeros pulled above them by the
    h term.  By construction H(1) = 1, which is what makes the cascade
    transparent to frequencies below every stage's CF.
    """
    d = z * z - 2.0 * r * a0 * z + r * r
    return g * (d + h * r * c0 * z) / d


def _measure(design, n_freq=1 << 14):
    """Analytic cascade response -> (best freq, peak gain, -3 dB BW, delay).

    Measuring this from a simulated impulse response is the obvious approach
    and it fails at the apex: resolving a 20 Hz channel one ERB wide needs a
    transform long enough that, at the sample rate required to reach 20 kHz at
    the other end, the response array runs past a gigabyte.  The cascade's
    transfer function is just a running product of per-stage biquads, so
    evaluate it directly on a log-spaced frequency grid instead -- exact, and
    a few million flops.
    """
    fs = design['fs']
    f = np.geomspace(max(2.0, fs * 1e-5), fs * 0.499, n_freq)
    w = 2.0 * np.pi * f / fs
    z = np.exp(1j * w)

    n_ch = design['n_ch']
    bf = np.empty(n_ch)
    pk = np.empty(n_ch)
    bw = np.empty(n_ch)
    delay = np.empty(n_ch)

    acc = np.ones(n_freq, dtype=np.complex128)
    lf = np.log(f)
    for k in range(n_ch):
        acc = acc * _stage_response(z, design['r'][k], design['a0'][k],
                                    design['c0'][k], design['h'][k],
                                    design['g'][k])
        mag = np.abs(acc)
        i = int(np.argmax(mag))
        pk[k] = mag[i]
        bf[k] = f[i]

        half = pk[k] / np.sqrt(2.0)
        lo = i
        while lo > 0 and mag[lo] > half:
            lo -= 1
        hi = i
        while hi < n_freq - 1 and mag[hi] > half:
            hi += 1
        bw[k] = f[hi] - f[lo]

        # Group delay at best frequency, from the phase slope.
        j0, j1 = max(i - 4, 0), min(i + 4, n_freq - 1)
        if j1 > j0:
            ph = np.unwrap(np.angle(acc[j0:j1 + 1]))
            delay[k] = -(ph[-1] - ph[0]) / (2 * np.pi * (f[j1] - f[j0]))
        else:
            delay[k] = 0.0
    delay = np.maximum(delay, 0.0)
    return bf, pk, bw, delay


@njit(cache=True, fastmath=True)
def _impulse_peak(a0, c0, h, r, g, norm, n, peak, idx):
    """Feed a unit impulse in; record when each tap's output peaks."""
    n_ch = a0.shape[0]
    z1 = np.zeros(n_ch)
    z2 = np.zeros(n_ch)
    for t in range(n):
        in_out = 1.0 if t == 0 else 0.0
        for k in range(n_ch):
            nz1 = r[k] * (a0[k] * z1[k] - c0[k] * z2[k])
            nz2 = r[k] * (c0[k] * z1[k] + a0[k] * z2[k])
            nz1 += in_out
            zY = h[k] * nz2
            in_out = g[k] * (in_out + zY)
            z1[k] = nz1
            z2[k] = nz2
            v = in_out * norm[k]
            if v > peak[k]:
                peak[k] = v
                idx[k] = t


def impulse_delay(design, seconds=0.6):
    """Time of each tap's largest positive response to a unit impulse.

    This is the alignment the de-skew wants: shift every tap back by this and a
    click in the input draws a straight vertical line across the whole cochlea.

    It is deliberately NOT the group delay taken from the phase slope at best
    frequency.  A cascade this deep is strongly dispersive, so the frequency at
    which a tap is most sensitive and the moment at which a broadband event
    actually arrives there are two different things, and the second is the one
    that governs where the ink lands.

    Streamed, so nothing the size of the impulse response is ever stored.
    """
    n = int(seconds * design['fs'])
    peak = np.full(design['n_ch'], -np.inf)
    idx = np.zeros(design['n_ch'], dtype=np.int64)
    _impulse_peak(design['a0'], design['c0'], design['h'], design['r'],
                  design['g'], design['norm'], n, peak, idx)
    return idx / design['fs']


def _fit_error(bw, tgt_bw, bf, want, body):
    """How far a design is from what was asked, in octaves.

    Two objectives: every channel one `erb_scale` of an ERB wide, and every
    channel's measured best frequency on the log grid its position claims.
    Combined in quadrature so neither can be sacrificed for the other.
    """
    e_bw = np.log2(np.clip(bw[body] / np.maximum(tgt_bw[body], 1e-9), 1e-6, 1e6))
    e_bf = np.log2(np.clip(bf[body] / np.maximum(want[body], 1e-9), 1e-6, 1e6))
    return float(np.sqrt((e_bw ** 2).mean() + (e_bf ** 2).mean()))


def calibrate(fs, f_lo=40.0, f_hi=None, taps_per_octave=60, erb_scale=1.0,
              lead_octaves=1.0, n_fft=1 << 15, iters=20, verbose=False,
              use_cache=True):
    """Design a cascade whose per-channel bandwidth is `erb_scale` x one ERB.

    Iteratively nudges per-channel damping until the measured -3 dB bandwidth
    matches the target, then stores a per-channel normalisation so a flat-
    spectrum input produces a flat cochleagram.
    """
    if f_hi is None:
        f_hi = fs / 8.0

    # v6: the smoothing kernel replicates the edges instead of zero-padding
    # them.  The design that comes out is different, so cached v5 results
    # must not be reused -- they would silently reinstate the old apex.
    # v8: best iterate scored on bandwidth *and* frequency placement
    key = f'v8_{fs}_{f_lo}_{f_hi}_{taps_per_octave}_{erb_scale}_{lead_octaves}_{n_fft}_{iters}'
    tag = hashlib.md5(key.encode()).hexdigest()[:16]
    path = os.path.join(CACHE_DIR, f'cascade_{tag}.npz')
    if use_cache and os.path.exists(path):
        z = np.load(path)
        d = design_cascade(fs, f_lo=f_lo, f_hi=f_hi,
                           taps_per_octave=taps_per_octave,
                           zeta=z['zeta'], lead_octaves=lead_octaves,
                           poles=z['poles'])
        d['norm'] = z['norm']
        return _finish(d, z['bf'], z['bw'], z['delay'], z['gdelay'])

    d = design_cascade(fs, f_lo=f_lo, f_hi=f_hi,
                       taps_per_octave=taps_per_octave, zeta=0.35,
                       lead_octaves=lead_octaves)
    want = d['target'].copy()          # the log grid the BFs should land on
    poles = d['cf_all'].copy()
    w = np.hanning(2 * (taps_per_octave // 4) + 3)
    w /= w.sum()

    def smooth(a):
        # Replicate the edges rather than zero-pad them.  `mode='same'` pads
        # with zeros, so at the outermost tap only half the kernel overlaps
        # real data and the correction there is scaled by about a half --
        # which under-corrects exactly the ~16 taps at each end and nowhere
        # else.  That is what left the apex 3.9 taps high, and with it the
        # bottom ten taps crammed into 1 Hz.
        pad = w.size // 2
        return np.convolve(np.pad(a, pad, mode='edge'), w, mode='valid')

    # Under-relaxation, scaled by the target sharpness.
    #
    # Bandwidth gets steadily more sensitive to damping as Q rises, so a step
    # size tuned at one ERB is too large below it: at 0.5 the iteration stops
    # converging and starts ringing along the channel axis -- taps 2 to 16 kHz
    # landing anywhere between 0.79 and 3.7 times their target, and *more*
    # iterations making it worse rather than better. Shrinking the step in
    # proportion to the target leaves 1.0 exactly as it was and gives the
    # sharp designs a loop gain they can survive.
    relax = min(1.0, erb_scale)

    # Keep the best iterate, not the last.
    #
    # The loop does not converge monotonically at sharp targets -- it rings
    # along the channel axis, and running it longer can land further from the
    # answer than stopping sooner. Remembering the best design seen makes more
    # iterations never worse than fewer, which is the property `iters` ought
    # to have and did not: at 0.5 ERB, 40 iterations used to be three times
    # worse than 20.
    best = None

    for it in range(iters):
        bf, pk, bw, _ = _measure(d)
        tgt_bw = erb_scale * erb(np.maximum(bf, 1.0))
        body = slice(d['n_lead'], None)
        # Scored on *both* objectives. Bandwidth alone picked a design at 1.3
        # ERB whose lowest tap sat at 78 Hz instead of 20 -- two octaves of
        # display traded away for a slightly better bandwidth fit, which is
        # not a trade anybody asked for.
        err = _fit_error(bw, tgt_bw, bf, want, body)
        if best is None or err < best[0]:
            best = (err, d['zeta'].copy(), np.asarray(d['cf_all']).copy())
        ratio = np.clip(bw / np.maximum(tgt_bw, 1e-9), 0.2, 5.0)
        # Wider than target -> reduce damping; narrower -> increase it.
        # Smooth along the channel axis: tuning is a cumulative property, so
        # per-channel corrections must not fight each other.
        d['zeta'] = np.clip(d['zeta'] * np.exp(smooth(np.log(ratio ** (-0.55 * relax)))),
                            0.02, 8.0)

        # The accumulated cascade pulls each channel's response peak below its
        # own pole -- by nearly an octave at the apex.  Walk the poles up until
        # tap k actually reports the frequency its position claims, so the
        # display axis means what it says.
        shift = np.clip(want / np.maximum(bf, 1e-6), 0.25, 4.0)
        poles = np.clip(poles * np.exp(smooth(np.log(shift)) * 0.7 * relax),
                        1.0, fs * 0.45)
        poles = np.maximum.accumulate(poles[::-1])[::-1]   # keep monotone

        d = design_cascade(fs, f_lo=f_lo, f_hi=f_hi,
                           taps_per_octave=taps_per_octave, zeta=d['zeta'],
                           lead_octaves=lead_octaves, poles=poles)
        d['target'] = want
        if verbose:
            body = slice(d['n_lead'], None)
            e1 = np.log2(np.clip(bw[body] / tgt_bw[body], 1e-6, 1e6))
            e2 = np.log2(np.clip(bf[body] / want[body], 1e-6, 1e6))
            print(f'  iter {it:2d}  BW/ERB={np.median(ratio[body]):.3f} '
                  f'rms(bw)={np.sqrt((e1**2).mean()):.3f} '
                  f'rms(bf)={np.sqrt((e2**2).mean()):.3f}')

    # Fall back to the best iterate if the last one drifted away from it.
    bf, pk, bw, gdelay = _measure(d)
    body = slice(d['n_lead'], None)
    tgt_bw = erb_scale * erb(np.maximum(bf, 1.0))
    final = _fit_error(bw, tgt_bw, bf, want, body)
    if best is not None and best[0] < final:
        if verbose:
            print(f'  keeping the best iterate: rms(bw) {best[0]:.4f} '
                  f'rather than the last at {final:.4f}')
        d = design_cascade(fs, f_lo=f_lo, f_hi=f_hi,
                           taps_per_octave=taps_per_octave, zeta=best[1],
                           lead_octaves=lead_octaves, poles=best[2])
        d['target'] = want
        bf, pk, bw, gdelay = _measure(d)
    d['norm'] = 1.0 / np.maximum(pk, 1e-12)
    # Alignment reference: where a unit impulse actually peaks in each tap.
    delay = impulse_delay(d)
    if use_cache:
        os.makedirs(CACHE_DIR, exist_ok=True)
        np.savez(path, zeta=d['zeta'], norm=d['norm'], bf=bf, bw=bw,
                 delay=delay, gdelay=gdelay, poles=d['cf_all'])
    return _finish(d, bf, bw, delay, gdelay)


def _finish(d, bf, bw, delay, gdelay=None):
    """Label channels by measured best frequency rather than pole frequency.

    At the apex the accumulated cascade pulls each channel's response peak
    well below its own pole, so the pole frequency is not the frequency the
    channel actually reports.  Everything downstream -- the display axis and
    the interval normalisation -- must use the measured BF.
    """
    nl = d['n_lead']
    d['bf_all'] = bf
    d['bw_all'] = bw
    d['cf_pole'] = d['cf_all'][nl:]
    d['cf'] = bf[nl:]
    d['bw'] = bw[nl:]
    # Travelling-wave delay, apex lagging base by ~100 ms at 1 ERB tuning.
    # Real, and audible as such, but on a display it skews every transient into
    # a diagonal smear.  Offering it as a correction rather than baking it in.
    d['delay'] = delay[nl:]
    if gdelay is not None:
        d['gdelay'] = gdelay[nl:]
    return d


# --------------------------------------------------------------------------
# Spike extraction
# --------------------------------------------------------------------------


@njit(cache=True)
def _find_spikes(bm, floor_frac, ch_idx, t_idx, amp_arr):
    n, n_ch = bm.shape
    count = 0
    for k in range(n_ch):
        pk = 0.0
        for i in range(n):
            v = bm[i, k]
            if v > pk:
                pk = v
        thr = pk * floor_frac
        for i in range(1, n - 1):
            v = bm[i, k]
            if v > thr and v > bm[i - 1, k] and v >= bm[i + 1, k]:
                if count < amp_arr.shape[0]:
                    ch_idx[count] = k
                    t_idx[count] = i
                    amp_arr[count] = v
                    count += 1
    return count


def find_spikes(bm, floor_frac=1e-4):
    """Extract (channel, sample_index, amplitude) spike triples.

    Only positive peaks are kept -- half-wave rectification, as the hair cells
    do.  This is the entire representation passed downstream.
    """
    n, n_ch = bm.shape
    cap = n * n_ch // 2 + n_ch
    ch_idx = np.empty(cap, dtype=np.int32)
    t_idx = np.empty(cap, dtype=np.int64)
    amp = np.empty(cap, dtype=np.float64)
    count = _find_spikes(bm, floor_frac, ch_idx, t_idx, amp)
    return ch_idx[:count], t_idx[:count], amp[:count]


# --------------------------------------------------------------------------


# --------------------------------------------------------------------------
# Streaming: cascade and peak detection fused, so nothing the size of the
# full basilar-membrane response is ever held in memory.  At 600 taps and
# 176 kHz that array would be about 2 GB; this way only the spikes survive,
# which is the representation the original hardware emitted anyway.
# --------------------------------------------------------------------------


@njit(cache=True, fastmath=True)
def _peak_scan(x, a0, c0, h, r, g, norm, z1, z2, p1, p2, thr,
               ch_idx, t_idx, amp, count, t0):
    n_ch = a0.shape[0]
    cap = amp.shape[0]
    for n in range(x.shape[0]):
        in_out = x[n]
        for k in range(n_ch):
            nz1 = r[k] * (a0[k] * z1[k] - c0[k] * z2[k])
            nz2 = r[k] * (c0[k] * z1[k] + a0[k] * z2[k])
            nz1 += in_out
            zY = h[k] * nz2
            in_out = g[k] * (in_out + zY)
            z1[k] = nz1
            z2[k] = nz2
            v = in_out * norm[k]
            # p2 is the sample before last, p1 the last: a peak is p1
            if thr[k] > 0.0 and p1[k] > thr[k] and p1[k] > p2[k] and p1[k] >= v:
                if count[0] < cap:
                    ch_idx[count[0]] = k
                    t_idx[count[0]] = t0 + n - 1
                    amp[count[0]] = p1[k]
                    count[0] += 1
            p2[k] = p1[k]
            p1[k] = v


@njit(cache=True, fastmath=True)
def _peak_max(x, a0, c0, h, r, g, norm, z1, z2, mx):
    n_ch = a0.shape[0]
    for n in range(x.shape[0]):
        in_out = x[n]
        for k in range(n_ch):
            nz1 = r[k] * (a0[k] * z1[k] - c0[k] * z2[k])
            nz2 = r[k] * (c0[k] * z1[k] + a0[k] * z2[k])
            nz1 += in_out
            zY = h[k] * nz2
            in_out = g[k] * (in_out + zY)
            z1[k] = nz1
            z2[k] = nz2
            v = in_out * norm[k]
            if v > mx[k]:
                mx[k] = v


def stream_spikes(x, design, floor_frac=1e-4, block=1 << 15, cap=None):
    """Two passes: per-channel peak level, then peaks above a relative floor."""
    x = np.ascontiguousarray(x, dtype=np.float64)
    a0, c0, h = design['a0'], design['c0'], design['h']
    r, g, norm = design['r'], design['g'], design['norm']
    n_ch, n = a0.shape[0], x.shape[0]

    mx = np.zeros(n_ch)
    z1, z2 = np.zeros(n_ch), np.zeros(n_ch)
    for i in range(0, n, block):
        _peak_max(x[i:i + block], a0, c0, h, r, g, norm, z1, z2, mx)
    thr = mx * floor_frac

    if cap is None:
        cap = int(min(3e8, 4e6 + 1.2 * n_ch * n * 0.06)) + n_ch
    ch_idx = np.empty(cap, dtype=np.int32)
    t_idx = np.empty(cap, dtype=np.int64)
    amp = np.empty(cap, dtype=np.float64)
    count = np.zeros(1, dtype=np.int64)

    z1[:], z2[:] = 0.0, 0.0
    p1, p2 = np.zeros(n_ch), np.zeros(n_ch)
    for i in range(0, n, block):
        _peak_scan(x[i:i + block], a0, c0, h, r, g, norm, z1, z2, p1, p2,
                   thr, ch_idx, t_idx, amp, count, i)
    m = int(count[0])

    nl = design['n_lead']
    keep = ch_idx[:m] >= nl
    return (ch_idx[:m][keep] - nl, t_idx[:m][keep], amp[:m][keep])


def analyse(x, fs, f_lo=40.0, f_hi=None, taps_per_octave=60, erb_scale=1.0,
            floor_frac=1e-4, verbose=False, streaming=None, lead_octaves=1.0):
    """Run the whole front end. Returns (design, bm, spikes).

    `bm` is None in streaming mode -- nothing that large is retained.
    """
    design = calibrate(fs, f_lo=f_lo, f_hi=f_hi,
                       taps_per_octave=taps_per_octave, erb_scale=erb_scale,
                       lead_octaves=lead_octaves, verbose=verbose)
    if streaming is None:
        streaming = x.size * design['n_ch'] > 60e6
    if streaming:
        return design, None, stream_spikes(x, design, floor_frac=floor_frac)
    bm = run_cascade(x, design)
    return design, bm, find_spikes(bm, floor_frac=floor_frac)
