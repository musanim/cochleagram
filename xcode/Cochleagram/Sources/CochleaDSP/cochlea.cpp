/*
 *  cochlea.cpp -- real-time cochlea filter cascade.
 *
 *  Port of prototype/cochlea.py and the display half of prototype/analysis.py.
 *  The filterbank calibration lives in Python and runs at design time; this
 *  reads the resulting coefficients and does nothing clever with them.
 *
 *  Structure per sample:
 *
 *      audio in  ->  half-band upsampler (2x)
 *                ->  middle ear (three biquads, zero gain at DC)
 *                ->  cascade of N two-pole/two-zero stages, basal to apical
 *                ->  positive-peak detection per tap  ->  spike (time, level)
 *                ->  sample-and-hold per tap
 *                ->  every column_ms, snapshot the held levels into a ring
 *                    buffer, reading each tap through its own de-skew delay
 *
 *  Nothing after the cascade allocates or blocks.
 */

#include "cochlea.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

namespace {

/* De-skew history depth, in columns.
 *
 * It has to cover the apex's group delay -- about 183 ms -- at the *shortest*
 * column the host will ask for, and that is not 4 ms. Close-up runs the engine
 * a divisor times faster, down to 0.05 ms a column, where 183 ms is 3660
 * columns.
 *
 * It was 256, which covers a second at 4 ms and looked ample. What it actually
 * did at short columns was clamp: every tap needing more than 255 columns got
 * exactly 255, so instead of a hold-back that grows with frequency they all
 * received the same one, and the skew de-skew exists to remove survived almost
 * untouched. It failed silently and only at fine Speeds, which is why it
 * looked like a drawing problem rather than an arithmetic one.
 *
 * 4096 columns is 205 ms at 0.05 ms and 16 s at 4 ms. The cost is
 * 4096 x 599 x 4 bytes, twice -- about 20 MB -- which is the price of the
 * feature working at every Speed rather than at some of them. */
constexpr int   kMaxDeskewColumns = 4096;
/*  Output queue.  At the close-up's finest column time the engine produces
 *  20,000 columns a second, so 4096 columns was 200 ms of slack -- a dozen
 *  frames, and one stall from overflowing.  8192 is 400 ms.
 *
 *  Not larger: it holds two floats per tap per column, so at 599 taps this is
 *  39 MB, and it is allocated whether or not the close-up is ever switched on.
 *  A display that has fallen four hundred milliseconds behind has a worse
 *  problem than a short queue, and the columns it loses are counted and
 *  marked. */
/* Columns the engine may hold before the display collects them.
 *
 * 1024 is four seconds at 4 ms a column, and the consumer pulls every audio
 * block -- every three milliseconds or so -- meaning the ring never holds more
 * than a handful. It was 8192, which is thirty-three seconds of queue nothing
 * asks for, and 37 MB of it: at 599 taps and two quantities a column costs
 * 4.7 kB, so the ring alone was the largest allocation in the program. On a
 * desktop that is invisible. In an iOS tab, where the whole page is competing
 * for a budget measured in hundreds of megabytes, it is most of the reason
 * Safari was reloading the page and handing back cleared canvases. */
constexpr int   kRingColumns      = 1024;
/*  What a tap with no energy in it reports, standing in for minus infinity.
 *  1e-30, not the 1e-12 this used to be: 1e-12 is -240 dB, and once the
 *  display's window could be positioned freely it became reachable -- a
 *  window of -300 to -100 drew genuine silence as a mid grey, because -240
 *  is inside it. A stand-in for minus infinity has to stay outside every
 *  window the instrument can be set to, and -600 dB does. Well above the
 *  smallest normal float, 1.18e-38, so nothing here goes subnormal. */
constexpr float kTinyLevel        = 1e-30f;


/* ---------------------------------------------------------------------------
 *  2x half-band upsampler.
 *
 *  The cascade is designed for 88.2 kHz so that its top taps sit far enough
 *  below Nyquist to be well behaved at 20 kHz.  Host audio arrives at 44.1 or
 *  48 kHz, so we interpolate by two.  A half-band FIR is the natural choice:
 *  every other coefficient is zero, so the odd output samples cost one MAC per
 *  non-zero tap and the even ones are just the delayed input.
 * ------------------------------------------------------------------------ */
class HalfBandUpsampler {
public:
    HalfBandUpsampler() { reset(); }

    void reset() { std::fill(hist_, hist_ + kLen, 0.0); pos_ = 0; }

    /* Produces exactly two output samples per input sample. */
    inline void step(double x, double *out) {
        hist_[pos_] = x;
        /* Even phase: pure delay through the centre tap. */
        out[0] = hist_[(pos_ + kLen - kCentre) % kLen];
        /* Odd phase: symmetric FIR over the non-zero coefficients. */
        double acc = 0.0;
        for (int i = 0; i < kHalf; ++i) {
            const int a = (pos_ + kLen - i) % kLen;
            const int b = (pos_ + kLen - (kTaps - 1 - i)) % kLen;
            acc += kCoef[i] * (hist_[a] + hist_[b]);
        }
        out[1] = acc;
        pos_ = (pos_ + 1) % kLen;
    }

private:
    /* 16-tap symmetric half-band kernel (Kaiser-windowed sinc, ~80 dB stop). */
    static constexpr int kTaps   = 16;
    static constexpr int kHalf   = kTaps / 2;
    static constexpr int kLen    = 32;
    static constexpr int kCentre = kTaps / 2;
    static constexpr double kCoef[kHalf] = {
        -0.0002520, 0.0014610, -0.0050927, 0.0136887,
        -0.0323559, 0.0757836, -0.2204633, 0.6371306
    };
    double hist_[kLen];
    int    pos_;
};
constexpr double HalfBandUpsampler::kCoef[];

/* ---------------------------------------------------------------------------
 *  Human middle ear.
 *
 *  Without this the cascade has no reason to reject DC, and it doesn't: fed a
 *  constant, the apex tap settles at 0.76 of the input and stays there, so a
 *  rectangular pulse paints the bottom of the display dark for its whole
 *  length instead of drawing a click at each edge.  That is not a fault in the
 *  filterbank.  At CF 20 Hz one ERB is about 25 Hz, so DC is inside the
 *  passband and no filter that wide can reject it.  A real ear is spared
 *  because the middle ear is a steep highpass sitting in front of the cochlea,
 *  and until now we had no such stage.
 *
 *  Three second-order sections, bilinear-transformed from analogue prototypes
 *  with pre-warping at 1 kHz: the digital form given in Ibrahim (2012,
 *  Appendix), after Pascal et al. (JASA 1998), as distributed in the Auditory
 *  Modeling Toolbox as middleearfilter(..., 'zilany2009').  The first section
 *  carries a zero at z = 1, so the DC gain of the chain is exactly zero rather
 *  than merely small.
 *
 *  Normalised to unity at 1 kHz.  The published scaling maps pressure to
 *  stapes velocity in SI units, which would move every level on screen by a
 *  large constant for no benefit; a display only cares about the shape.
 *  Response relative to 1 kHz, at 88.2 kHz sample rate:
 *
 *      20 Hz  -34.0 dB      500 Hz   -4.4 dB      4 kHz   -2.4 dB
 *      80 Hz  -21.9 dB        1 kHz    0.0 dB      8 kHz   -8.5 dB
 *     250 Hz  -11.5 dB        2 kHz   -3.9 dB     16 kHz  -23.6 dB
 * ------------------------------------------------------------------------ */
class MiddleEar {
public:
    MiddleEar() { reset(); }

