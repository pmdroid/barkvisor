import BarkVisorHelperProtocol
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

    /// Homebrew opt-prefix first (PAS-287). Leftover libexec last.
    static let socketVmnetSearchPaths = SocketVmnetLayout.searchPaths

    func resolveSocketVmnet() -> (path: String?, candidates: [String]) {
        let candidates = Self.socketVmnetSearchPaths
        for candidate in candidates {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let resolved = (candidate as NSString).resolvingSymlinksInPath
            guard SocketVmnetLayout.allowedPrefix(resolved),
                  !isGroupOrWorldWritable(atPath: resolved)
            else { continue }
            let url = URL(fileURLWithPath: resolved)
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
                  let code
            else { continue }
            let reqString = "identifier \"socket_vmnet\""
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(reqString as CFString, [], &requirement)
                == errSecSuccess,
                let requirement
            else { continue }
            if SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess {
                return (resolved, candidates)
            }
        }
        return (nil, candidates)
    }

    func isGroupOrWorldWritable(atPath path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return true }
        if (st.st_mode & S_IFMT) == S_IFLNK { return true }
        return (st.st_mode & 0o022) != 0
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
