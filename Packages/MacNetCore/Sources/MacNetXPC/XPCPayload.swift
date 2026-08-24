import Foundation
import MacNetModels

/// Encoding and decoding for the JSON payloads carried by the XPC interface.
///
/// The interface itself is Objective-C and therefore deals in `Data`. Everything is funnelled
/// through here so that the size limits and the date strategy are applied uniformly, and so
/// no call site is free to invent its own decoder.
///
/// Ticket §7.10 forbids `[String: Any]` as a wire format: every payload decodes into an
/// explicit, named model or is rejected.
public enum XPCPayload {

    /// ISO-8601 for every date on the wire, so payloads stay readable in logs and stable
    /// across locale and time-zone differences between the app and the root helper.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Deterministic output makes payloads diffable and hashable in tests.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encodes a value, refusing anything larger than `limit`.
    public static func encode<T: Encodable>(
        _ value: T, limit: Int
    ) throws(ServiceFailure) -> Data {
        let data: Data
        do {
            data = try makeEncoder().encode(value)
        } catch {
            throw ServiceFailure.internalError("failed to encode payload: \(error)")
        }
        guard data.count <= limit else {
            throw ServiceFailure.payloadTooLarge(byteCount: data.count, limit: limit)
        }
        return data
    }

    /// Decodes a value, refusing anything larger than `limit` **before** parsing it.
    ///
    /// The order matters: checking the size first is what keeps a hostile payload from being
    /// parsed at all.
    public static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        limit: Int
    ) throws(ServiceFailure) -> T {
        guard data.count <= limit else {
            throw ServiceFailure.payloadTooLarge(byteCount: data.count, limit: limit)
        }
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            throw ServiceFailure.invalidRequest("failed to decode \(type): \(error)")
        }
    }

    // Convenience wrappers so call sites cannot accidentally apply the wrong direction's
    // limit.

    public static func encodeRequest<T: Encodable>(_ value: T) throws(ServiceFailure) -> Data {
        try encode(value, limit: XPCLimits.maximumRequestBytes)
    }

    public static func decodeRequest<T: Decodable>(
        _ type: T.Type, from data: Data
    ) throws(ServiceFailure) -> T {
        try decode(type, from: data, limit: XPCLimits.maximumRequestBytes)
    }

    public static func encodeResponse<T: Encodable>(_ value: T) throws(ServiceFailure) -> Data {
        try encode(value, limit: XPCLimits.maximumResponseBytes)
    }

    public static func decodeResponse<T: Decodable>(
        _ type: T.Type, from data: Data
    ) throws(ServiceFailure) -> T {
        try decode(type, from: data, limit: XPCLimits.maximumResponseBytes)
    }
}
