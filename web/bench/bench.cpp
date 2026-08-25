#include "cochlea.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <chrono>

int main(int argc, char **argv) {
    const char *path = argv[1];
    double rate = argc > 2 ? atof(argv[2]) : 48000.0;
    double secs = argc > 3 ? atof(argv[3]) : 10.0;

    CochleaEngine *e = cochlea_create(path, rate);
    if (!e) { fprintf(stderr, "could not load %s\n", path); return 1; }
    const int taps = cochlea_tap_count(e);

    // Deterministic broadband input: worst case for a peak detector, since
    // every tap fires constantly.
    const int N = (int)(rate * secs);
    std::vector<float> in(N);
    uint64_t s = 88172645463325252ULL;
    for (int i = 0; i < N; ++i) {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17;
        in[i] = ((float)(int64_t)(s >> 11) / (float)(1LL << 52)) * 0.25f;
    }

    std::vector<float> lv(64 * taps), ch(64 * taps), rf(64);
    const int BLOCK = 128;               // one Web Audio quantum
    auto t0 = std::chrono::steady_clock::now();
    long long pulled = 0;
    // A digest over every column, so a port can be checked for producing the
    // same numbers and not merely for producing them quickly. Deterministic
    // as long as nothing is dropped, which the count below confirms.
    double dl = 0, dc = 0;
    for (int i = 0; i + BLOCK <= N; i += BLOCK) {
        cochlea_process(e, in.data() + i, BLOCK);
        int got = cochlea_pull_columns(e, lv.data(), ch.data(), rf.data(), nullptr, nullptr, 64);
        for (int k = 0; k < got * taps; ++k) { dl += lv[k]; dc += ch[k]; }
        pulled += got;
    }
    auto t1 = std::chrono::steady_clock::now();
    double el = std::chrono::duration<double>(t1 - t0).count();
    printf("%d taps, internal %.0f Hz, input %.0f Hz\n",
           taps, cochlea_internal_rate(e), rate);
    printf("%.1f s of audio in %.3f s  ->  %.1fx realtime, %.1f%% of one core\n",
           secs, el, secs / el, 100.0 * el / secs);
    printf("columns pulled %lld, dropped %llu\n",
           pulled, (unsigned long long)cochlea_dropped_columns(e));
    printf("digest  levels %.6f  coherence %.6f\n",
           dl / (pulled * taps), dc / (pulled * taps));
    cochlea_destroy(e);
    return 0;
}
