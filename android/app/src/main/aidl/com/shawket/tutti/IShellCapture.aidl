// Runs inside a Shizuku UserService process (uid 2000 shell, or 0 with root Shizuku).
package com.shawket.tutti;

interface IShellCapture {
    // Shizuku calls this transaction code to destroy the service.
    void destroy() = 16777114;

    // Starts REMOTE_SUBMIX capture (whole device output). Returns the read end of a pipe
    // carrying interleaved s16le PCM. Errors come back as an exception message.
    ParcelFileDescriptor start(int sampleRate, int channels) = 1;

    void stop() = 2;

    // "uid=2000 sdk=35 ..." for diagnostics.
    String info() = 3;
}
