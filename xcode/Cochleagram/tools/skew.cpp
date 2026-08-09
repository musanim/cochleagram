/*
 *  skew.cpp -- does a click stand vertical, and where does it not?
 *
 *  Feeds a single-sample impulse and reports, per tap, when that tap's
 *  sample-and-hold level peaked. With De-skew on every row should peak at the
 *  same moment; the last column says how far from that the worst row is.
 *
 *  Built to settle an argument that could not be settled by looking: the
 *  de-skew shifts were clamped to 255 columns, which at fine Speeds gave every
 *  tap above a certain frequency the *same* hold-back instead of one that grows
 *  with frequency, so the picture kept its skew and only moved. The crossover
 *  frequency this printed matched the one Stephen had read off the screen to
 *  within one label.
 *
 *      c++ -std=c++17 -O2 -I ../Sources/CochleaDSP/include \
 *          skew.cpp ../Sources/CochleaDSP/cochlea.cpp -o skew
 *      ./skew ../Sources/CochleagramApp/Resources/cochlea_88200_erb100.coch 1 0.5
 *
 *  Arguments: coefficient file, de-skew (0/1), milliseconds per column.
 */
#include "cochlea.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
int main(int argc, char **argv) {
    const double rate = 44100.0, colMS = atof(argv[3]);
    CochleaEngine *e = cochlea_create(argv[1], rate);
    cochlea_set_column_ms(e, colMS);
    cochlea_set_deskew(e, atoi(argv[2]));
    const int taps = cochlea_tap_count(e);
    const double *design = cochlea_delays(e);
    const int N = (int)(rate * 0.9);
    std::vector<float> in(N, 0.0f); in[64] = 1.0f;
    std::vector<float> lv(256 * taps), rf(256);
    std::vector<float> best(taps, -1e30f);
    std::vector<double> when(taps, -1);
    long long col = 0;
    for (int i = 0; i + 128 <= N; i += 128) {
        cochlea_process(e, in.data() + i, 128);
        int got;
        while ((got = cochlea_pull_columns(e, lv.data(), nullptr, rf.data(), 256)) > 0) {
            for (int c = 0; c < got; ++c) for (int t = 0; t < taps; ++t) {
                float v = lv[c * taps + t];
                if (v > best[t] + 1e-6f) { best[t] = v; when[t] = (col + c) * colMS; }
            }
            col += got;
            if (got < 256) break;
        }
    }
    const double t0 = 64.0 / rate * 1000.0;
    printf("colMS %.2f deskew %s\n", colMS, argv[2]);
    printf("%6s %9s %10s %9s %s\n", "tap", "Hz", "peak(ms)", "level", "need(cols)");
    for (int t = 0; t < taps; t += 50) {
        double need = (design[598] - design[t]) / (colMS * 1e-3);
        printf("%6d %9.1f %10.2f %9.1f %10.0f%s\n", t, cochlea_frequencies(e)[t],
               when[t] - t0, best[t], need, need > 255 ? "  CLAMPED" : "");
    }
    return 0;
}
