/*
 *  measuredelays -- the de-skew curve this engine build computes, as text.
 *
 *  Half of baking a tuning at design time. The engine already knows how to
 *  measure its own de-skew curve -- `calibrateDelays` runs an impulse through
 *  the finished cascade and takes each tap's first peak, precursor rule and
 *  all -- and the point of this tool is to capture *that* answer rather than
 *  reimplement the measurement somewhere else. It loads a coefficient file,
 *  lets `cochlea_create` calibrate exactly as the app would, and prints the
 *  resulting curve. `bakedelays.py --curve` writes it back into the file.
 *
 *  Why not measure in Python, in export_coeffs.py, where the coefficients
 *  come from: at the sharpest tunings the answer is decided in the last bits
 *  of the arithmetic, so a second implementation would be a third answer, not
 *  the canonical one. The curve that ships has to be the curve the engine
 *  computes, from one nominated machine.
 *
 *      c++ -std=c++17 -O2 -I ../Sources/CochleaDSP/include \
 *          measuredelays.cpp ../Sources/CochleaDSP/cochlea.cpp \
 *          -o /tmp/measuredelays
 *      /tmp/measuredelays coeffs.coch 44100
 *
 *  Only a version-1 file measures anything, which after the bake means a
 *  freshly exported one. Every file that ships is version 2 and is refused;
 *  `--force` measures one anyway, for comparison, and writes nothing.
 *
 *  The curve depends on the input rate, because the impulse goes in through
 *  `feedInput` and 44100 takes the exact half-band path while 48000 falls
 *  back to fractional interpolation. Measured across the bakes, anchored on
 *  each curve's own maximum so a constant cancels, the two rates agree to
 *  0.15 ms at ERB 0.8 and blunter; at 0.7 five taps near 1.7 kHz differ by
 *  0.85 ms; at 0.6 one tap at 447 Hz differs by 2.88 ms. Isolated peak-index
 *  flips rather than a different curve -- but a bake has to name a rate, and
 *  44100 is it, matching the ERB 0.5 file and the exact 2x path.
 *
 *  Output is `#`-commented header lines and then one line per tap, which is
 *  both what bakedelays.py reads and something two machines can be diffed
 *  through. Keep a copy in figures/caldump/ beside the reference curves.
 */
#include "cochlea.h"

#include <cfloat>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>

/*  Enough of the build to tell two of them apart -- the same fingerprint
 *  caldump prints, and for the same reason: floating-point contraction is the
 *  first suspect when one source gives two answers. A baked curve is only
 *  meaningful next to a record of what measured it. */
static void describeBuild(FILE *out) {
    std::fprintf(out, "# build: ");
#if defined(__clang__)
    std::fprintf(out, " clang %d.%d.%d", __clang_major__, __clang_minor__,
                 __clang_patchlevel__);
#elif defined(__GNUC__)
    std::fprintf(out, " gcc %d.%d.%d", __GNUC__, __GNUC_MINOR__,
                 __GNUC_PATCHLEVEL__);
#else
    std::fprintf(out, " unknown compiler");
#endif
#if defined(__aarch64__) || defined(__arm64__)
    std::fprintf(out, "  arm64");
#elif defined(__x86_64__)
    std::fprintf(out, "  x86_64");
#else
    std::fprintf(out, "  unknown arch");
#endif
#ifdef __FAST_MATH__
    std::fprintf(out, "  FAST_MATH");
#endif
#ifdef __FP_FAST_FMA
    std::fprintf(out, "  FP_FAST_FMA");
#endif
    std::fprintf(out, "  FLT_EVAL_METHOD=%d\n", (int)FLT_EVAL_METHOD);
}

/*  Magic and version only. The rest of the layout is bakedelays.py's business
 *  and is not repeated here; this reads four bytes at offset 4 so it can
 *  refuse a file whose curve is already baked. */
static bool readVersion(const char *path, int32_t *version) {
    FILE *f = std::fopen(path, "rb");
    if (!f) return false;
    char magic[4];
    bool ok = std::fread(magic, 1, 4, f) == 4 &&
              std::memcmp(magic, "COCH", 4) == 0 &&
              std::fread(version, 1, 4, f) == 4;
    std::fclose(f);
    return ok;
}

/*  Present a version-2 file to the engine as a version-1 one, so it
 *  calibrates instead of loading the curve it already carries.
 *
 *  For diagnostics only -- "what would this machine have measured?" against a
 *  curve that is already settled. It writes a copy; the original is not
 *  touched. Version is an int32 at offset 4, which is the one piece of the
 *  layout this file knows.
 *
 *  The header goes out as its own write before anything is copied, rather
 *  than being patched inside the first block. Patching the first block makes
 *  the edit conditional on that block being at least eight bytes long, which
 *  a short read is entitled not to be -- and the failure is silent: the copy
 *  stays version 2, the engine loads the baked curve instead of measuring
 *  one, and the output is labelled a measurement. */
static bool copyAsVersion1(const char *src, const std::string &dst) {
    FILE *in = std::fopen(src, "rb");
    if (!in) return false;

    char header[8];
    if (std::fread(header, 1, 8, in) != 8) { std::fclose(in); return false; }
    const int32_t one = 1;
    std::memcpy(header + 4, &one, 4);

    FILE *out = std::fopen(dst.c_str(), "wb");
    if (!out) { std::fclose(in); return false; }

    bool ok = std::fwrite(header, 1, 8, out) == 8;
    char buf[65536];
    size_t n;
    while (ok && (n = std::fread(buf, 1, sizeof buf, in)) > 0) {
        ok = std::fwrite(buf, 1, n, out) == n;
    }
    /*  A read error looks exactly like end of file to the loop above, and a
     *  buffered write error may not surface until the close. Neither may pass
     *  for success: a truncated copy loads as a malformed file if we are
     *  lucky and as a shorter cascade if we are not. */
    if (std::ferror(in)) ok = false;
    std::fclose(in);
    if (std::fclose(out) != 0) ok = false;
    return ok;
}