    void design(double fs) {
        constexpr double kPi = 3.14159265358979323846;
        const double fp = 1000.0;                 /* pre-warp frequency */
        const double C  = 2.0 * kPi * fp / std::tan(kPi * fp / fs);
        const double C2 = C * C;

        const double m11 = 1.0 / (C2 + 5.9761e3 * C + 2.5255e7);
        setSection(0, m11 * (C2 + 5.6665e3 * C),
                      m11 * (-2.0 * C2),
                      m11 * (C2 - 5.6665e3 * C),
                      m11 * (-2.0 * C2 + 2.0 * 2.5255e7),
                      m11 * (C2 - 5.9761e3 * C + 2.5255e7));

        const double m21 = 1.0 / (C2 + 6.4255e3 * C + 1.3975e8);
        setSection(1, m21 * (C2 + 5.8934e3 * C + 1.7926e8),
                      m21 * (-2.0 * C2 + 2.0 * 1.7926e8),
                      m21 * (C2 - 5.8934e3 * C + 1.7926e8),
                      m21 * (-2.0 * C2 + 2.0 * 1.3975e8),
                      m21 * (C2 - 6.4255e3 * C + 1.3975e8));

        const double m31 = 1.0 / (C2 + 2.4891e4 * C + 1.2700e9);
        const double megainmax = 2.0;
        setSection(2, m31 * (3.1137e3 * C + 6.9768e8) / megainmax,
                      m31 * (2.0 * 6.9768e8) / megainmax,
                      m31 * (6.9768e8 - 3.1137e3 * C) / megainmax,
                      m31 * (-2.0 * C2 + 2.0 * 1.27e9),
                      m31 * (C2 - 2.4891e4 * C + 1.27e9));

        /* Scale the first section so the chain is unity at 1 kHz. */
        const double gain = magnitudeAt(2.0 * kPi * fp / fs);
        if (gain > 0.0) {
            b0_[0] /= gain; b1_[0] /= gain; b2_[0] /= gain;
        }
        reset();
    }

    void reset() {
        for (int s = 0; s < kSections; ++s) z1_[s] = z2_[s] = 0.0;
    }

    /* Transposed direct form II, one sample. */
    inline double process(double x) {
        for (int s = 0; s < kSections; ++s) {
            const double y = b0_[s] * x + z1_[s];
            z1_[s] = b1_[s] * x - a1_[s] * y + z2_[s];
            z2_[s] = b2_[s] * x - a2_[s] * y;
            x = y;
        }
        return x;
    }

    /* |H| of the whole chain at a normalised angular frequency, for the
     * unity-at-1-kHz scaling and for the self test. */
    double magnitudeAt(double w) const {
        const double cw = std::cos(w), sw = std::sin(w);
        const double c2w = std::cos(2.0 * w), s2w = std::sin(2.0 * w);
        double mag = 1.0;
        for (int s = 0; s < kSections; ++s) {
            const double nr = b0_[s] + b1_[s] * cw + b2_[s] * c2w;
            const double ni = -(b1_[s] * sw + b2_[s] * s2w);
            const double dr = 1.0 + a1_[s] * cw + a2_[s] * c2w;
            const double di = -(a1_[s] * sw + a2_[s] * s2w);
            mag *= std::sqrt((nr * nr + ni * ni) / (dr * dr + di * di));
        }
        return mag;
    }

private:
    void setSection(int s, double b0, double b1, double b2,
                    double a1, double a2) {
        b0_[s] = b0; b1_[s] = b1; b2_[s] = b2; a1_[s] = a1; a2_[s] = a2;
    }

    static constexpr int kSections = 3;
    double b0_[kSections], b1_[kSections], b2_[kSections];
    double a1_[kSections], a2_[kSections];
    double z1_[kSections], z2_[kSections];
};

/* ---------------------------------------------------------------------------
 *  Lock-free single-producer / single-consumer column queue.
 * ------------------------------------------------------------------------ */
class ColumnRing {
public:
    /*  Two quantities per column, side by side.  The engine has no reason to
     *  choose between them: which one is drawn, and how, is a question about
     *  controls the display owns.  Shipping both also means switching the
     *  display's mode re-renders what is already on screen instead of wiping
     *  it, for the same reason levels are shipped rather than pixels. */
    void init(int taps) {
        taps_ = taps;
        buf_.assign(static_cast<size_t>(taps) * 2 * kRingColumns, 0.0f);
        refs_.assign(kRingColumns, 0.0f);
        range_.assign(static_cast<size_t>(kRingColumns) * 2, 0.0f);
        head_.store(0);
        tail_.store(0);
        dropped_.store(0);
    }

    /* audio thread */
    void push(const float *level, const float *coherence, float ref,
              float lo, float hi) {
        const uint64_t h = head_.load(std::memory_order_relaxed);
        const uint64_t t = tail_.load(std::memory_order_acquire);
        if (h - t >= static_cast<uint64_t>(kRingColumns)) {
            dropped_.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        const size_t at = (h % kRingColumns) * static_cast<size_t>(taps_) * 2;
        std::memcpy(&buf_[at], level, taps_ * sizeof(float));
        std::memcpy(&buf_[at + taps_], coherence, taps_ * sizeof(float));
        refs_[h % kRingColumns] = ref;
        range_[(h % kRingColumns) * 2] = lo;
        range_[(h % kRingColumns) * 2 + 1] = hi;
        head_.store(h + 1, std::memory_order_release);
    }

    /* drawing thread */
    int pull(float *levels, float *coherence, float *refs,
             float *lo, float *hi, int max_cols) {
        const uint64_t h = head_.load(std::memory_order_acquire);
        uint64_t t = tail_.load(std::memory_order_relaxed);
        int n = 0;
        while (t < h && n < max_cols) {
            const size_t at =
                (t % kRingColumns) * static_cast<size_t>(taps_) * 2;
            if (levels) {
                std::memcpy(levels + static_cast<size_t>(n) * taps_,
                            &buf_[at], taps_ * sizeof(float));
            }
            if (coherence) {
                std::memcpy(coherence + static_cast<size_t>(n) * taps_,
                            &buf_[at + taps_], taps_ * sizeof(float));
            }
            if (refs) refs[n] = refs_[t % kRingColumns];
            if (lo) lo[n] = range_[(t % kRingColumns) * 2];
            if (hi) hi[n] = range_[(t % kRingColumns) * 2 + 1];
            ++t;
            ++n;
        }
        tail_.store(t, std::memory_order_release);
        return n;
    }

    uint64_t dropped() const { return dropped_.load(std::memory_order_relaxed); }

private:
    int                   taps_ = 0;
    std::vector<float>    buf_;
    std::vector<float>    refs_;
    /*  The input's smallest and largest sample over each column, so a host can
     *  draw the waveform the picture was made from.  Two floats a column, in
     *  the same slot as everything else, because they describe the same
     *  column and must not be able to arrive out of step with it. */
    std::vector<float>    range_;
    std::atomic<uint64_t> head_{0}, tail_{0}, dropped_{0};
};

/* ---------------------------------------------------------------------------
 *  The same thing again for raw input samples, so what is on screen can be
 *  played back.
 *
 *  Deliberately a separate ring rather than a wider ColumnRing.  The two carry
 *  different quantities at different rates -- one item per column against one
 *  per sample, some hundreds of times more often -- and a consumer that wants
 *  columns without audio is the ordinary case, not a special one.
 *
 *  Sized in seconds rather than in buffers.  The consumer is a display link,
 *  so the ring is normally emptied sixty times a second and a fraction of a
 *  second would do; the margin is for the case where the link stops -- a
 *  minimised or fully occluded window -- which also drops columns and is
 *  already marked in the picture as a seam.
 * ------------------------------------------------------------------------ */
class InputRing {
public:
    void init(double rate_hz) {
        const size_t n = static_cast<size_t>(
            std::fmax(1.0, rate_hz * kCaptureSeconds));
        buf_.assign(n, 0.0f);
        head_.store(0);
        tail_.store(0);
        dropped_.store(0);
    }

