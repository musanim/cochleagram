/*
 *  peakdump -- the first few peaks of a tap's impulse response, and which one
 *              the de-skew calibration chose.
 *
 *  `calibrateDelays` picks the first peak above a threshold. When that goes
 *  wrong the picture leans or steps, and the only way to see *why* is to look
 *  at the candidates it was choosing between. This prints them.
 *
 *  No engine internals are needed. The sample-and-hold level only ever moves
 *  at a peak, so asking the engine for one column per internal sample turns
 *  the column stream into a list of peaks with their times and levels -- and
 *  it arrives through `cochlea_process`, which is the same front end the
 *  calibration and the display both use.
 *
 *      c++ -std=c++17 -O2 -I ../Sources/CochleaDSP/include \
 *          peakdump.cpp ../Sources/CochleaDSP/cochlea.cpp -o /tmp/peakdump
 *      /tmp/peakdump coeffs.coch ../../../reference/pureimpulse.wav
 *
 *  Times are measured from the impulse in the file, so they are directly
 *  comparable with the delays `caldump` reports. A third argument overrides
 *  the frequencies examined, as a comma-separated list.
 */
#include "cochlea.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static bool readWav(const char *path, std::vector<float> &out, double &rate) {
    FILE *f = std::fopen(path, "rb");
    if (!f) return false;
    char id[4];
    if (std::fread(id, 1, 4, f) != 4 || std::memcmp(id, "RIFF", 4)) {
        std::fclose(f); return false;
    }
    std::fseek(f, 8, SEEK_SET);
    if (std::fread(id, 1, 4, f) != 4 || std::memcmp(id, "WAVE", 4)) {
        std::fclose(f); return false;
    }
    int channels = 1, bits = 16;
    while (true) {
        char cid[4]; uint32_t sz = 0;
        if (std::fread(cid, 1, 4, f) != 4) break;
        if (std::fread(&sz, 4, 1, f) != 1) break;
        if (!std::memcmp(cid, "fmt ", 4)) {
            uint16_t fmt = 0, ch = 0, bps = 0, align = 0; uint32_t sr = 0, br = 0;
            if (std::fread(&fmt, 2, 1, f) != 1) break;
            if (std::fread(&ch, 2, 1, f) != 1) break;
            if (std::fread(&sr, 4, 1, f) != 1) break;
            if (std::fread(&br, 4, 1, f) != 1) break;
            if (std::fread(&align, 2, 1, f) != 1) break;
            if (std::fread(&bps, 2, 1, f) != 1) break;
            channels = ch; bits = bps; rate = sr;
            std::fseek(f, (long)sz - 16, SEEK_CUR);
        } else if (!std::memcmp(cid, "data", 4)) {
            const size_t frames = sz / (size_t)(channels * bits / 8);
            out.resize(frames);
            for (size_t i = 0; i < frames; ++i) {
                double acc = 0.0;
                for (int c = 0; c < channels; ++c) {
                    int16_t s = 0;
                    if (std::fread(&s, 2, 1, f) != 1) { out.clear(); break; }
                    acc += s / 32768.0;
                }
                out[i] = (float)(acc / channels);
            }
            std::fclose(f);
            return bits == 16 && !out.empty();
        } else {
            std::fseek(f, (long)sz + (sz & 1), SEEK_CUR);
        }
    }
    std::fclose(f);
    return false;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        std::fprintf(stderr,
                     "usage: %s coeffs.coch impulse.wav [freq,freq,...]\n",
                     argv[0]);
        return 2;
    }
    /*  Around the band that misbehaves at ERB 0.5 on arm64, with two controls
     *  well above it. */
    std::vector<double> want = {300, 100, 45, 40, 36, 33, 30, 27, 25, 22};
    if (argc > 3) {
        want.clear();
        const char *p = argv[3];
        while (*p) { want.push_back(std::atof(p));
                     while (*p && *p != ',') ++p;
                     if (*p == ',') ++p; }
    }

    std::vector<float> in; double rate = 44100.0;
    if (!readWav(argv[2], in, rate)) {
        std::fprintf(stderr, "could not read %s as 16-bit PCM\n", argv[2]);
        return 1;
    }
    size_t impulse = 0;
    while (impulse < in.size() && in[impulse] == 0.0f) ++impulse;

    CochleaEngine *e = cochlea_create(argv[1], rate);
    if (!e) { std::fprintf(stderr, "could not load %s\n", argv[1]); return 1; }
    const int taps = cochlea_tap_count(e);
    const double *bf = cochlea_frequencies(e);
    const double *gd = cochlea_delays(e);
    /* reassigned when the engine is rebuilt for the whole-tap dump */
    const double ifs = cochlea_internal_rate(e);

    /*  One column per internal sample. `held` only moves at a peak, so the
     *  column stream is now the peak list. De-skew off: this is about when
     *  each tap responds, not about where it is drawn. */
    cochlea_set_column_ms(e, 1000.0 / ifs);
    cochlea_set_deskew(e, 0);

    std::vector<int> which;
    std::vector<double> chosen;
    for (double hz : want) {
        int best = 0;
        for (int t = 1; t < taps; ++t)
            if (std::fabs(bf[t] - hz) < std::fabs(bf[best] - hz)) best = t;
        which.push_back(best);
        chosen.push_back(gd[best] * 1000.0);
    }

    constexpr int kKeep = 6;
    /*  Levels are in dB and start far below zero, so the high-water mark has
     *  to start lower still. Zero is not "nothing yet" here. */
    /* -599, not -1e30: an untouched tap reads -600 dB, and the step up
       out of silence is not a peak. */
    std::vector<double> seen(which.size(), -599.0);
    std::vector<std::vector<std::pair<double,double>>> peaks(which.size());

    std::vector<float> pull((size_t)taps * 256);
    long col = 0;
    const double t0 = (double)impulse / rate * 1000.0;
    for (size_t i = 0; i < in.size(); i += 64) {
        const int n = (int)std::min<size_t>(64, in.size() - i);
        cochlea_process(e, in.data() + i, n);
        int got;
        while ((got = cochlea_pull_columns(e, pull.data(), nullptr, nullptr,
                                           256)) > 0) {
            for (int c = 0; c < got; ++c, ++col) {
                const double ms = col * 1000.0 / ifs - t0;
                for (size_t k = 0; k < which.size(); ++k) {
                    if ((int)peaks[k].size() >= kKeep) continue;
                    const double v = pull[(size_t)c * taps + which[k]];
                    if (v > seen[k] + 0.01) {          /* dB; held has risen */
                        seen[k] = v;
                        if (ms >= 0.0) peaks[k].push_back({ms, v});
                    }
                }
            }
            if (got < 256) break;
        }
    }

    /*  With a fourth argument, every tap rather than a chosen few, written to
     *  a file. That is how these get compared between machines: the numbers go
     *  into the project folder and can be plotted or diffed, instead of being
     *  read off a screenshot of someone else's window. */
    if (argc > 4) {
        FILE *out = std::fopen(argv[4], "w");
        if (!out) { std::fprintf(stderr, "cannot write %s\n", argv[4]); return 1; }
        std::fprintf(out, "# tap freq_Hz chose_ms then peak_ms peak_dB pairs\n");
        std::vector<double> seenAll(taps, -599.0);
        std::vector<std::vector<std::pair<double,double>>> allPeaks(taps);
        cochlea_destroy(e);
        e = cochlea_create(argv[1], rate);
        cochlea_set_column_ms(e, 1000.0 / ifs);
        cochlea_set_deskew(e, 0);
        bf = cochlea_frequencies(e);
        gd = cochlea_delays(e);
        long c2 = 0;
        for (size_t i = 0; i < in.size(); i += 64) {
            const int n = (int)std::min<size_t>(64, in.size() - i);
            cochlea_process(e, in.data() + i, n);
            int got;
            while ((got = cochlea_pull_columns(e, pull.data(), nullptr,
                                               nullptr, 256)) > 0) {
                for (int c = 0; c < got; ++c, ++c2) {
                    const double ms = c2 * 1000.0 / ifs - t0;
                    if (ms < 0.0) continue;
                    for (int t = 0; t < taps; ++t) {
                        if ((int)allPeaks[t].size() >= 4) continue;
                        const double v = pull[(size_t)c * taps + t];
                        if (v > seenAll[t] + 0.01) {
                            seenAll[t] = v;
                            allPeaks[t].push_back({ms, v});
                        }
                    }
                }
                if (got < 256) break;
            }
        }
        for (int t = 0; t < taps; ++t) {
            std::fprintf(out, "%d %.3f %.4f", t, bf[t], gd[t] * 1000.0);
            for (auto &p : allPeaks[t])
                std::fprintf(out, " %.4f %.2f", p.first, p.second);
            std::fprintf(out, "\n");
        }
        std::fclose(out);
        std::printf("wrote %s (%d taps)\n", argv[4], taps);
        cochlea_destroy(e);
        return 0;
    }

    std::printf("%s\n", argv[1]);
    std::printf("peaks of each tap's response, ms after the impulse, with the "
                "level the\nsample-and-hold reached. `chose` is the delay the "
                "calibration settled on.\n\n");
    for (size_t k = 0; k < which.size(); ++k) {
        std::printf("%8.1f Hz   chose %8.3f ms\n", bf[which[k]], chosen[k]);
        /*  Whichever peak the calibration landed nearest. The two measurements
         *  start counting from slightly different places -- the calibration
         *  from its own impulse, this from the one in the file -- so an exact
         *  match is not the test; being a whole period out is. */
        size_t nearest = 0;
        for (size_t j = 1; j < peaks[k].size(); ++j) {
            if (std::fabs(peaks[k][j].first - chosen[k])
                < std::fabs(peaks[k][nearest].first - chosen[k])) nearest = j;
        }
        for (size_t j = 0; j < peaks[k].size(); ++j) {
            std::printf("      peak %zu %10.3f ms %9.1f dB%s\n", j + 1,
                        peaks[k][j].first, peaks[k][j].second,
                        (j == nearest && !peaks[k].empty()) ? "   <-- chosen"
                                                            : "");
        }
        std::printf("\n");
    }
    cochlea_destroy(e);
    return 0;
}
