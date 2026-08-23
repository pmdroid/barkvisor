import ArgumentParser
import BarkVisor
import BarkVisorCore
import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Logging
import SwiftSentry

/// Pipe for signal→async communication.
/// A raw POSIX signal handler writes here; the async main reads from it.
/// We avoid DispatchSource entirely because Swift 6 strict concurrency
/// checks executor isolation on GCD callbacks, causing dispatch_assert_queue crashes.
nonisolated(unsafe) var signalPipeFDs: [Int32] = [0, 0]

@main
struct BarkVisorCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "barkvisor",
        abstract: "BarkVisor Device daemon",
        subcommands: [Serve.self, Join.self],
        defaultSubcommand: Serve.self,
    )
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the BarkVisor Device daemon (default).",
    )

    func run() async throws {
        await runDaemon()
    }
}

/// Console-local Home join (PAS-180). Posts the pairing offer to this
/// Device's host API — not through Home.
struct Join: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Join a Home from this Device.",
        discussion: """
        1. On the other Device, Settings → Home → Add a Device, pick the \
        address this Device can reach, and copy the full barkvisor:// offer.
        2. Run this command with that offer (not the short printed code).
        3. This posts to http://127.0.0.1:7777/api/pairing/join on this Device.
        """,
    )

    @Option(
        name: .long,
        help: "Full barkvisor://pair/v1?… offer from the other Device (not the short code).",
    )
    var code: String

    func run() async throws {
        let result = try await LocalPairingJoin.post(
            offer: code,
            client: URLSessionPairingHTTPClient(),
        )
        FileHandle.standardOutput.write(
            Data("Joined Home. Peer Device \(result.peerHostId)\n".utf8),
        )
    }
}

func configureLogging() {
    let sentry = try? Sentry(
        dsn: "https://fd23965cd2644e52116484d7029e900d@o477595.ingest.us.sentry.io/4511210185162752",
    )
    LoggingSystem.bootstrap { [sentry] label in
        var handler = StreamLogHandler.standardOutput(label: label)
        handler.logLevel = .debug
        if let sentry {
            return MultiplexLogHandler([
                SentryLogHandler(label: label, sentry: sentry, level: .error),
                handler,
            ])
        }
        return handler
    }
    if let sentry {
        LogService.configureSentry(sentry: sentry)
    }
}

func runDaemon() async {
    configureLogging()

    let sockets = Config.socketDir
    if PlatformPaths.socketDirIsPackagingOwned(sockets),
       !PlatformPaths.isWritableDirectory(sockets) {
        let message = """
        Socket directory \(sockets.path) is missing or not writable. \
        Packaging must create this directory (Homebrew postinstall, pkg, or systemd); \
        the Device daemon cannot mkdir /var/run or /run. \
        Homebrew: sudo "$(brew --prefix barkvisor)/share/barkvisor/postinstall" \
        && sudo brew services restart barkvisor
        """
        Log.server.critical("\(message)")
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }

    pipe(&signalPipeFDs)
    signal(SIGTERM) { _ in
        var b: UInt8 = 1
        write(signalPipeFDs[1], &b, 1)
    }
    signal(SIGINT) { _ in
        var b: UInt8 = 1
        write(signalPipeFDs[1], &b, 1)
    }

    var serverLogger = Logger(label: "barkvisor.server")
    serverLogger[metadataKey: "version"] = Logger.MetadataValue(stringLiteral: Config.version)

    let server = VaporServer()

    do {
        try await server.start()
    } catch {
        Log.server.critical("Server failed to start: \(error)")
        FileHandle.standardError.write(Data("Server failed to start: \(error)\n".utf8))
        exit(1)
    }

    // Block (async-safe) until a signal writes to the pipe (POSIX read; portable).
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            var b: UInt8 = 0
            _ = read(signalPipeFDs[0], &b, 1)
            cont.resume()
        }
    }
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
}