    void setEnabled(bool on) { enabled_.store(on, std::memory_order_relaxed); }
    bool enabled() const { return enabled_.load(std::memory_order_relaxed); }

    /* audio thread */
    void push(const float *in, int n) {
        if (!enabled() || buf_.empty() || n <= 0) return;
        const size_t cap = buf_.size();
        const uint64_t h = head_.load(std::memory_order_relaxed);
        const uint64_t t = tail_.load(std::memory_order_acquire);
        const size_t free_now = cap - static_cast<size_t>(h - t);
        size_t take = static_cast<size_t>(n);
        if (take > free_now) {
            /*  Drop the tail of the buffer rather than the head of the ring.
             *  Overwriting what the consumer has not read yet would silently
             *  reorder the recording; losing the newest samples leaves what is
             *  already held still contiguous and still true. */
            dropped_.fetch_add(take - free_now, std::memory_order_relaxed);
            take = free_now;
            if (take == 0) return;
        }
        const size_t at = static_cast<size_t>(h % cap);
        const size_t first = std::min(take, cap - at);
        std::memcpy(&buf_[at], in, first * sizeof(float));
        if (take > first) {
            std::memcpy(&buf_[0], in + first, (take - first) * sizeof(float));
        }
        head_.store(h + take, std::memory_order_release);
    }

    /* drawing thread */
    int pull(float *out, int max) {
        if (buf_.empty() || max <= 0 || !out) return 0;
        const size_t cap = buf_.size();
        const uint64_t h = head_.load(std::memory_order_acquire);
        const uint64_t t = tail_.load(std::memory_order_relaxed);
        size_t take = static_cast<size_t>(h - t);
        if (take > static_cast<size_t>(max)) take = static_cast<size_t>(max);
        if (take == 0) return 0;
        const size_t at = static_cast<size_t>(t % cap);
        const size_t first = std::min(take, cap - at);
        std::memcpy(out, &buf_[at], first * sizeof(float));
        if (take > first) {
            std::memcpy(out + first, &buf_[0], (take - first) * sizeof(float));
        }
        tail_.store(t + take, std::memory_order_release);
        return static_cast<int>(take);
    }

    uint64_t dropped() const { return dropped_.load(std::memory_order_relaxed); }

private:
    static constexpr double kCaptureSeconds = 4.0;

    std::vector<float>    buf_;
    std::atomic<bool>     enabled_{false};
    std::atomic<uint64_t> head_{0}, tail_{0}, dropped_{0};
};

}  // namespace

/* ------------------------------------------------------------------------- */

struct CochleaEngine {
    /* geometry */
    int    n_ch = 0;        /* stages including lead-in */
    int    n_lead = 0;
    int    n_taps = 0;      /* displayed taps = n_ch - n_lead */
    double fs = 0.0;        /* internal rate */
    double input_rate = 0.0;

    /* coefficients, length n_ch */
    std::vector<double> a0, c0, h, r, g, norm;
    /* per displayed tap */
    std::vector<double> bf, gdelay, idelay;

    /* filter state */
    std::vector<double> z1, z2;
    /* peak detection: previous two outputs and the held spike level */
    std::vector<double> p1, p2, held;

    /*  Coherence.  For each tap, when it peaks, how long ago did the tap above
     *  it -- the next higher best frequency -- last peak?  Held the same way
     *  the amplitude is held, so the two displays behave alike.
     *
     *  Stored in cycles of the tap's own best frequency rather than in seconds.
     *  Seconds are unreadable across the display: the apex peaks every 50 ms
     *  and the base every 0.1 ms, so any fixed grey scale is saturated at one
     *  end and empty at the other.  Neighbouring taps sit 1/60 octave apart, so
     *  their periods differ by about 1%, and which of the two you divide by
     *  does not matter.
     *
     *  A tap driven coherently with its neighbour -- both following the same
     *  partial -- should hold a steady fraction of a cycle.  One driven by
     *  something its neighbour is not following has no reason to.  That is the
     *  quantity to look at; what it does on real sound is the open question
     *  this display exists to answer.
     *
     *  What is subtracted, and why.  Adjacent taps do not respond at the same
     *  instant: the cascade delays each one a little more than the tap above
     *  it, and that step multiplied by the tap's own frequency is a fixed
     *  phase.  It belongs to the filterbank, not to the sound, and it grows
     *  with frequency -- 0.05 cycles at 125 Hz against 0.24 at 8 kHz -- so
     *  without removing it white noise reads pale at the apex and dark at the
     *  base and nothing can be compared across the picture.  Measured on white
     *  noise, the per-tap mean tracks this prediction at r = 0.87 over 598
     *  taps, so it is the bulk of the drift.
     *
     *  It is subtracted, leaving a signed deviation: zero means a tap peaked
     *  exactly the interval later than its neighbour that the filterbank's own
     *  delay would produce.
     *
     *  The step is a first difference of a measured group delay, which is a
     *  noisy thing to differentiate, so it is smoothed across taps first. */
    std::vector<double> peak_time;   /* internal sample index of the last peak */
    std::vector<double> held_dt;     /* held deviation, cycles of own CF */
    std::vector<double> dt_base;     /* the filterbank's own step, cycles */
    double sample_index = 0.0;
    double inv_fs = 0.0;
    static constexpr double kNoPeak = -1e18;


    /* middle ear, ahead of the cascade and at the internal rate */
    MiddleEar mear;

    /* upsampling */
    HalfBandUpsampler up;
    bool   need_upsample = false;
    double resample_phase = 0.0;   /* for non-integer rate ratios */
    double resample_step = 1.0;
    double last_in = 0.0;

    /* column timing */
    double column_ms = 4.0;
    double samples_per_column = 0.0;
    double column_accum = 0.0;

