import Foundation
#if canImport(WinSDK)
    import WinSDK
#endif

public enum PrivateFileAccess {
    public static func windowsProtectedDACLSDDL(userSID: String) -> String {
        let sid = userSID.trimmingCharacters(in: .whitespacesAndNewlines)
        if sid.isEmpty || sid == "S-1-5-18" || sid.caseInsensitiveCompare("SY") == .orderedSame {
            return "D:P(A;;FA;;;SY)"
        }
        return "D:P(A;;FA;;;SY)(A;;FA;;;\(sid))"
    }

    public static func restrict(path: String) throws {
        #if os(Windows)
            try applyWindowsDACL(path: path)
        #else
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path,
            )
        #endif
    }

    #if os(Windows)
        private static func applyWindowsDACL(path: String) throws {
            let sid = currentUserSID() ?? "SY"
            let sddl = windowsProtectedDACLSDDL(userSID: sid)
            var descriptor: PSECURITY_DESCRIPTOR?
            let converted = sddl.withCString(encodedAs: UTF16.self) { wide in
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    wide,
                    DWORD(1),
                    &descriptor,
                    nil,
                )
            }
            guard converted, let descriptor else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { _ = LocalFree(descriptor) }
            let applied = path.withCString(encodedAs: UTF16.self) { wide in
                SetFileSecurityW(
                    UnsafeMutablePointer(mutating: wide),
                    SECURITY_INFORMATION(DACL_SECURITY_INFORMATION),
                    descriptor,
                )
            }
            guard applied else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        private static func currentUserSID() -> String? {
            var token: HANDLE?
            guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token),
                  let token
            else {
                return nil
            }
            defer { CloseHandle(token) }
            var needed: DWORD = 0
            GetTokenInformation(token, TokenUser, nil, 0, &needed)
            guard needed > 0 else { return nil }
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(needed), alignment: 8)
            defer { buffer.deallocate() }
            guard GetTokenInformation(token, TokenUser, buffer, needed, &needed) else {
                return nil
            }
            let user = buffer.assumingMemoryBound(to: TOKEN_USER.self)
            var sidString: LPWSTR?
            guard ConvertSidToStringSidW(user.pointee.User.Sid, &sidString),
                  let sidString
            else {
                return nil
            }
            defer { _ = LocalFree(sidString) }
            return String(decodingCString: sidString, as: UTF16.self)
        }
    #endif
}
