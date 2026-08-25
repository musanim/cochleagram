// The cochlea engine, as seen from JavaScript.
//
// A thin wrapper over the WebAssembly build of the same cochlea.cpp the Mac
// app uses. Nothing here decides anything: it allocates the buffers the C API
// wants, copies samples in and columns out, and otherwise gets out of the way.
// The engine has no display mode and no opinion about drawing, and neither
// does this.
//
// Runs in a worker. It has no dependency on the DOM.

import createModule from './cochlea.js';

let modulePromise = null;

/// One instance of the WASM module, shared by every engine in this worker.
/// Instantiating it is the expensive part and it holds no per-engine state.
function loadModule() {
    if (!modulePromise) modulePromise = createModule();
    return modulePromise;
}

/// Copy a JS string into WASM memory as a NUL-terminated C string.
/// The caller frees it.
function cString(M, s) {
    const bytes = new TextEncoder().encode(s);
    const p = M._malloc(bytes.length + 1);
    M.HEAPU8.set(bytes, p);
    M.HEAPU8[p + bytes.length] = 0;
    return p;
}

export class Cochlea {

    /// Load a coefficient set and open an engine on it.
    ///
    /// `coeffURL` is fetched and written into the module's in-memory
    /// filesystem, because `cochlea_create` takes a path -- it was written for
    /// a world with files in it, and inventing a second entry point that takes
    /// bytes would be two code paths through the one function that must not
    /// differ between platforms.
    static async create(coeffURL, inputRate) {
        const M = await loadModule();
        const res = await fetch(coeffURL);
        if (!res.ok) throw new Error(`${coeffURL}: ${res.status}`);
        const bytes = new Uint8Array(await res.arrayBuffer());

        // Named for the URL so switching tuning does not overwrite a file an
        // existing engine still has open.
        const path = '/' + coeffURL.split('/').pop();
        try { M.FS.unlink(path); } catch { /* not there yet */ }
        M.FS.writeFile(path, bytes);

        const cpath = cString(M, path);
        const e = M._cochlea_create(cpath, inputRate);
        M._free(cpath);
        if (!e) throw new Error(`could not open ${coeffURL}`);
        return new Cochlea(M, e);
    }

    constructor(M, e) {
        this.M = M;
        this.e = e;
        this.tapCount = M._cochlea_tap_count(e);
        this.internalRate = M._cochlea_internal_rate(e);

        // Best frequency of each tap, high to low. Copied out rather than
        // read in place: the engine owns that array, and a view into WASM
        // memory is invalidated the moment the heap grows.
        this.frequencies = this._copyDoubles(M._cochlea_frequencies(e));
        this.delays = this._copyDoubles(M._cochlea_delays(e));

        // Scratch on the WASM side. Allocated once, because the audio path
        // must not allocate and because these are the only two shapes anything
        // ever asks for.
        this.maxBlock = 8192;
        this.maxCols = 128;
        this.pIn = M._malloc(this.maxBlock * 4);
        this.pLevels = M._malloc(this.maxCols * this.tapCount * 4);
        this.pCoherence = M._malloc(this.maxCols * this.tapCount * 4);
        this.pRefs = M._malloc(this.maxCols * 4);
        // The input's range over each column, for drawing the waveform the
        // picture was made from. Delayed by the engine to match de-skew, so
        // nothing here or above has to correct for it.
        this.pInLo = M._malloc(this.maxCols * 4);
        this.pInHi = M._malloc(this.maxCols * 4);
    }

    _copyDoubles(ptr) {
        const out = new Float64Array(this.tapCount);
        out.set(this.M.HEAPF64.subarray(ptr / 8, ptr / 8 + this.tapCount));
        return out;
    }

    /// Feed mono samples at the rate the engine was opened with.
    process(samples) {
        const M = this.M;
        for (let i = 0; i < samples.length; i += this.maxBlock) {
            const n = Math.min(this.maxBlock, samples.length - i);
            // HEAPF32 is read fresh every time. Growing the heap detaches
            // every existing view, so a cached one is a buffer that silently
            // stops being memory.
            M.HEAPF32.set(samples.subarray(i, i + n), this.pIn / 4);
            M._cochlea_process(this.e, this.pIn, n);
        }
    }

    /// Take whatever finished columns are waiting.
    ///
    /// Returns freshly allocated arrays, so they can be transferred to another
    /// thread without the caller having to think about when the next pull will
    /// overwrite them. `levels` and `coherence` are column-major: all
    /// `tapCount` values of a column are contiguous, tap 0 -- the highest
    /// frequency -- first.
    pullColumns(maxCols = this.maxCols) {
        const M = this.M;
        const want = Math.min(maxCols, this.maxCols);
        const n = M._cochlea_pull_columns(this.e, this.pLevels, this.pCoherence,
                                          this.pRefs, this.pInLo, this.pInHi,
                                          want);
        if (n === 0) return null;
        const k = n * this.tapCount;
        return {
            columns: n,
            taps: this.tapCount,
            levels: M.HEAPF32.slice(this.pLevels / 4, this.pLevels / 4 + k),
            coherence: M.HEAPF32.slice(this.pCoherence / 4, this.pCoherence / 4 + k),
            refs: M.HEAPF32.slice(this.pRefs / 4, this.pRefs / 4 + n),
            inLo: M.HEAPF32.slice(this.pInLo / 4, this.pInLo / 4 + n),
            inHi: M.HEAPF32.slice(this.pInHi / 4, this.pInHi / 4 + n),
        };
    }

    setColumnMs(ms)          { this.M._cochlea_set_column_ms(this.e, ms); }
    setDeskew(on)            { this.M._cochlea_set_deskew(this.e, on ? 1 : 0); }
    setAutoGainHalflife(s)   { this.M._cochlea_set_auto_gain_halflife(this.e, s); }
    get currentRefDb()       { return this.M._cochlea_current_ref_db(this.e); }
    get droppedColumns()     { return this.M._cochlea_dropped_columns(this.e); }
    get peakLevel()          { return this.M._cochlea_peak_level(this.e); }

    destroy() {
        const M = this.M;
        for (const p of [this.pIn, this.pLevels, this.pCoherence, this.pRefs,
                         this.pInLo, this.pInHi]) {
            M._free(p);
        }
        M._cochlea_destroy(this.e);
        this.e = 0;
    }
}