    /* de-skew history: kMaxDeskewColumns columns of raw held levels.
     * Both quantities are kept whatever the mode is showing, so switching mode
     * does not leave a screen's worth of de-skew depth reading from a buffer
     * that was filled with the other one. */
    std::vector<float> history;    /* [column][tap] */
    std::vector<float> history_dt; /* [column][tap], cycles */
    /*  The input's range over each column, in the same ring and at the same
     *  position, so that it can be read back with the same delay the taps are.
     *  See emitColumn. */
    std::vector<float> history_range;  /* [column][lo, hi] */
    /*  Accumulated over the input samples since the last column was emitted.
     *  Deliberately impossible values, so "nothing arrived" is distinguishable
     *  from "arrived and was silent". */
    float  in_lo =  1e30f;
    float  in_hi = -1e30f;
    int    hist_pos = 0;
    std::vector<int> shift;        /* per tap, in columns */
    int    max_shift = 0;
    bool   deskew = true;

    /* Auto-gain reference.  Always tracked, never applied: the engine reports
     * it alongside each column and the display decides whether to use it.
     * Follows the loudest tap up instantly, decays back slowly. */
    double auto_halflife = 3.0;
    double auto_decay = 1.0;
    double auto_ref = 1e-6;

    void recomputeAutoDecay() {
        const double col_s = column_ms * 1e-3;
        auto_decay = std::exp(-0.693147180559945 * col_s /
                              std::fmax(auto_halflife, 1e-3));
    }

    std::vector<float> scratch, scratch_dt;
    ColumnRing ring;
    InputRing  capture;
    std::atomic<float> peak{0.0f};

    void recomputeShifts() {
        max_shift = 0;
        const double col_s = column_ms * 1e-3;
        double dmax = 0.0;
        for (int k = 0; k < n_taps; ++k) dmax = std::fmax(dmax, gdelay[k]);
        for (int k = 0; k < n_taps; ++k) {
            /* Hold the fast (basal) taps back so every tap reports a given
             * event in the same column.  Causality means we can only delay,
             * never advance, so the whole display lags by dmax. */
            int s = deskew
                  ? static_cast<int>(std::lround((dmax - gdelay[k]) / col_s))
                  : 0;
            if (s < 0) s = 0;
            if (s >= kMaxDeskewColumns) s = kMaxDeskewColumns - 1;
            shift[k] = s;
            if (s > max_shift) max_shift = s;
        }
    }

    /*  One sample at the *input* rate through the same front end the audio
     *  takes: the resampler, and then the middle ear inside `runCascade`.
     *  `step` is called after each internal sample, so a caller can watch the
     *  taps at the engine's own resolution.
     *
     *  This exists so that calibration can measure the cascade through the
     *  chain the picture is actually drawn from. Feeding `runCascade` a unit
     *  sample directly -- which is what calibration used to do -- presents it
     *  with an impulse carrying energy to half the *internal* rate, an octave
     *  above anything real audio can contain. That extra octave leaks down the
     *  cascade almost instantaneously and shows up as a tiny early "response"
     *  ahead of the real one: 100 dB below it at 56 Hz and 177 dB below at
     *  30 Hz at ERB 0.5, which is enough to be found by any threshold low
     *  enough to catch a sharp tuning's genuine first peak. It never appears
     *  in the picture, because real audio arrives band-limited through the
     *  half-band upsampler. Calibrating through the same front end removes it
     *  at the source rather than trying to recognise and reject it.
     *
     *  Deliberately not `cochlea_process` itself: that also fills the column
     *  ring, and calibration has no picture to draw. */
    template <typename F>
    inline void feedInput(double x, F &&step) {
        if (need_upsample) {
            double two[2];
            up.step(x, two);
            for (int j = 0; j < 2; ++j) { runCascade(two[j]); step(); }
        } else {
            while (resample_phase < 1.0) {
                const double s = last_in + (x - last_in) * resample_phase;
                runCascade(s);
                step();
                resample_phase += resample_step;
            }
            resample_phase -= 1.0;
            last_in = x;
        }
    }

    inline void runCascade(double x) {
        /* The middle ear runs here rather than on the host samples so that it
         * sees the internal rate, which is what its coefficients were designed
         * for, and so that both rate-conversion paths get it. */
        double in_out = mear.process(x);
        for (int k = 0; k < n_ch; ++k) {
            const double nz1 = r[k] * (a0[k] * z1[k] - c0[k] * z2[k]) ;
            const double nz2 = r[k] * (c0[k] * z1[k] + a0[k] * z2[k]);
            z1[k] = nz1 + in_out;
            z2[k] = nz2;
            in_out = g[k] * (in_out + h[k] * nz2);

            if (k < n_lead) continue;
            const int t = k - n_lead;
            const double v = in_out * norm[k];
            /* A spike is a positive local maximum: p1 higher than both
             * neighbours.  Sample and hold -- the level stays put until the
             * next spike, so a steady tone draws a steady shade.
             *
             * No amplitude floor here, deliberately.  One was tried, copying
             * the offline reference's `floor_frac`, and it froze every tap at
             * its floor when the sound stopped: below the threshold no further
             * spike is accepted, so the last one accepted is held for ever and
             * a 1 kHz tone leaves a grey bar running to the edge of the screen
             * long after it has gone silent.  Offline that is harmless because
             * the threshold is a fraction of the whole file's maximum and the
             * raster ends; in a display that never ends it is a lie that stays
             * on screen. */
            if (p1[t] > 0.0 && p1[t] > p2[t] && p1[t] >= v) {
                held[t] = p1[t];
                /* p1 is the output one sample ago, so that is when it peaked.
                 * Tap t-1 was updated earlier in this same loop, so a peak in
                 * both taps on the same sample reads as a difference of zero,
                 * which is what it is. */
                /*  Where the peak actually was, to a fraction of a sample.
                 *
                 *  Taking the sample index alone quantises the peak time to
                 *  the internal rate, and at the top of the display that
                 *  quantum is enormous in the units this display uses: one
                 *  sample at 88.2 kHz is 0.18 cycles at 16 kHz and 0.09 at
                 *  8 kHz, against a full scale of 0.05.  The whole top of the
                 *  picture was quantisation and nothing else.
                 *
                 *  Fit a sine rather than a parabola.  A parabola is the
                 *  obvious three-point interpolator and it is wrong here: the
                 *  output of a narrowband filter near its peak is a sinusoid,
                 *  not a quadratic, and the error grows with how few samples
                 *  there are per cycle -- which is exactly where the problem
                 *  already was.  Stephen recalls Lloyd Watts saying the
                 *  original fitted a sine; that is a recollection rather than
                 *  a confirmation, but it agrees with the measurement.
                 *
                 *  Three samples y(-1), y(0), y(1) of A.cos(wn - phi) give
                 *
                 *      y(1) + y(-1) = 2A cos(w) cos(phi)
                 *      y(1) - y(-1) = 2A sin(w) sin(phi)
                 *
                 *  so the frequency comes from the standard resonator
                 *  identity y(1) + y(-1) = 2 cos(w) y(0), which holds at any
                 *  phase, and the peak then sits phi/w samples from y(0).
                 *  Both are exact for a pure sinusoid at any sample rate.
                 *
                 *  y(0) is a positive local maximum and the largest of the
                 *  three, so the division is well conditioned -- which is not
                 *  true of this identity in general. */
                const double ym1 = p2[t], y0 = p1[t], y1 = v;
                double frac = 0.0;
                double c = (ym1 + y1) / (2.0 * y0);
                c = c > 0.999999 ? 0.999999 : (c < -0.999999 ? -0.999999 : c);
                const double w = std::acos(c);
                if (w > 1e-9) {
                    const double sn = std::sqrt(1.0 - c * c);
                    frac = std::atan2((y1 - ym1) * c, (y1 + ym1) * sn) / w;
                    /* A genuine local maximum cannot be more than half a
                     * sample from the middle of the three. */
                    frac = frac > 0.5 ? 0.5 : (frac < -0.5 ? -0.5 : frac);
                }
                const double tpk = sample_index - 1.0 + frac;
                if (t > 0 && peak_time[t - 1] > kNoPeak) {
                    held_dt[t] = (tpk - peak_time[t - 1]) * inv_fs * bf[t]
                               - dt_base[t];
                }
                peak_time[t] = tpk;
            }
            p2[t] = p1[t];
            p1[t] = v;
        }
        sample_index += 1.0;
    }

