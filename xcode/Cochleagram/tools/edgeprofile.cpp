/*
 *  edgeprofile -- where does the leading edge of a click land, per tap?
 *
 *  The same question a screenshot answers, asked of the engine directly. No
 *  app, no window, no reading pixels off an image: it plays the reference
 *  impulse through the cascade exactly as the display would, and reports the
 *  first column in which each tap goes visible.
 *
 *  With De-skew on that edge should be vertical, so the interesting numbers
 *  are the spread and the biggest step between neighbouring taps.
 *
 *      c++ -std=c++17 -O2 -I ../Sources/CochleaDSP/include \
 *          edgeprofile.cpp ../Sources/CochleaDSP/cochlea.cpp -o /tmp/edgeprofile
 *      /tmp/edgeprofile ../Sources/CochleagramApp/Resources/cochlea_88200_erb050.coch \
 *                       ../../../reference/pureimpulse.wav
 *
 *  Third argument is the visible floor in dBFS, default -180 -- the white
 *  point of the default exposure, and the level the de-skew calibration is
 *  measured at. Those two have to agree: on hardware whose cascade computes a
 *  precursor, looking for the edge at a level nothing is calibrated for is
 *  worth 94 ms of apparent error all by itself.
 */
#include "cochlea.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

/*  Minimal 16-bit PCM WAV reader -- enough for the reference signals, and
 *  deliberately not more, so this tool has no dependencies to install. */
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
            uint16_t fmt = 0, ch = 0, bps = 0; uint32_t sr = 0, br = 0;
            uint16_t align = 0;
            std::fread(&fmt, 2, 1, f); std::fread(&ch, 2, 1, f);
            std::fread(&sr, 4, 1, f);  std::fread(&br, 4, 1, f);
            std::fread(&align, 2, 1, f); std::fread(&bps, 2, 1, f);
            channels = ch; bits = bps; rate = sr;
            std::fseek(f, (long)sz - 16, SEEK_CUR);
        } else if (!std::memcmp(cid, "data", 4)) {
            const size_t frames = sz / (size_t)(channels * bits / 8);
            out.resize(frames);
            for (size_t i = 0; i < frames; ++i) {
                double acc = 0.0;
                for (int c = 0; c < channels; ++c) {
                    int16_t s = 0; std::fread(&s, 2, 1, f);
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
        std::fprintf(stderr, "usage: %s coeffs.coch impulse.wav [floor_dB]\n",
                     argv[0]);
        return 2;
    }
    /*  -180, matching both the calibration threshold and the white
     point of the default exposure. It was -250, which is a level
     nothing is calibrated for and nothing is normally drawn at,
     and on hardware that computes a precursor that mismatch alone
     is worth 94 ms of apparent error. */
    const double floorDB = argc > 3 ? std::atof(argv[3]) : -180.0;
    const double colMS = 0.5;

    std::vector<float> in; double rate = 44100.0;
    if (!readWav(argv[2], in, rate)) {
        std::fprintf(stderr, "could not read %s as 16-bit PCM\n", argv[2]);
        return 1;
    }
    CochleaEngine *e = cochlea_create(argv[1], rate);
    if (!e) { std::fprintf(stderr, "could not load %s\n", argv[1]); return 1; }
    cochlea_set_column_ms(e, colMS);
    cochlea_set_deskew(e, 1);

    const int taps = cochlea_tap_count(e);
    const double *bf = cochlea_frequencies(e);
    std::vector<double> first(taps, -1.0);
    std::vector<float> pull((size_t)taps * 512);
    long col = 0;

    for (size_t i = 0; i < in.size(); i += 128) {
        const int n = (int)std::min<size_t>(128, in.size() - i);
        cochlea_process(e, in.data() + i, n);
        int got;
        while ((got = cochlea_pull_columns(e, pull.data(), nullptr, nullptr,
                                           512)) > 0) {
            for (int c = 0; c < got; ++c, ++col) {
                for (int t = 0; t < taps; ++t) {
                    if (first[t] < 0.0 &&
                        pull[(size_t)c * taps + t] >= floorDB) {
                        first[t] = col * colMS;
                    }
                }
            }
            if (got < 512) break;
        }
    }

    std::printf("%s\n", argv[1]);
    std::printf("floor %.0f dBFS, %.1f ms/column, de-skew on, %ld columns\n\n",
                floorDB, colMS, col);
    std::printf("%10s %12s\n", "freq_Hz", "edge_ms");
    for (int t = 0; t < taps; t += 40) {
        std::printf("%10.0f %12.1f\n", bf[t], first[t]);
    }
    std::printf("%10.0f %12.1f\n", bf[taps - 1], first[taps - 1]);

    double lo = 1e30, hi = -1e30;
    int seen = 0;
    for (int t = 0; t < taps; ++t) {
        if (first[t] < 0.0) continue;
        ++seen;
        lo = std::min(lo, first[t]);
        hi = std::max(hi, first[t]);
    }
    std::printf("\nspread %.1f ms over %d visible taps\n", hi - lo, seen);

    /*  The three biggest breaks between neighbouring taps. A vertical edge has
     *  none; a slipped band shows one at each of its boundaries. */
    struct Step { double d, hz; };
    std::vector<Step> steps;
    for (int t = 1; t < taps; ++t) {
        if (first[t] < 0.0 || first[t - 1] < 0.0) continue;
        steps.push_back({first[t] - first[t - 1], bf[t]});
    }
    std::sort(steps.begin(), steps.end(),
              [](const Step &a, const Step &b) {
                  return std::fabs(a.d) > std::fabs(b.d);
              });
    std::printf("biggest steps:");
    for (size_t i = 0; i < steps.size() && i < 3; ++i) {
        std::printf("  %+.1f ms at %.1f Hz", steps[i].d, steps[i].hz);
    }
    std::printf("\n");
    cochlea_destroy(e);
    return 0;
}
