/*
 *  cochlea.h -- real-time cochlea filter cascade, C ABI.
 *
 *  Deliberately a plain C interface over a C++ implementation, so it drops into
 *  a Swift app, an AU/VST plugin, or a command-line tool without ceremony.
 *
 *  Threading: one CochleaEngine belongs to one audio thread.  cochlea_process()
 *  is real-time safe -- no allocation, no locks, no syscalls.  Pull display
 *  columns from another thread with cochlea_pull_columns(), which reads from a
 *  single-producer / single-consumer ring buffer.
 */

#ifndef COCHLEA_H
#define COCHLEA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CochleaEngine CochleaEngine;

/* ---- lifecycle ---------------------------------------------------------- */

/*  Load a coefficient set written by prototype/export_coeffs.py.
 *  `input_rate` is the rate the host will feed samples at (44100, 48000, ...).
 *  The engine resamples internally to the rate the coefficients were designed
 *  for.  Returns NULL if the file is missing or malformed.               */
CochleaEngine *cochlea_create(const char *coeff_path, double input_rate);

void cochlea_destroy(CochleaEngine *e);

/* ---- geometry ----------------------------------------------------------- */

int    cochlea_tap_count(const CochleaEngine *e);       /* rows in the display */
double cochlea_internal_rate(const CochleaEngine *e);
/*  Best frequency of each tap, high to low -- tap 0 is the top of the display.
 *  Array is tap_count long and owned by the engine.                       */
const double *cochlea_frequencies(const CochleaEngine *e);
/*  Group delay per tap, seconds.  Only needed if you want to draw your own
 *  time axis; de-skew is applied internally.                              */
const double *cochlea_delays(const CochleaEngine *e);

/* ---- configuration (safe to call between process() calls) --------------- */

/*  Milliseconds of audio per display column.  Default 4.0.                */
void cochlea_set_column_ms(CochleaEngine *e, double ms);
/*  Track the reference automatically: it follows the loudest tap upward at
 *  once and decays back with `halflife_s` (default 3 s).  The engine always
 *  tracks it and reports it per column; whether the display *uses* it is the
 *  display's business.                                                    */
void cochlea_set_auto_gain_halflife(CochleaEngine *e, double halflife_s);

/*  Reference the engine is currently tracking, in dB.  For a readout.    */
double cochlea_current_ref_db(const CochleaEngine *e);
/*  Compensate the travelling-wave delay so a click stands vertical.  Costs
 *  the apex's group delay (about 170 ms) in display latency, because the
 *  correction can only be applied by holding the faster taps back.
 *  Non-zero = on, which is the default.                                   */
void cochlea_set_deskew(CochleaEngine *e, int enabled);

/*  Every column carries two quantities.
 *
 *    levels     Each tap's held peak level, in dB relative to full scale.
 *
 *    coherence  When a tap peaks, how long ago the tap above it -- the next
 *       higher best frequency -- last peaked, expressed in cycles of the
 *       reporting tap's own best frequency, and held between peaks exactly as
 *       the amplitude is.  Tap 0 has nothing above it and reads zero.
 *
 *       The value is *signed*, because the phase step the cascade imposes on
 *       neighbouring taps all by itself has already been subtracted.  That
 *       step grows with frequency -- 0.05 cycles at 125 Hz against 0.24 at
 *       8 kHz -- and left in it swamps everything else, so white noise reads
 *       pale at the apex and dark at the base and nothing can be compared
 *       across the picture.  Zero therefore means "exactly the interval the
 *       filterbank would produce anyway", and belongs in the middle of a grey
 *       ramp rather than at one end.
 *
 *       Not in dB and not measured against any reference, so the auto-gain
 *       reference and the two ends of the level mapping mean nothing here.  On
 *       noise, on a tone and on speech the deviation stays within about
 *       +/- 0.05 cycles, which is a reasonable full scale.
 *
 *  Both are always produced.  The engine has no display mode: which quantity
 *  is drawn, and how, is a question about controls the display owns, and
 *  shipping both means changing one's mind re-renders what is already on
 *  screen rather than wiping it.
 */
/* ---- the audio thread --------------------------------------------------- */

/*  Feed `n` mono samples at the host's input rate.  Real-time safe.       */
void cochlea_process(CochleaEngine *e, const float *in, int n);

/* ---- the drawing thread ------------------------------------------------- */

/*  Copy up to `max_cols` finished display columns.
 *
 *  `levels` receives max_cols * tap_count floats: the level of each tap in
 *  decibels relative to full scale, column-major, tap 0 first (the highest
 *  frequency).  `coherence` receives the same shape in cycles, as described
 *  above.  `refs` receives one float per column -- the auto-gain
 *  reference, also in dB, that the engine was tracking when that column was
 *  produced.  Either pointer may be NULL.
 *
 *  Levels rather than pixels, deliberately.  Mapping level to grey needs a
 *  reference and a floor, both of which the user can change at any moment,
 *  and a display that has thrown the levels away cannot honour the change on
 *  anything already drawn -- so adjusting the controls while paused did
 *  nothing to the picture in front of you.  Shipping dB also means the
 *  consumer's re-mapping is a subtract, a scale and a clamp, with no
 *  logarithm: a whole screen costs a millisecond, which is what makes
 *  dragging a slider feel continuous.
 *
 *  Returns the number of columns written.  Non-blocking; returns 0 if none
 *  are ready.                                                             */
int cochlea_pull_columns(CochleaEngine *e, float *levels, float *coherence,
                         float *refs, int max_cols);

/*  How many columns were dropped because the consumer fell behind.  Useful
 *  as a health check while tuning buffer sizes; should stay at zero.      */
uint64_t cochlea_dropped_columns(const CochleaEngine *e);

/*  Peak input level since the last call, linear.  For a level meter.      */
float cochlea_peak_level(CochleaEngine *e);

#ifdef __cplusplus
}
#endif

#endif /* COCHLEA_H */