    /*  Measure the coherence baseline instead of predicting it.
     *
     *  The group-delay estimate gets the shape of the drift right -- r = 0.87
     *  across 598 taps -- but not the detail: subtracting it leaves broad
     *  bands, dark near 300 Hz and pale near 4 and 11 and 16 kHz, which are
     *  places where the cascade's actual behaviour departs from the smooth
     *  delay curve.  Rather than model those, run white noise through this
     *  engine and record what each tap does.
     *
     *  White noise is the right reference because it is the definition of no
     *  structure: after this, white noise reads flat mid-grey by construction,
     *  and anything that is not flat is something the sound is doing.
     *
     *  Deterministic -- a fixed seed, so two runs of the same build produce
     *  the same baseline and a picture is reproducible.  Costs one second of
     *  audio through the cascade at engine creation, once.
     *
     *  The middle ear is left in the path rather than bypassed, so this is
     *  calibrated through exactly the chain the sound will take.  It costs the
     *  apex some drive, but a phase measurement does not care about level. */
    void calibrateCoherence() {
        const int n = n_taps;
        if (n < 2) return;
        std::vector<double> analytic = dt_base;
        std::fill(dt_base.begin(), dt_base.end(), 0.0);

        std::vector<double> sum(static_cast<size_t>(n), 0.0);
        std::vector<long>   cnt(static_cast<size_t>(n), 0);

        uint64_t s = 0x9E3779B97F4A7C15ull;
        const long total = static_cast<long>(fs);            /* one second */
        const long every = static_cast<long>(std::fmax(1.0, samples_per_column));
        const long settle = every * 8;
        for (long i = 0; i < total; ++i) {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17;         /* xorshift64 */
            const double u = static_cast<double>(s >> 11)
                           * (1.0 / 9007199254740992.0);
            runCascade((u - 0.5) * 0.5);
            /* Sampled on the column grid, because a column is what the display
             * averages; sampling every sample would weight the taps that fire
             * often far above the ones that do not. */
            if (i > settle && i % every == 0) {
                for (int t = 1; t < n; ++t) {
                    if (peak_time[t] > kNoPeak && peak_time[t - 1] > kNoPeak) {
                        sum[static_cast<size_t>(t)] += held_dt[t];
                        cnt[static_cast<size_t>(t)] += 1;
                    }
                }
            }
        }

        std::vector<double> raw(static_cast<size_t>(n), 0.0);
        for (int t = 0; t < n; ++t) {
            raw[static_cast<size_t>(t)] =
                cnt[static_cast<size_t>(t)] >= 8
                    ? sum[static_cast<size_t>(t)] / double(cnt[static_cast<size_t>(t)])
                    : analytic[static_cast<size_t>(t)];
        }
        raw[0] = raw[1];
        /*  Lightly smoothed.  This is a direct measurement rather than a
         *  differentiated one, so it needs far less than the analytic version
         *  did; seven taps is a ninth of an octave and leaves every feature
         *  wide enough to matter. */
        constexpr int kHalf = 3;
        for (int t = 0; t < n; ++t) {
            double acc = 0.0;
            for (int j = -kHalf; j <= kHalf; ++j) {
                int i = t + j;
                i = i < 0 ? 0 : (i >= n ? n - 1 : i);
                acc += raw[static_cast<size_t>(i)];
            }
            dt_base[t] = acc / (2 * kHalf + 1);
        }
        resetState();
    }

