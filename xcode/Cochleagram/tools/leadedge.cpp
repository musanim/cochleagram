/*
 *  leadedge.cpp -- where does each row of the picture first go dark?
 *
 *  The companion to skew.cpp, and the more honest of the two. skew.cpp finds
 *  each tap's *largest* peak; this finds its leading edge -- the first column
 *  within 20 dB of that tap's own maximum -- which is the feature the eye
 *  actually follows and the one de-skew has to line up. The two differ by a
 *  cycle, which at 30 Hz is 33 ms.
 *
 *  Caveat worth keeping in mind: the engine's calibrateDelays() uses the same
 *  "within 20 dB of this tap's peak" rule, so this tool and the thing it
 *  measures agree by construction. It shows that the engine did what it set
 *  out to do; it does not independently establish that the rule is right.
 *
 *      c++ -std=c++17 -O2 -I ../Sources/CochleaDSP/include \
 *          leadedge.cpp ../Sources/CochleaDSP/cochlea.cpp -o leadedge
 *      ./leadedge ../Sources/CochleagramApp/Resources/cochlea_88200_erb100.coch 1 0.5
 */
#include "cochlea.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
/* When does each row of the picture first go dark? That is the leading edge,
   and it is what de-skew has to line up. */
int main(int argc, char **argv) {
    const double rate = 44100.0, colMS = atof(argv[3]);
    CochleaEngine *e = cochlea_create(argv[1], rate);
    cochlea_set_column_ms(e, colMS);
    cochlea_set_deskew(e, atoi(argv[2]));
    const int taps = cochlea_tap_count(e);
    const int N = (int)(rate * 1.2);
    std::vector<float> in(N, 0.0f); in[64] = 1.0f;
    std::vector<float> lv(256 * taps), rf(256);
    std::vector<std::vector<float>> hist(taps);
    long long col = 0;
    for (int i = 0; i + 128 <= N; i += 128) {
        cochlea_process(e, in.data() + i, 128);
        int got;
        while ((got = cochlea_pull_columns(e, lv.data(), nullptr, rf.data(), nullptr, nullptr, 256)) > 0) {
            for (int c = 0; c < got; ++c)
                for (int t = 0; t < taps; ++t) hist[t].push_back(lv[c * taps + t]);
            col += got;
            if (got < 256) break;
        }
    }
    const double t0 = 64.0 / rate * 1000.0;
    double lo = 1e9, hi = -1e9;
    for (int t = 0; t < taps; ++t) {
        float mx = -1e30f;
        for (float v : hist[t]) if (v > mx) mx = v;
        for (size_t c = 0; c < hist[t].size(); ++c) {
            if (hist[t][c] >= mx - 20.0f) {          /* within 20 dB of its own peak */
                double when = c * colMS - t0;
                if (when < lo) lo = when;
                if (when > hi) hi = when;
                break;
            }
        }
    }
    printf("%-26s colMS %5.2f  leading edge: earliest %7.2f  latest %7.2f  "
           "OUT OF LINE BY %6.2f ms\n",
           argv[1] + strlen(argv[1]) - 22, colMS, lo, hi, hi - lo);
    return 0;
}
