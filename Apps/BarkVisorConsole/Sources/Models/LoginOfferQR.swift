import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Host stamped on POST /api/auth/login-offers.
/// PAS-246 pairing picker is out of this ticket: without it, omit the field so the daemon
/// uses the first advertisable host, matching the SPA.
enum LoginOfferHost {
    static func advertisedHost(pickerSelection: String?, pickerAvailable: Bool) -> String? {
        guard pickerAvailable else { return nil }
        let trimmed = pickerSelection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum LoginOfferQR {
    static func cgImage(from uri: String, scale: CGFloat = 10) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(uri.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

struct LoginOfferQRView: View {
    var uri: String

    var body: some View {
        Group {
            if let image = LoginOfferQR.cgImage(from: uri) {
                Image(image, scale: 1, label: Text("Sign-in QR"))
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 192, height: 192)
        .padding(8)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