    /// Measure what the de-skew shifts should be, rather than trusting the
    /// number in the coefficient file.
    ///
    /// The file carries an analytic group delay -- what the poles say the
    /// cascade should do. What the display draws is the sample-and-hold peak,
    /// and the two are not the same thing: measured against an impulse they
    /// disagree by up to 10 ms at the apex and by -5 ms around 78 Hz, which is
    /// exactly the residual tilt left over after de-skewing by the analytic
    /// value. There is no reason to infer a quantity we can simply observe --
    /// the cascade is right here, with these coefficients, this rate, and the
    /// middle ear in front of it.
    ///
    /// Half a second, because the apex's delay alone is about 180 ms and its
    /// ringing outlasts that. About 200 ms of work, and it is what baking
    /// exists to avoid paying: the shipped coefficient files carry the result
    /// already, so in the app this does not run. `tools/measuredelays` calls
    /// it -- by handing the engine a version-1 file -- to produce the curve
    /// that gets baked in.
    void calibrateDelays() {
        const int n = n_taps;
        if (n < 1) return;
        /* At the *input* rate, and through `feedInput`, so that the impulse
         * reaching the cascade is the one real audio would deliver. See the
         * note on `feedInput`. */
        const long total = static_cast<long>(input_rate * 0.5);

        /* Two passes, because the threshold for the second is a property of
         * the first. */
        resetState();
        std::vector<double> best(static_cast<size_t>(n), 0.0);
        for (long i = 0; i < total; ++i) {
            feedInput(i == 0 ? 1.0 : 0.0, [&] {
                for (int t = 0; t < n; ++t) {
                    if (held[t] > best[static_cast<size_t>(t)]) {
                        best[static_cast<size_t>(t)] = held[t];
                    }
                }
            });
        }

        /* The *first* peak, not the biggest one and not the first big one.
         *
         * A tap's impulse response builds over a cycle or two, so its largest
         * peak comes after its first. Lining up the largest ones lines up the
         * wrong feature: what the eye follows is the leading edge of the mark,
         * and at 30 Hz the gap between the first peak and the biggest is a
         * whole cycle -- 33 ms.
         *
         * `held` only ever moves at a genuine positive local maximum of the
         * tap's output, so "the first time held moves" *is* "the first peak".
         *
         * The threshold is **absolute** -- one level for every tap -- and that
         * is the whole of it. It was a fraction of each tap's own maximum,
         * which is a different level for every tap, and where that level
         * happened to fall between a tap's first and second peak the search
         * took the second: a whole cycle late, for a whole band of taps at
         * once. At ERB 0.6 that put everything above 305 Hz one cycle out,
         * above 648 Hz two, above 1898 Hz three -- visible as rectangular
         * steps in the leading edge of a click, 4.5 ms at the worst of them.
         * ERB 1.0 escaped only by luck: at one ERB the first peak stands far
         * enough above a hundredth of a millionth of the maximum everywhere.
         *
         * Chasing the fraction downwards does not fix it and cannot: the level
         * it has to clear varies by tens of decibels across frequency and
         * tuning, so no single fraction is below every first peak. An absolute
         * level can be, and is also what the eye is using -- turn Sensitivity
         * and Range to maximum, and the first non-white point in each row *is*
         * this crossing. The rule and the picture are then the same statement.
         *
         * -300 dB, and the value barely matters now. Spread of the visible
         * leading edge at 0.5 ms per column, de-skew on, measured through the
         * front end above:
         *
         *            -140   -180   -220   -260   -300   -340   -380 dB
         *   ERB 0.5  16.0   12.0    8.5    8.5    8.5    8.5    8.5 ms
         *   ERB 0.6   5.0    4.0    1.5    1.5    1.5    1.5    1.5
         *   ERB 0.7   3.5    1.5    0.5    0.5    0.5    0.5    0.5
         *   ERB 1.0   0.5    0.5    0.5    0.5    0.5    0.5    0.5
         *
         * 0.5 ms is one column: as vertical as the display can draw. The
         * answer stops moving below -220 dB and never moves again -- there is
         * no floor to fall off, because there is no longer a precursor to
         * find. -300 is chosen for margin against a sharper bake than any that
         * exists, not because anything changes there.
         *
         * It was 1e-5 of each tap's *own maximum* -- a different level for
         * every tap -- and where that fell between a tap's first and second
         * peak the search took the second. At ERB 0.6 that put everything
         * above 305 Hz one cycle late, above 648 Hz two, above 1898 Hz three,
         * visible as rectangular steps in the leading edge of a click. ERB 1.0
         * escaped by luck. No fraction can work: at ERB 0.6 a genuine first
         * peak sits 185 dB below its tap's maximum, deeper than the artefact
         * an earlier version of this comment was trying to exclude.
         *
         * The fraction survives as a floor and not as the rule: a tap whose
         * entire response sits below the absolute level would otherwise never
         * be found at all, and would report a delay of zero. */
        /*  Overridable at build time so it can be swept without editing this
         *  file -- `-DCOCHLEA_LEAD_ABSOLUTE=1e-10`. The value matters more
         *  than it looks: see the note below about which machine measures it.
         */
#ifndef COCHLEA_LEAD_ABSOLUTE
#define COCHLEA_LEAD_ABSOLUTE 1e-9    /* -180 dBFS */
#endif
        constexpr double kLeadAbsolute = COCHLEA_LEAD_ABSOLUTE;
#ifndef COCHLEA_LEAD_FRACTION
#define COCHLEA_LEAD_FRACTION 1e-5
#endif
        constexpr double kLeadFraction = COCHLEA_LEAD_FRACTION;
        /*  Step over a precursor, if there is one.
         *
         *  At the sharpest tunings some machines compute a tiny early peak
         *  ahead of the real response -- smooth, monotone, entirely plausible
         *  looking, and absent on other hardware running the same source. It
         *  is a rounding artefact of a cascade whose first peak sits 200 dB
         *  below its own maximum, and it is not distinguishable from a
         *  response by anything about its shape or its position.
         *
         *  It is distinguishable by what follows it. Measured over both an
         *  arm64 and an x86 build of ERB 0.5: a genuine first peak is followed
         *  by a step of 42 to 54 dB, being the next cycle of a response still
         *  building; a precursor is followed by 62 to 282 dB, being the
         *  arrival of the response itself. The two ranges do not touch, and on
         *  the machine with no precursors nothing exceeds 51 dB, so this never
         *  fires there.
         *
         *  A kludge, and deliberately one. The principled fix -- stop
         *  measuring per machine, bake the delays so every build loads the
         *  same numbers -- has since been done: see tools/bakeall.sh and the
         *  note on the version check in `cochlea_create`. This rule now only
         *  shapes a curve at the moment of baking, on the one machine that
         *  bakes, instead of differing from machine to machine in the field.
         *
         *  It is not where ERB 0.5's shipped curve came from. That one was
         *  chosen by hand through `peakdump --peak 2` and checked against the
         *  picture, and stays that way. This rule is what the blunter tunings
         *  were baked with, whether or not it found anything to step over on
         *  the machine that baked them. */
        constexpr double kPrecursorJumpDB = 60.0;

        resetState();
        std::vector<long> at(static_cast<size_t>(n), 0);
        std::vector<bool> found(static_cast<size_t>(n), false);
        /*  The second peak as well, and how far it stands above the first. */
        std::vector<long>   at2(static_cast<size_t>(n), -1);
        std::vector<double> lvl1(static_cast<size_t>(n), 0.0);
        std::vector<double> lvl2(static_cast<size_t>(n), 0.0);
        /* Counted in *internal* samples, which is what the delays are in and
         * is twice the resolution the input rate would give. */
        long isamp = 0;
        for (long i = 0; i < total; ++i) {
            feedInput(i == 0 ? 1.0 : 0.0, [&] {
                for (int t = 0; t < n; ++t) {
                    const size_t T = static_cast<size_t>(t);
                    const double thresh =
                        std::min(kLeadAbsolute, kLeadFraction * best[T]);
                    if (best[T] <= 0.0 || held[t] < thresh) continue;
                    if (!found[T]) {
                        found[T] = true;
                        at[T] = isamp;
                        lvl1[T] = held[t];
                    } else if (at2[T] < 0 && held[t] > lvl1[T]) {
                        /* `held` is a running maximum, so the next time it
                           moves is the next peak. */
                        at2[T] = isamp;
                        lvl2[T] = held[t];
                    }
                }
                ++isamp;
            });
        }
        for (int t = 0; t < n; ++t) {
            const size_t T = static_cast<size_t>(t);
            long when = at[T];
            if (at2[T] >= 0 && lvl1[T] > 0.0 && lvl2[T] > 0.0) {
                const double jump = 20.0 * std::log10(lvl2[T] / lvl1[T]);
                if (jump > kPrecursorJumpDB) when = at2[T];
            }
            gdelay[T] = static_cast<double>(when) / fs;
        }
        resetState();
        recomputeShifts();
    }

    /*  Back to silence, with nothing left over from whatever was fed in. */
    void resetState() {
        std::fill(z1.begin(), z1.end(), 0.0);
        std::fill(z2.begin(), z2.end(), 0.0);
        std::fill(p1.begin(), p1.end(), 0.0);
        std::fill(p2.begin(), p2.end(), 0.0);
        std::fill(held.begin(), held.end(), 0.0);
        std::fill(held_dt.begin(), held_dt.end(), 0.0);
        std::fill(peak_time.begin(), peak_time.end(), kNoPeak);
        std::fill(history.begin(), history.end(), 0.0f);
        std::fill(history_dt.begin(), history_dt.end(), 0.0f);
        std::fill(history_range.begin(), history_range.end(), 0.0f);
        in_lo =  1e30f;
        in_hi = -1e30f;
        hist_pos = 0;
        sample_index = 0.0;
        column_accum = 0.0;
        resample_phase = 0.0;
        last_in = 0.0;
        auto_ref = 1e-6;
        mear.reset();
        up.reset();
    }

