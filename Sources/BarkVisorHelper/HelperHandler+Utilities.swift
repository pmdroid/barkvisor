import Foundation
import Security

extension HelperHandler {
    func validateInterface(_ name: String) -> Bool {
        !name.isEmpty
            && name.count <= 15
            && name.allSatisfy { $0.isLetter || $0.isNumber }
    }

    func isSymlink(atPath path: String) -> Bool {
        var stat = stat()
        guard lstat(path, &stat) == 0 else { return false }
        return (stat.st_mode & S_IFMT) == S_IFLNK
    }

    func makeSocketAccessible(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        chmod(path, 0o777)
    }

    func resolveSocketVmnet() -> (path: String?, candidates: [String]) {
        let trustedPath = "/usr/local/libexec/barkvisor/socket_vmnet"
        if FileManager.default.isExecutableFile(atPath: trustedPath) {
            return (trustedPath, [trustedPath])
        }
        let fallbackCandidates = [
            "/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet",
            "/usr/local/opt/socket_vmnet/bin/socket_vmnet",
        ]
        for candidate in fallbackCandidates {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let url = URL(fileURLWithPath: candidate)
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
                  let code
            else { continue }
            if SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess {
                return (candidate, [trustedPath] + fallbackCandidates)
            }
        }
        return (nil, [trustedPath] + fallbackCandidates)
    }

    @discardableResult
    func runProcess(_ path: String, arguments: [String]) -> (Bool, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output =
                String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (proc.terminationStatus == 0, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
