/*
 *  mear_test.cpp -- check the middle-ear sections in cochlea.cpp against the
 *  Python reference in prototype/midear.py.
 *
 *  Includes the .cpp directly so it can reach the anonymous namespace.
 *
 *      c++ -std=c++17 -O2 -I ../Sources/CochleaDSP/include mear_test.cpp -o mear_test
 *      ./mear_test > cpp.txt
 *
 *  Prints, at 88200 Hz:
 *    line 1  the gain at exactly DC (evaluated as |H| at w = 0)
 *    line 2  the magnitude response at a fixed set of frequencies, in dB
 *    then    the first 64 samples of the impulse response, %.17g one per line
 */
#include "../Sources/CochleaDSP/cochlea.cpp"

#include <cstdio>

int main() {
    const double fs = 88200.0;
    MiddleEar me;
    me.design(fs);

    constexpr double kPi = 3.14159265358979323846;
    std::printf("dc %.17g\n", me.magnitudeAt(0.0));

    const double f[] = {1, 5, 10, 20, 40, 80, 125, 250, 500,
                        1000, 2000, 4000, 8000, 16000};
    std::printf("mag");
    for (double v : f) {
        std::printf(" %.10g", 20.0 * std::log10(me.magnitudeAt(2.0 * kPi * v / fs)));
    }
    std::printf("\n");

    me.reset();
    for (int i = 0; i < 64; ++i) {
        std::printf("%.17g\n", me.process(i == 0 ? 1.0 : 0.0));
    }
    return 0;
}