    inline void emitColumn() {
        float *row = &history[static_cast<size_t>(hist_pos) * n_taps];
        float *row_dt = &history_dt[static_cast<size_t>(hist_pos) * n_taps];
        double loudest = 0.0;
        for (int t = 0; t < n_taps; ++t) {
            row[t] = static_cast<float>(held[t]);
            row_dt[t] = static_cast<float>(held_dt[t]);
            if (held[t] > loudest) loudest = held[t];
        }
        auto_ref = loudest > auto_ref ? loudest
                                      : std::fmax(auto_ref * auto_decay, 1e-7);

        /* dB relative to full scale.  The display subtracts whichever
         * reference it wants -- this one, or a fixed one of its own. */
        for (int t = 0; t < n_taps; ++t) {
            int src = hist_pos - shift[t];
            while (src < 0) src += kMaxDeskewColumns;
            const size_t at = static_cast<size_t>(src) * n_taps + t;
            scratch[t] = static_cast<float>(
                20.0 * std::log10(std::fmax(history[at], kTinyLevel)));
            /* Already the number the display wants; no reference, no
             * logarithm.  Tap 0 has no tap above it and stays at zero. */
            scratch_dt[t] = history_dt[at];
        }
        /*  The input's range, written into this column's slot and read back
         *  `max_shift` columns, which is the same delay the *slowest* tap is
         *  held to.
         *
         *  That is what makes the waveform line up with the picture instead of
         *  needing a correction somewhere else. De-skew holds every tap back to
         *  the apex's travel time, so the column being emitted depicts events
         *  from `max_shift` columns ago -- and the input from `max_shift`
         *  columns ago is exactly the sound those events were made of. With
         *  De-skew off `max_shift` is zero and this is simply the input during
         *  this column, which is right for the same reason.
         *
         *  Written before it is read, so with no delay a column reports its own
         *  input rather than the previous one's.  */
        const size_t here = static_cast<size_t>(hist_pos) * 2;
        const bool any = in_hi >= in_lo;
        history_range[here]     = any ? in_lo : 0.0f;
        history_range[here + 1] = any ? in_hi : 0.0f;
        in_lo =  1e30f;
        in_hi = -1e30f;

        int rsrc = hist_pos - max_shift;
        while (rsrc < 0) rsrc += kMaxDeskewColumns;
        const size_t rat = static_cast<size_t>(rsrc) * 2;

        ring.push(scratch.data(), scratch_dt.data(),
                  static_cast<float>(20.0 * std::log10(
                      std::fmax(auto_ref, 1e-12))),
                  history_range[rat], history_range[rat + 1]);
        hist_pos = (hist_pos + 1) % kMaxDeskewColumns;
    }
};

/* ------------------------------------------------------------------------- */

namespace {

bool readAll(FILE *f, void *dst, size_t bytes) {
    return std::fread(dst, 1, bytes, f) == bytes;
}

bool readVec(FILE *f, std::vector<double> &v, int n) {
    v.resize(n);
    return readAll(f, v.data(), sizeof(double) * static_cast<size_t>(n));
}

}  // namespace

CochleaEngine *cochlea_create(const char *coeff_path, double input_rate) {
    FILE *f = std::fopen(coeff_path, "rb");
    if (!f) return nullptr;

    char magic[4];
    int32_t version = 0, n_ch = 0, n_lead = 0, tpo = 0;
    double fs = 0.0;
    bool ok = readAll(f, magic, 4) && std::memcmp(magic, "COCH", 4) == 0 &&
              readAll(f, &version, 4) && (version == 1 || version == 2) &&
              readAll(f, &fs, 8) &&
              readAll(f, &n_ch, 4) && readAll(f, &n_lead, 4) &&
              readAll(f, &tpo, 4) &&
              n_ch > 0 && n_lead >= 0 && n_lead < n_ch;
    if (!ok) { std::fclose(f); return nullptr; }

    CochleaEngine *e = new CochleaEngine();
    e->n_ch = n_ch;
    e->n_lead = n_lead;
    e->n_taps = n_ch - n_lead;
    e->fs = fs;
    e->input_rate = input_rate;

    ok = readVec(f, e->a0, n_ch) && readVec(f, e->c0, n_ch) &&
         readVec(f, e->h, n_ch) && readVec(f, e->r, n_ch) &&
         readVec(f, e->g, n_ch) && readVec(f, e->norm, n_ch) &&
         readVec(f, e->bf, e->n_taps) && readVec(f, e->gdelay, e->n_taps) &&
         readVec(f, e->idelay, e->n_taps);
    std::fclose(f);
    if (!ok) { delete e; return nullptr; }

    e->z1.assign(n_ch, 0.0);
    e->z2.assign(n_ch, 0.0);
    e->p1.assign(e->n_taps, 0.0);
    e->p2.assign(e->n_taps, 0.0);
    e->held.assign(e->n_taps, 0.0);
    e->peak_time.assign(e->n_taps, CochleaEngine::kNoPeak);
    e->held_dt.assign(e->n_taps, 0.0);

    /*  The filterbank's own phase step between neighbouring taps, smoothed.
     *  Edges replicate rather than zero-pad: zero-padding would pull the
     *  outermost taps toward a value the design never has, which is exactly
     *  where the apex and the base already need the most care. */
    {
        const int n = e->n_taps;
        std::vector<double> raw(static_cast<size_t>(n), 0.0);
        for (int t = 1; t < n; ++t) {
            raw[t] = (e->gdelay[t] - e->gdelay[t - 1]) * e->bf[t];
        }
        if (n > 1) raw[0] = raw[1];
        constexpr int kHalf = 6;             /* 13 taps, about a fifth octave */
        e->dt_base.assign(n, 0.0);
        for (int t = 0; t < n; ++t) {
            double s = 0.0;
            for (int j = -kHalf; j <= kHalf; ++j) {
                int i = t + j;
                i = i < 0 ? 0 : (i >= n ? n - 1 : i);
                s += raw[i];
            }
            e->dt_base[t] = s / (2 * kHalf + 1);
        }
    }
    e->shift.assign(e->n_taps, 0);
    e->scratch.assign(e->n_taps, 0.0f);
    e->scratch_dt.assign(e->n_taps, 0.0f);
    e->history.assign(static_cast<size_t>(e->n_taps) * kMaxDeskewColumns, 0.0f);
    e->history_dt.assign(static_cast<size_t>(e->n_taps) * kMaxDeskewColumns, 0.0f);
    e->history_range.assign(static_cast<size_t>(kMaxDeskewColumns) * 2, 0.0f);
    e->ring.init(e->n_taps);
    /*  At the host's rate, not the internal one: what is kept is the input as
     *  handed over, so that playing it back reproduces what was heard. */
    e->capture.init(input_rate);

    /*  Rate handling.  The common cases are exact: 44.1 -> 88.2 and 48 -> 96
     *  are a clean 2x, handled by the half-band filter.  Anything else falls
     *  back to linear interpolation at a fractional step, which is not good
     *  enough for audio but is fine for driving an analysis display.       */
    e->need_upsample = std::fabs(fs - 2.0 * input_rate) < 1.0;
    e->resample_step = input_rate / fs;

    e->mear.design(fs);
    e->inv_fs = 1.0 / fs;

    e->samples_per_column = fs * e->column_ms * 1e-3;
    e->recomputeShifts();
    e->recomputeAutoDecay();
    /*  Last, because it runs audio through the finished engine and then puts
     *  it back the way it found it. */
    e->calibrateCoherence();
    /*  Version 2 carries a measured de-skew curve in `gdelay`, and the engine
     *  uses it as it stands. Every tuning that ships is version 2, so in the
     *  app this branch is not taken and `calibrateDelays` does not run.
     *
     *  Measuring it here means every machine measures its own, and at the
     *  sharpest tunings they do not agree: the first peak of a narrow filter
     *  sits 200 dB below its own maximum, where whether a sample crosses a
     *  threshold is settled in the last bits of the arithmetic. Two builds of
     *  this file, clang on arm64 and gcc on x86, choose different peaks for a
     *  band of taps around 30 Hz at ERB 0.5 and draw a click 87 ms out of line
     *  from each other. A quantity that depends on the compiler is not a
     *  property of the filterbank, and no threshold makes it one. The curve
     *  also depends on the input rate, since the impulse arrives through
     *  `feedInput` and 44100 takes the half-band path while 48000 does not.
     *
     *  So the curve is baked: measured once on a nominated machine at 44100,
     *  written into the file, loaded identically everywhere. See
     *  tools/bakeall.sh, which is how the shipped files were made.
     *
     *  The version-1 path stays, and is not dead. It is what performs the
     *  measurement that baking captures: `tools/measuredelays` loads a
     *  freshly exported version-1 file precisely to make this run. It is also
     *  the fallback for a file that predates the bake. Baking is worth about
     *  200 ms of the 440 an engine build costs -- paid at launch, on every
     *  ERB change and on every device change. */
    if (version < 2) {
        /*  After the coherence pass, and after the analytic dt_base above was
         *  derived from the file's delays: this overwrites gdelay with
         *  measured ones, and doing it earlier would change a fallback that
         *  has nothing to do with de-skew. */
        e->calibrateDelays();
    } else {
        e->recomputeShifts();
    }
    return e;
}

void cochlea_destroy(CochleaEngine *e) { delete e; }

int    cochlea_tap_count(const CochleaEngine *e) { return e ? e->n_taps : 0; }
double cochlea_internal_rate(const CochleaEngine *e) { return e ? e->fs : 0.0; }
const double *cochlea_frequencies(const CochleaEngine *e) {
    return e ? e->bf.data() : nullptr;
}
const double *cochlea_delays(const CochleaEngine *e) {
    return e ? e->gdelay.data() : nullptr;
}

void cochlea_set_column_ms(CochleaEngine *e, double ms) {
    if (!e || ms <= 0.0) return;
    e->column_ms = ms;
    e->samples_per_column = e->fs * ms * 1e-3;
    e->recomputeShifts();
    e->recomputeAutoDecay();
}

void cochlea_set_auto_gain_halflife(CochleaEngine *e, double halflife_s) {
    if (!e || halflife_s <= 0.0) return;
    e->auto_halflife = halflife_s;
    e->recomputeAutoDecay();
}

double cochlea_current_ref_db(const CochleaEngine *e) {
    return e ? 20.0 * std::log10(std::fmax(e->auto_ref, 1e-12)) : 0.0;
}

void cochlea_set_deskew(CochleaEngine *e, int enabled) {
    if (!e) return;
    e->deskew = enabled != 0;
    e->recomputeShifts();
}

void cochlea_process(CochleaEngine *e, const float *in, int n) {
    if (!e || !in) return;
    /*  Before the cascade, so that a buffer which is captured is captured
     *  whole: the loop below can leave part of a buffer unprocessed on no path
     *  today, but a recording that is sometimes short by a few samples is a
     *  drift nobody would find. */
    e->capture.push(in, n);
    float pk = e->peak.load(std::memory_order_relaxed);

    for (int i = 0; i < n; ++i) {
        const double x = static_cast<double>(in[i]);
        const float ax = std::fabs(in[i]);
        if (ax > pk) pk = ax;
        /*  Signed, unlike the peak above: a waveform is drawn about zero and
         *  wants both ends of the excursion, not its magnitude. Taken at the
         *  host's rate, before the resampler, so it is the sound as handed
         *  over. */
        if (in[i] < e->in_lo) e->in_lo = in[i];
        if (in[i] > e->in_hi) e->in_hi = in[i];

        if (e->need_upsample) {
            double two[2];
            e->up.step(x, two);
            for (int j = 0; j < 2; ++j) {
                e->runCascade(two[j]);
                e->column_accum += 1.0;
                if (e->column_accum >= e->samples_per_column) {
                    e->column_accum -= e->samples_per_column;
                    e->emitColumn();
                }
            }
        } else {
            /* Fractional rate: emit internal samples until we have consumed
             * this input sample, interpolating linearly between the last two. */
            while (e->resample_phase < 1.0) {
                const double s = e->last_in +
                                 (x - e->last_in) * e->resample_phase;
                e->runCascade(s);
                e->column_accum += 1.0;
                if (e->column_accum >= e->samples_per_column) {
                    e->column_accum -= e->samples_per_column;
                    e->emitColumn();
                }
                e->resample_phase += e->resample_step;
            }
            e->resample_phase -= 1.0;
            e->last_in = x;
        }
    }
    e->peak.store(pk, std::memory_order_relaxed);
}

int cochlea_pull_columns(CochleaEngine *e, float *levels, float *coherence,
                         float *refs, float *in_lo, float *in_hi,
                         int max_cols) {
    if (!e || max_cols <= 0) return 0;
    return e->ring.pull(levels, coherence, refs, in_lo, in_hi, max_cols);
}

uint64_t cochlea_dropped_columns(const CochleaEngine *e) {
    return e ? e->ring.dropped() : 0;
}

void cochlea_set_capture(CochleaEngine *e, int enabled) {
    if (e) e->capture.setEnabled(enabled != 0);
}

int cochlea_capture_enabled(const CochleaEngine *e) {
    return (e && e->capture.enabled()) ? 1 : 0;
}

int cochlea_pull_input(CochleaEngine *e, float *out, int max) {
    if (!e) return 0;
    return e->capture.pull(out, max);
}

uint64_t cochlea_dropped_input(const CochleaEngine *e) {
    return e ? e->capture.dropped() : 0;
}

float cochlea_peak_level(CochleaEngine *e) {
    if (!e) return 0.0f;
    return e->peak.exchange(0.0f, std::memory_order_relaxed);
}