int main(int argc, char **argv) {
    const char *path = nullptr;
    double rate = 44100.0;
    bool force = false, haveRate = false;
    /*  Strict, because the failure this guards against is silent and total.
     *  `atof` on anything it does not understand returns 0.0, an input rate
     *  of zero makes `calibrateDelays` run its impulse for zero samples, and
     *  every tap then reports a delay of zero. A curve of 599 zeroes is a
     *  well-formed curve: it bakes, it loads, and it draws a picture with no
     *  de-skew at all. A mistyped flag must not reach that. */
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--force") == 0) {
            force = true;
        } else if (std::strcmp(argv[i], "--build") == 0) {
            /*  The fingerprint alone, without calibrating anything, so a
             *  driver script can say which machine it is about to bake from
             *  before spending a second per tuning finding out. */
            describeBuild(stdout);
            return 0;
        } else if (argv[i][0] == '-' && argv[i][1] != '\0') {
            std::fprintf(stderr, "measuredelays: unknown option %s\n", argv[i]);
            return 2;
        } else if (!path) {
            path = argv[i];
        } else if (!haveRate) {
            char *end = nullptr;
            rate = std::strtod(argv[i], &end);
            if (end == argv[i] || *end != '\0' || !(rate >= 8000.0) ||
                !(rate <= 768000.0)) {
                std::fprintf(stderr,
                             "measuredelays: %s is not a sample rate\n",
                             argv[i]);
                return 2;
            }
            haveRate = true;
        } else {
            std::fprintf(stderr, "measuredelays: unexpected argument %s\n",
                         argv[i]);
            return 2;
        }
    }
    if (!path) {
        std::fprintf(stderr,
                     "usage: measuredelays <coeffs.coch> [input_rate] "
                     "[--force]\n"
                     "       measuredelays --build\n");
        return 2;
    }

    int32_t version = 0;
    if (!readVersion(path, &version)) {
        std::fprintf(stderr, "%s: not a coefficient file\n", path);
        return 1;
    }

    std::string temp;
    const char *load = path;
    if (version >= 2) {
        if (!force) {
            /*  Loading it would skip calibration and echo the curve already
             *  in the file, which looks like a measurement and is not one. */
            std::fprintf(stderr,
                         "%s: already version %d -- the curve is baked, so "
                         "the engine would not calibrate.\n"
                         "  Pass --force to measure it anyway (writes "
                         "nothing; for comparison only).\n",
                         path, (int)version);
            return 1;
        }
        /*  In the temporary directory, not beside the original: the original
         *  lives in the app's Resources, which may be read-only, is scanned
         *  by SwiftPM, and should not collect debris from a diagnostic. */
        const char *tmpdir = std::getenv("TMPDIR");
        temp = std::string(tmpdir && *tmpdir ? tmpdir : "/tmp");
        if (temp.back() != '/') temp += '/';
        temp += "measuredelays." + std::to_string((long)getpid()) + ".coch";
        if (!copyAsVersion1(path, temp)) {
            std::fprintf(stderr, "%s: could not write %s\n", path,
                         temp.c_str());
            std::remove(temp.c_str());     /* may be a partial copy */
            return 1;
        }
        int32_t check = 0;
        if (!readVersion(temp.c_str(), &check) || check != 1) {
            /*  Belt and braces. If this is ever not 1 the engine loads the
             *  baked curve and we print it as a measurement, which is the one
             *  wrong answer this tool must never give. */
            std::fprintf(stderr, "%s: copy is version %d, not 1 -- refusing\n",
                         path, (int)check);
            std::remove(temp.c_str());
            return 1;
        }
        load = temp.c_str();
    }

    CochleaEngine *e = cochlea_create(load, rate);
    if (!temp.empty()) std::remove(temp.c_str());
    if (!e) {
        std::fprintf(stderr, "%s: could not load\n", path);
        return 1;
    }

    const int n = cochlea_tap_count(e);
    const double *d = cochlea_delays(e);
    const double *f = cochlea_frequencies(e);

    const char *name = std::strrchr(path, '/');
    name = name ? name + 1 : path;
    std::printf("# measuredelays: %s\n", name);
    describeBuild(stdout);
    std::printf("# input rate: %.0f Hz\n", rate);
    std::printf("# file version: %d%s\n", (int)version,
                version >= 2 ? "  (forced: measured, not the baked curve)" : "");
    std::printf("# taps: %d\n", n);
    /*  bakedelays.py --curve reads field 0 as the tap and field 2 as the
     *  delay in milliseconds. Frequency is for the reader. */
    std::printf("#%4s %10s %12s\n", "tap", "freq_Hz", "delay_ms");
    for (int t = 0; t < n; ++t) {
        std::printf("%5d %10.2f %12.6f\n", t, f[t], d[t] * 1000.0);
    }
    cochlea_destroy(e);
    /*  The output is the whole product, and it is usually redirected into a
     *  file that something else then bakes. A curve truncated by a full disk
     *  must not exit 0. */
    if (std::fflush(stdout) != 0 || std::ferror(stdout)) {
        std::fprintf(stderr, "%s: could not write the curve\n", path);
        return 1;
    }
    return 0;
}
