// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Vision
import CoreVideo

public struct PairingOffer: Decodable {
    public let kind: String
    public let version: Int
    public let address: String
    public let fingerprint: String
    public let code: String

    public static func parse(_ raw: String, allowLoopback: Bool = false) throws -> PairingOffer {
        guard raw.utf8.count <= 2048 else { throw RemoteError.malformedResponse }
        let offer = try JSONDecoder().decode(Self.self, from: Data(raw.utf8))
        guard offer.kind == "wifi-remote-input", offer.version == 1,
              offer.code.count == 8, offer.code.allSatisfy({ "0123456789".contains($0) }) else { throw RemoteError.malformedResponse }
        _ = try Transport.endpoint(address: offer.address, allowLoopback: allowLoopback)
        _ = try Transport.normalizedFingerprint(offer.fingerprint)
        return offer
    }
}

public enum PairingQR {
    public static func decode(image: CGImage, allowLoopback: Bool = false) throws -> PairingOffer {
        try decode(handler: VNImageRequestHandler(cgImage: image), allowLoopback: allowLoopback)
    }
    public static func decode(frame: CVPixelBuffer) throws -> PairingOffer {
        try decode(handler: VNImageRequestHandler(cvPixelBuffer: frame), allowLoopback: false)
    }
    private static func decode(handler: VNImageRequestHandler, allowLoopback: Bool) throws -> PairingOffer {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try handler.perform([request])
        let offers = (request.results ?? []).compactMap { observation -> PairingOffer? in
            guard let raw = observation.payloadStringValue else { return nil }
            return try? PairingOffer.parse(raw, allowLoopback: allowLoopback)
        }
        // Never silently pick a device when two valid pairing QR codes are in the frame.
        guard offers.count == 1 else { throw RemoteError.malformedResponse }
        return offers[0]
    }
}
