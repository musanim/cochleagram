# Cochleagram in a browser

The same engine, on a page. `cochlea.cpp` is compiled to WebAssembly through
its existing C interface, so there is one engine rather than two and the
browser version cannot quietly drift away from the thing the Python prototype
checks.

## Why it is worth doing

Anyone can look at a URL. Nobody evaluating an idea installs a signed Mac app
first.

## Whether it is possible

Measured before anything was built, because the answer could have been no. The
cascade is 599 taps at a fixed 88.2 kHz internal rate — 53 million filter
updates a second — and it is serial in both axes, so there is nothing for SIMD
to do.

On an M1 Max, 20 s of broadband noise — the worst case, since every tap fires
on every cycle:

| | one core |
|---|---|
| native | 25.1% |
| **WebAssembly, in the browser** | **28.1%** |
| WebAssembly under node, scalar | 35.1% |
| WebAssembly under node, SIMD | 36.5% |

A 1.12× tax for WebAssembly. The node figures are worse only because Homebrew
here is x86_64 and node was running under Rosetta; the browser runs the module
natively. SIMD measured *slower* than scalar, which is why `build.sh` does not
pass `-msimd128`: a cascade is serial in both axes and there is nothing for
128-bit lanes to do.

All four runs produced the identical digest — `levels -53.548068`,
`coherence 0.001214` — so this is the same engine and not merely a similar
one.

`bench/run.sh` reproduces all three.

## Shape

Audio cannot be processed on the thread that draws, and the cascade is too
expensive to sit in an AudioWorklet, where missing the deadline is a glitch.
So:

```
  AudioWorklet  --postMessage-->  Worker  --postMessage-->  main thread
  (capture only)                (WASM engine)              (canvas)
```

The worklet does nothing but forward blocks. The worker runs the engine and
pulls finished columns. The main thread scrolls a bitmap. Because the worker is
not on the audio clock it is allowed to fall behind under load, which turns a
glitch into a lag.

No `SharedArrayBuffer`, deliberately — it would need COOP/COEP headers and
cross-origin isolation, which a plain static host does not give you. Copying
48000 floats a second between threads is 192 kB/s, which is nothing.

## Building and running

```
brew install emscripten
./build.sh          # writes site/cochlea.js, site/cochlea.wasm, coefficients
./serve.sh          # http://localhost:8000/
```

The server is not optional: ES modules and `.wasm` cannot be loaded from
`file://`.

## Self-test

`site/selftest.html` runs the same benchmark as `bench/`, on the same
deterministic noise, and prints a **digest** — the mean of every level and
every coherence value it produced. It should match the native run to about six
decimal places.

Speed alone would not have caught a port that ran beautifully and computed
something slightly different. The digest is there so the two can be compared
as engines and not merely as workloads.
