import BarkVisor
import BarkVisorCore
import Foundation
import Sentry

/// Pipe for signal→async communication.
/// A raw POSIX signal handler writes here; the async main reads from it.
/// We avoid DispatchSource entirely because Swift 6 strict concurrency
/// checks executor isolation on GCD callbacks, causing dispatch_assert_queue crashes.
nonisolated(unsafe) var signalPipeFDs: [Int32] = [0, 0]
pipe(&signalPipeFDs)

signal(SIGTERM) { _ in
    var b: UInt8 = 1
    Darwin.write(signalPipeFDs[1], &b, 1)
}
signal(SIGINT) { _ in
    var b: UInt8 = 1
    Darwin.write(signalPipeFDs[1], &b, 1)
}

SentrySDK.start { options in
    options.dsn =
        "https://d5e5eb34a4353cb69a861084a2c9e522@o477595.ingest.us.sentry.io/4511188107788288"
    options.debug = true
    options.sendDefaultPii = false
}

let server = VaporServer()

do {
    try await server.start()
} catch {
    Log.server.critical("Server failed to start: \(error)")
    fputs("Server failed to start: \(error)\n", stderr)
    exit(1)
}

/// Block (async-safe) until a signal writes to the pipe
let fh = FileHandle(fileDescriptor: signalPipeFDs[0], closeOnDealloc: false)
_ = try? await fh.bytes.first { _ in true }

Log.server.info("Received signal, shutting down gracefully...")

// Second signal → force exit
signal(SIGTERM) { _ in _exit(1) }
signal(SIGINT) { _ in _exit(1) }

// Graceful shutdown with hard timeout
await withTaskGroup(of: Void.self) { group in
    group.addTask { await server.stop() }
    group.addTask {
        try? await Task.sleep(for: .seconds(10))
        Log.server.error("Graceful shutdown timed out after 10s, forcing exit")
        _exit(1)
    }
    await group.next()
    group.cancelAll()
}

close(signalPipeFDs[0])
close(signalPipeFDs[1])
