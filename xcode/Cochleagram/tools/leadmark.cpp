/*
 *  leadmark.cpp -- how far is the impulse's leading edge from the green
 *                  end-of-file mark?
 *
 *  This is the ground truth the two apps are measured against, and it is the
 *  harness the 2026-08-14 handoff called /tmp/lead.cpp -- which lived in a
 *  sandbox and did not survive it. It lives in the repo now.
 *
 *  What it reproduces, and why it is not simply "when does the click appear":
 *  the mark is placed on the *newest column at the moment the file's last
 *  sample has been fed*, exactly as both apps place it. De-skew delays the
 *  picture but not the arrival of the last sample, so the two are shifted by
 *  different amounts and the offset does not cancel. Feeding the file and then
 *  asking where the mark landed is the only way to get that right.
 *
 *  Input is raw mono float32 at `rate` -- the same convention selftest.cpp
 *  uses. Convert with:
 *      python3 -c "import sys,wave,array;w=wave.open(sys.argv[1]);\
 *      a=array.array('h');a.frombytes(w.readframes(w.getnframes()));\
 *      import struct;open(sys.argv[2],'wb').write(\
 *      b''.join(struct.pack('<f',v/32768) for v in a))" in.wav out.f32
 *
 *      c++ -std=c++17 -O2 -I ../Sources/CochleaDSP/include \
 *          leadmark.cpp ../Sources/CochleaDSP/cochlea.cpp -o leadmark
 *      ./leadmark coeffs.coch input.f32 44100 0.5 1
 */
#include "cochlea.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <cmath>

int main(int argc, char **argv) {
    if (argc < 6) {
        fprintf(stderr,
                "usage: %s coeffs.coch input.f32 rate column_ms deskew\n",
                argv[0]);
        return 1;
    }
    const char *coeffs = argv[1];
    const char *path   = argv[2];
    const double rate   = atof(argv[3]);
    const double colMS  = atof(argv[4]);
    const int    deskew = atoi(argv[5]);
    /* Samples per process() call. Not a detail: the Mac app's tap delivers
       4410 frames at a time where this harness defaulted to 128, and that is
       exactly the sort of difference an engine is entitled to be indifferent
       to and has to be checked rather than assumed. */
    const int    block  = argc > 6 ? atoi(argv[6]) : 128;

    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 1; }
    std::vector<float> in;
    float s;
    while (fread(&s, sizeof(float), 1, f) == 1) in.push_back(s);
    fclose(f);
    if (in.empty()) { fprintf(stderr, "%s is empty\n", path); return 1; }

    CochleaEngine *e = cochlea_create(coeffs, rate);
    if (!e) { fprintf(stderr, "cannot load %s\n", coeffs); return 1; }
    cochlea_set_column_ms(e, colMS);
    cochlea_set_deskew(e, deskew);
    const int taps = cochlea_tap_count(e);

    /* levels[tap][column], grown as the file is fed. */
    std::vector<std::vector<float>> hist(taps);
    std::vector<float> lv(256 * taps);
    long long cols = 0;

    /* 128 samples at a time, draining after each block: the same shape as the
       audio thread feeding and the display thread pulling. */
    const int BLOCK = block;
    for (size_t i = 0; i < in.size(); i += BLOCK) {
        int n = (int)std::min((size_t)BLOCK, in.size() - i);
        cochlea_process(e, in.data() + i, n);
        int got;
        while ((got = cochlea_pull_columns(e, lv.data(), nullptr, nullptr, nullptr, nullptr, 256)) > 0) {
            for (int c = 0; c < got; ++c)
                for (int t = 0; t < taps; ++t)
                    hist[t].push_back(lv[c * taps + t]);
            cols += got;
            if (got < 256) break;
        }
    }
    /* The mark: the newest column once the last sample has been fed and
       everything ready has been drained. Columns are zero-based, so the
       newest one is cols - 1. */
    const long long markCol = cols - 1;

    /* The leading edge, by three definitions, so the number quoted is never
       ambiguous about which one it is:
         within20  first column within 20 dB of that tap's own peak
                   (the rule calibrateDelays() uses -- what the eye follows)
         within60  the same at 60 dB, a fainter edge the display can still show
         earliest  the earliest such column over all taps; for a de-skewed
                   click every tap should agree, and the spread says whether
                   it does. */
    auto edgeAt = [&](double downDB) {
        long long earliest = -1, latest = -1;
        for (int t = 0; t < taps; ++t) {
            float mx = -1e30f;
            for (float v : hist[t]) if (v > mx) mx = v;
            for (size_t c = 0; c < hist[t].size(); ++c) {
                if (hist[t][c] >= mx - (float)downDB) {
                    if (earliest < 0 || (long long)c < earliest) earliest = c;
                    if ((long long)c > latest) latest = c;
                    break;
                }
            }
        }
        return std::make_pair(earliest, latest);
    };

    printf("file        %zu samples, %.2f ms at %.0f Hz\n",
           in.size(), in.size() / rate * 1000.0, rate);
    printf("columns     %lld produced, %.1f ms each, de-skew %s\n",
           cols, colMS, deskew ? "on" : "off");
    printf("mark        column %lld  (= %.2f ms from the first column)\n",
           markCol, markCol * colMS);
    for (double d : {20.0, 60.0}) {
        auto [first, last] = edgeAt(d);
        printf("edge -%.0f dB  earliest column %lld, latest %lld  "
               "(spread %.2f ms)\n", d, first, last, (last - first) * colMS);
        printf("            mark - edge = %.2f ms (earliest) / %.2f ms (latest)\n",
               (markCol - first) * colMS, (markCol - last) * colMS);
    }
    cochlea_destroy(e);
    return 0;
}
