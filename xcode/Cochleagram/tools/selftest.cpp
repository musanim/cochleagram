/*  selftest -- run the real-time core off-line and write a PGM.
 *
 *  The C++ core is plain portable C++, so it can be built and checked on any
 *  machine, not just the one with Xcode on it.  This harness feeds it the same
 *  audio the Python prototype uses and writes the display bitmap out, so the
 *  two can be compared pixel for pixel.
 *
 *    c++ -std=c++17 -O2 -I ../Sources/CochleaDSP/include \
 *        selftest.cpp ../Sources/CochleaDSP/cochlea.cpp -o selftest
 *    ./selftest coeffs.coch input.f32 44100 out.pgm
 *
 *  `input.f32` is raw little-endian float32 mono.
 */

#include "cochlea.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

int main(int argc, char **argv) {
    if (argc < 5) {
        std::fprintf(stderr,
                     "usage: %s coeffs.coch input.f32 input_rate out.pgm "
                     "[column_ms] [floor_db] [deskew 0|1] "
                     "[ref_db] [auto_gain 0|1]\n", argv[0]);
        return 2;
    }
    const char *coeffs = argv[1];
    const char *inpath = argv[2];
    const double rate = std::atof(argv[3]);
    const char *outpath = argv[4];
    const double column_ms = argc > 5 ? std::atof(argv[5]) : 4.0;
    double floor_db = argc > 6 ? std::atof(argv[6]) : -35.0;
    if (floor_db >= 0.0) floor_db = -35.0;   /* it divides by this */
    const int deskew = argc > 7 ? std::atoi(argv[7]) : 1;

    CochleaEngine *e = cochlea_create(coeffs, rate);
    if (!e) { std::fprintf(stderr, "could not load %s\n", coeffs); return 1; }

    const double ref_db = argc > 8 ? std::atof(argv[8]) : 0.0;
    cochlea_set_column_ms(e, column_ms);
    cochlea_set_deskew(e, deskew);

    const int taps = cochlea_tap_count(e);
    const double *bf = cochlea_frequencies(e);
    std::fprintf(stderr, "%d taps, %.1f - %.0f Hz, internal rate %.0f\n",
                 taps, bf[taps - 1], bf[0], cochlea_internal_rate(e));

    FILE *f = std::fopen(inpath, "rb");
    if (!f) { std::fprintf(stderr, "no such file %s\n", inpath); return 1; }
    std::fseek(f, 0, SEEK_END);
    const long bytes = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    std::vector<float> in(static_cast<size_t>(bytes) / sizeof(float));
    if (std::fread(in.data(), sizeof(float), in.size(), f) != in.size()) {
        std::fprintf(stderr, "short read\n"); return 1;
    }
    std::fclose(f);

    /* Feed it in realistic audio-callback sized chunks, and drain as we go,
     * exercising the same producer/consumer path the app uses.
     *
     * The engine emits levels in dB, not pixels -- turning level into grey is
     * the display's job now, so this harness has to do it too.  That is the
     * point of the split: the mapping needs a reference and a floor that the
     * user can change at any moment, and only something holding the levels
     * can honour a change on what is already drawn. */
    std::vector<float> cols;
    std::vector<float> col_refs;
    std::vector<float> pull(static_cast<size_t>(taps) * 512);
    std::vector<float> pull_refs(512);
    const int block = 512;
    for (size_t i = 0; i < in.size(); i += block) {
        const int n = static_cast<int>(std::min<size_t>(block, in.size() - i));
        cochlea_process(e, in.data() + i, n);
        int got;
        while ((got = cochlea_pull_columns(e, pull.data(), nullptr, pull_refs.data(),
                                           512)) > 0) {
            cols.insert(cols.end(), pull.begin(),
                        pull.begin() + static_cast<size_t>(got) * taps);
            col_refs.insert(col_refs.end(), pull_refs.begin(),
                            pull_refs.begin() + got);
            if (got < 512) break;
        }
    }
    const int n_cols = static_cast<int>(cols.size() / taps);
    std::fprintf(stderr, "%d columns, %llu dropped\n", n_cols,
                 (unsigned long long)cochlea_dropped_columns(e));

    /* PGM is row-major; our columns are tap-major, so transpose -- and map
     * dB to grey on the way, with the same arithmetic the view uses.  A fixed
     * reference here: `auto` follows the engine's tracked one instead. */
    FILE *o = std::fopen(outpath, "wb");
    std::fprintf(o, "P5\n%d %d\n255\n", n_cols, taps);
    const bool use_auto = (argc > 9) ? std::atoi(argv[9]) != 0 : false;
    std::vector<uint8_t> row(n_cols);
    for (int t = 0; t < taps; ++t) {
        for (int c = 0; c < n_cols; ++c) {
            const double ref = use_auto ? col_refs[c] : ref_db;
            double u = (cols[(size_t)c * taps + t] - ref - floor_db)
                     / (-floor_db);
            u = u < 0.0 ? 0.0 : (u > 1.0 ? 1.0 : u);
            row[c] = static_cast<uint8_t>(std::lround((1.0 - u) * 255.0));
        }
        std::fwrite(row.data(), 1, n_cols, o);
    }
    std::fclose(o);
    cochlea_destroy(e);
    std::fprintf(stderr, "wrote %s (%d x %d)\n", outpath, n_cols, taps);
    return 0;
}
