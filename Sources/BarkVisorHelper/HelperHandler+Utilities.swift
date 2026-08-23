import BarkVisorHelperProtocol
import Darwin
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
        if isSymlink(atPath: path) { return }

        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { return }
        guard let ids = serviceAccountIDs() else {
            // Fail closed: never leave a bridged socket world-accessible.
            chmod(path, 0o600)
            chown(path, 0, 0)
            NSLog(
                "BarkVisorHelper: service user \(kHelperServiceUser) not found; socket \(path) set 0600 root",
            )
            return
        }

        guard chmod(path, mode_t(kHelperBridgeSocketMode)) == 0 else {
            NSLog("BarkVisorHelper: chmod 0660 failed for \(path): \(String(cString: strerror(errno)))")
            return
        }
        guard chown(path, ids.uid, ids.gid) == 0 else {
            NSLog("BarkVisorHelper: chown \(kHelperServiceUser) failed for \(path): \(String(cString: strerror(errno)))")
            return
        }
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
            guard hasTrustedSocketVmnetSignature(at: resolved) else { continue }
            return (resolved, candidates)
        }
        return (nil, candidates)
    }

    func isGroupOrWorldWritable(atPath path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return true }
        if (st.st_mode & S_IFMT) == S_IFLNK { return true }
        return (st.st_mode & 0o022) != 0
    }

    func hasTrustedSocketVmnetSignature(at path: String) -> Bool {
        if isSymlink(atPath: path) { return false }
        let url = URL(fileURLWithPath: path)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code
        else { return false }

        let teamReq = helperCodeRequirement(
            identifier: kHelperSocketVmnetIdentifier,
            teamID: kHelperTeamID,
        )
        if checkValidity(code, requirement: teamReq) { return true }
        // Homebrew socket_vmnet is not BarkVisor-team-signed (PAS-287).
        return checkValidity(code, requirement: "identifier \"\(kHelperSocketVmnetIdentifier)\"")
    }

    private func checkValidity(_ code: SecStaticCode, requirement reqString: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(reqString as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private func serviceAccountIDs() -> (uid: uid_t, gid: gid_t)? {
        guard let pw = getpwnam(kHelperServiceUser) else { return nil }
        return (pw.pointee.pw_uid, pw.pointee.pw_gid)
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
