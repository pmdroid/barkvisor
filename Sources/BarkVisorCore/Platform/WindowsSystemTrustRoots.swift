#if os(Windows)
    import NIOSSL
    import WinSDK

    enum WindowsSystemTrustRoots {
        static func certificates() -> [NIOSSLCertificate] {
            loadStore("ROOT") + loadStore("CA")
        }

        static func clientTLSConfiguration() -> TLSConfiguration {
            var config = TLSConfiguration.makeClientConfiguration()
            let roots = certificates()
            if !roots.isEmpty {
                config.trustRoots = .certificates(roots)
            }
            return config
        }

        private static func loadStore(_ name: String) -> [NIOSSLCertificate] {
            let store = name.withCString { CertOpenSystemStoreA(0, $0) }
            guard let store else { return [] }
            defer { _ = CertCloseStore(store, 0) }
            var certs: [NIOSSLCertificate] = []
            var context: PCCERT_CONTEXT?
            while true {
                context = CertEnumCertificatesInStore(store, context)
                guard let context else { break }
                let encoded = context.pointee.pbCertEncoded
                let length = Int(context.pointee.cbCertEncoded)
                guard let encoded, length > 0 else { continue }
                let bytes = Array(UnsafeBufferPointer(start: encoded, count: length))
                if let cert = try? NIOSSLCertificate(bytes: bytes, format: .der) {
                    certs.append(cert)
                }
            }
            return certs
        }
    }
#endif
