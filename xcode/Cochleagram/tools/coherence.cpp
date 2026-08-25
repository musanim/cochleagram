/*
 *  coherence.cpp -- render the coherence display off-line, and print what the
 *  numbers actually are, before anyone decides how to colour them.
 *
 *      c++ -std=c++17 -O2 -I ../Sources/CochleaDSP/include coherence.cpp \
 *          ../Sources/CochleaDSP/cochlea.cpp -o coherence
 *      ./coherence coeffs.coch in.f32 44100 out.pgm [column_ms] [hi_cycles]
 *
 *  Grey ramp runs -hi_cycles = white through 0 = mid-grey to +hi_cycles =
 *  black, linear, no reference and no logarithm.  Also prints a histogram of the values and the
 *  per-tap spread, which is the thing worth knowing: a tap following the same
 *  partial as its neighbour should hold a steady fraction of a cycle, and a
 *  tap that is not should not.
 */
#include "cochlea.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

int main(int argc, char **argv) {
    if (argc < 5) {
        std::fprintf(stderr,
                     "usage: %s coeffs.coch input.f32 input_rate out.pgm "
                     "[column_ms] [hi_cycles]\n", argv[0]);
        return 2;
    }
    const double rate = std::atof(argv[3]);
    const double column_ms = argc > 5 ? std::atof(argv[5]) : 4.0;
    const double hi = argc > 6 ? std::atof(argv[6]) : 1.0;

    CochleaEngine *e = cochlea_create(argv[1], rate);
    if (!e) { std::fprintf(stderr, "cannot load %s\n", argv[1]); return 1; }
    cochlea_set_column_ms(e, column_ms);
    const int taps = cochlea_tap_count(e);
    const double *bf = cochlea_frequencies(e);

    FILE *f = std::fopen(argv[2], "rb");
    if (!f) { std::fprintf(stderr, "cannot open %s\n", argv[2]); return 1; }
    std::fseek(f, 0, SEEK_END);
    const long n = std::ftell(f) / 4;
    std::fseek(f, 0, SEEK_SET);
    std::vector<float> in(static_cast<size_t>(n));
    if (std::fread(in.data(), 4, static_cast<size_t>(n), f) != size_t(n)) {
        std::fprintf(stderr, "short read\n"); return 1;
    }
    std::fclose(f);

    std::vector<float> cols;
    std::vector<float> buf(static_cast<size_t>(taps) * 256);
    const int chunk = 512;
    for (long i = 0; i < n; i += chunk) {
        cochlea_process(e, in.data() + i, int(std::min<long>(chunk, n - i)));
        int got;
        while ((got = cochlea_pull_columns(e, nullptr, buf.data(), nullptr, nullptr, nullptr, 256)) > 0) {
            cols.insert(cols.end(), buf.begin(),
                        buf.begin() + size_t(got) * taps);
        }
    }
    const int ncols = int(cols.size() / taps);
    std::printf("%d taps x %d columns at %g ms\n", taps, ncols, column_ms);

    /*  Distribution.  The value is a signed deviation from the phase step the
     *  filterbank imposes by itself, so it straddles zero and the bins do
     *  too. */
    const int kBins = 10;
    std::vector<long> hist(size_t(kBins), 0);
    long total = 0, out = 0;
    for (int c = 0; c < ncols; ++c) {
        for (int t = 1; t < taps; ++t) {
            const double v = cols[size_t(c) * taps + t];
            ++total;
            const double u = (v / hi + 1.0) * 0.5;      /* -hi..hi -> 0..1 */
            if (u < 0.0 || u >= 1.0) { ++out; continue; }
            hist[size_t(u * kBins)]++;
        }
    }
    std::printf("distribution of the deviation, in cycles of own CF, "
                "over +/- %g\n", hi);
    for (int b = 0; b < kBins; ++b) {
        const double lo_e = -hi + 2.0 * hi * b / kBins;
        std::printf("  %+7.4f..%+7.4f  %6.2f%%\n", lo_e, lo_e + 2.0 * hi / kBins,
                    100.0 * hist[size_t(b)] / double(total ? total : 1));
    }
    std::printf("  outside          %6.2f%%\n",
                100.0 * out / double(total ? total : 1));

    /*  Is the drift with frequency simply the filterbank's own group delay?
     *
     *  Adjacent taps do not respond at the same instant: the cascade delays
     *  each tap a little more than the one above it, and that step, multiplied
     *  by the tap's own frequency, is a phase.  It is a property of the
     *  filterbank and has nothing to do with the sound, so if it accounts for
     *  the drift it should be taken out. */
    const double *gd = cochlea_delays(e);
    std::vector<double> mean(size_t(taps), 0.0), step(size_t(taps), 0.0);
    for (int t = 0; t < taps; ++t) {
        double s = 0.0, d = 0.0, prev = 0.0;
        for (int c = 0; c < ncols; ++c) {
            const double v = cols[size_t(c) * taps + t];
            s += v;
            if (c) d += std::fabs(v - prev);
            prev = v;
        }
        mean[size_t(t)] = ncols ? s / ncols : 0.0;
        step[size_t(t)] = ncols > 1 ? d / (ncols - 1) : 0.0;
    }

    double sx = 0, sy = 0, sxx = 0, syy = 0, sxy = 0;
    int m = 0;
    for (int t = 1; t < taps; ++t) {
        const double pred = (gd[t] - gd[t - 1]) * bf[t];
        const double obs = mean[size_t(t)];
        sx += pred; sy += obs; sxx += pred * pred;
        syy += obs * obs; sxy += pred * obs; ++m;
    }
    const double num = m * sxy - sx * sy;
    const double den = std::sqrt((m * sxx - sx * sx) * (m * syy - sy * sy));
    std::printf("\ncorrelation of the per-tap mean with the group-delay step: "
                "%.4f over %d taps\n", den > 0 ? num / den : 0.0, m);

    std::printf("\n%8s %9s %12s %12s %12s\n",
                "tap", "CF", "mean cycles", "gdelay step", "mean |step|");
    for (double target : {8000.0, 4000.0, 2000.0, 1000.0, 500.0, 250.0, 125.0}) {
        int k = 1;
        for (int t = 1; t < taps; ++t) {
            if (std::fabs(bf[t] - target) < std::fabs(bf[k] - target)) k = t;
        }
        std::printf("%8d %9.0f %12.4f %12.4f %12.4f\n", k, bf[k],
                    mean[size_t(k)], (gd[k] - gd[k - 1]) * bf[k],
                    step[size_t(k)]);
    }

    FILE *o = std::fopen(argv[4], "wb");
    std::fprintf(o, "P5\n%d %d\n255\n", ncols, taps);
    std::vector<unsigned char> row{};
    row.resize(size_t(ncols));
    for (int t = 0; t < taps; ++t) {
        for (int c = 0; c < ncols; ++c) {
            /* Signed: zero is mid-grey, so a tap that keeps exactly the
             * filterbank's own step is neither ink nor paper. */
            double u = (cols[size_t(c) * taps + t] / (hi > 0 ? hi : 1.0)
                        + 1.0) * 0.5;
            u = u < 0 ? 0 : (u > 1 ? 1 : u);
            row[size_t(c)] = (unsigned char)std::lround((1.0 - u) * 255.0);
        }
        std::fwrite(row.data(), 1, row.size(), o);
    }
    std::fclose(o);
    std::printf("\nwrote %s (%d x %d)\n", argv[4], ncols, taps);
    cochlea_destroy(e);
    return 0;
}
