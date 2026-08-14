/*
 *  caldump -- what did the calibration actually decide, on *this* machine?
 *
 *  The de-skew reference is measured at engine build time by running an
 *  impulse through the cascade. Everything downstream -- whether a click
 *  stands vertical, where the leading edge lands, what De-skew costs in
 *  latency -- follows from the numbers it produces, and until now the only
 *  way to see them was to infer them from a screenshot.
 *
 *  Written because a Mac build and a Linux build of the same source disagreed
 *  about those numbers, and no amount of reading the picture could say why.
 *  It prints the delay curve, so two machines can be compared tap by tap
 *  rather than through a single summary that might agree by accident.
 *
 *      c++ -std=c++17 -O2 -I ../Sources/CochleaDSP/include \
 *          caldump.cpp ../Sources/CochleaDSP/cochlea.cpp -o /tmp/caldump
 *      /tmp/caldump ../Sources/CochleagramApp/Resources/cochlea_88200_erb060.coch
 *
 *  With no coefficient file it looks for all of them beside itself and prints
 *  one summary line each, which is the quick comparison; with one file it
 *  prints that bake's whole curve, which is the slow one.
 */
#include "cochlea.h"

#include <cfloat>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

/*  Enough of the build to tell two of them apart. Floating-point contraction
 *  is the first suspect when the same source gives different answers on
 *  different machines: a fused multiply-add rounds once where a separate
 *  multiply and add round twice, and the cascade is nothing but multiply-adds.
 */
static void describeBuild() {
    std::printf("build:  ");
#if defined(__clang__)
    std::printf("clang %d.%d.%d", __clang_major__, __clang_minor__,
                __clang_patchlevel__);
#elif defined(__GNUC__)
    std::printf("gcc %d.%d.%d", __GNUC__, __GNUC_MINOR__, __GNUC_PATCHLEVEL__);
#else
    std::printf("unknown compiler");
#endif
#if defined(__aarch64__) || defined(__arm64__)
    std::printf("  arm64");
#elif defined(__x86_64__)
    std::printf("  x86_64");
#else
    std::printf("  unknown arch");
#endif
#ifdef __FAST_MATH__
    std::printf("  FAST_MATH");
#endif
#ifdef __FP_FAST_FMA
    std::printf("  FP_FAST_FMA");
#endif
    std::printf("  FLT_EVAL_METHOD=%d\n", (int)FLT_EVAL_METHOD);
}

/*  A number that changes if any tap's delay changes, so two runs can be
 *  compared at a glance before anyone starts diffing curves. Not a hash with
 *  any pretensions -- just a sum that will not hide a one-sample difference. */
static double curveSum(const double *d, int n) {
    double s = 0.0;
    for (int i = 0; i < n; ++i) s += d[i] * 1000.0 * (i + 1);
    return s;
}

static bool summarise(const char *path, double rate, bool full) {
    CochleaEngine *e = cochlea_create(path, rate);
    if (!e) {
        std::printf("  %-28s  could not load\n", path);
        return false;
    }
    const int n = cochlea_tap_count(e);
    const double *d = cochlea_delays(e);
    const double *f = cochlea_frequencies(e);

    double dmin = 1e30, dmax = -1e30;
    int backward = 0;
    double worstBack = 0.0, worstBackHz = 0.0;
    for (int t = 0; t < n; ++t) {
        if (d[t] < dmin) dmin = d[t];
        if (d[t] > dmax) dmax = d[t];
        if (t > 0 && d[t] < d[t - 1] - 1e-8) {
            ++backward;
            const double step = (d[t] - d[t - 1]) * 1000.0;
            if (step < worstBack) { worstBack = step; worstBackHz = f[t]; }
        }
    }

    const char *name = std::strrchr(path, '/');
    name = name ? name + 1 : path;
    std::printf("  %-28s %6.1f-%-6.0f Hz  dmin %7.3f  dmax %8.3f ms  "
                "sum %14.3f  backward %d",
                name, f[n - 1], f[0], dmin * 1000.0, dmax * 1000.0,
                curveSum(d, n), backward);
    if (backward) std::printf(" (worst %.3f ms at %.1f Hz)", worstBack, worstBackHz);
    std::printf("\n");

    if (full) {
        std::printf("\n%5s %10s %12s %12s\n", "tap", "freq_Hz", "delay_ms",
                    "step_ms");
        for (int t = 0; t < n; ++t) {
            std::printf("%5d %10.2f %12.4f %12.4f\n", t, f[t], d[t] * 1000.0,
                        t ? (d[t] - d[t - 1]) * 1000.0 : 0.0);
        }
    }
    cochlea_destroy(e);
    return true;
}

int main(int argc, char **argv) {
    const double rate = (argc > 2) ? std::atof(argv[2]) : 44100.0;
    describeBuild();
    std::printf("input rate: %.0f Hz\n\n", rate);

    if (argc > 1) {
        summarise(argv[1], rate, /*full=*/true);
        return 0;
    }
    /*  No argument: every bake that can be found in the usual places, one
     *  line each. Paths relative to the tools directory and to the repo root,
     *  so it works from either. */
    static const char *dirs[] = {
        "../Sources/CochleagramApp/Resources",
        "Sources/CochleagramApp/Resources",
        "xcode/Cochleagram/Sources/CochleagramApp/Resources",
        ".",
    };
    static const char *scales[] = {"050", "060", "070", "080", "090",
                                   "100", "110", "120", "130"};
    for (const char *dir : dirs) {
        std::string probe = std::string(dir) + "/cochlea_88200_erb100.coch";
        FILE *t = std::fopen(probe.c_str(), "rb");
        if (!t) continue;
        std::fclose(t);
        std::printf("coefficients in %s\n", dir);
        for (const char *s : scales) {
            std::string p = std::string(dir) + "/cochlea_88200_erb" + s + ".coch";
            FILE *g = std::fopen(p.c_str(), "rb");
            if (!g) continue;
            std::fclose(g);
            summarise(p.c_str(), rate, /*full=*/false);
        }
        return 0;
    }
    std::printf("No coefficient files found. Pass one as an argument.\n");
    return 1;
}
