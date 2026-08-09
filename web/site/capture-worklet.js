// Capture, and nothing else.
//
// This runs on the audio thread, where missing a deadline is a glitch rather
// than a delay. So it does the least possible: copies the block and posts it
// on. The cascade -- 53 million filter updates a second -- runs in a worker
// that is allowed to fall behind.
//
// The copy is not avoidable: the buffer handed to `process` is reused by the
// browser the moment it returns, so anything kept must be kept elsewhere.
// Transferring the copy hands the memory over rather than cloning it again.

class Capture extends AudioWorkletProcessor {
    process(inputs) {
        const input = inputs[0];
        if (input && input.length) {
            // Mono. A stereo microphone would have two channels of nearly the
            // same thing, and the engine takes one signal.
            const block = input[0].slice();
            this.port.postMessage(block, [block.buffer]);
        }
        return true;               // keep running even during silence
    }
}

registerProcessor('capture', Capture);
