import Foundation

// Wire formats of the mobile SDK API. Kept separate from the domain models so the JSON
// shape can change without touching the SDK surface. Decoding is tolerant in the same
// places as `MobileSdkResponseParser` of the Android SDK: unknown fields are ignored,
// numeric identifiers are read as text and malformed list entries are skipped.

/// Common `{ "success": ..., "data": ... }` envelope.
struct EnvelopeDTO<Payload: Decodable>: Decodable {
    let success: Bool?
    let data: Payload?
}

/// Decodes a value or yields `nil` instead of failing the enclosing container.
struct LossyDTO<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// A JSON scalar that may arrive as a string or as a number.
///
/// Numbers are decoded as `Decimal`, never as `Double`, and rendered with
/// `Decimal.description`, which uses no locale and no exponent for these magnitudes.
struct FlexibleScalarDTO: Decodable {
    let text: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            text = nil
        } else if let string = try? container.decode(String.self) {
            text = string
        } else if let number = try? container.decode(Decimal.self) {
            text = number.description
        } else {
            text = nil
        }
    }
}

struct ChannelDTO: Decodable {
    struct AmountDTO: Decodable {
        let min: FlexibleScalarDTO?
        let max: FlexibleScalarDTO?
    }

    let id: FlexibleScalarDTO?
    let name: LossyDTO<String>?
    let type: LossyDTO<String>?
    let img: LossyDTO<String>?
    let currencies: LossyDTO<[LossyDTO<String>]>?
    let amount: LossyDTO<AmountDTO>?

    /// Mirrors `parseChannel`: a channel without an id is dropped, a missing name falls
    /// back to the id, and blank or `"null"` texts count as missing.
    func toDomain() -> PaymentChannel? {
        guard let id = id?.text.nonBlank else { return nil }

        let image = img?.value.nonBlank.flatMap(URL.init(string:)).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
        let limits = amount?.value

        return PaymentChannel(
            id: id,
            name: name?.value.nonBlank ?? id,
            type: type?.value.nonBlank,
            imageURL: image,
            currencies: currencies?.value?.compactMap { $0.value.nonBlank } ?? [],
            minimumAmount: limits?.min?.text.nonBlank.flatMap(Self.decimal),
            maximumAmount: limits?.max?.text.nonBlank.flatMap(Self.decimal)
        )
    }

    private static func decimal(_ text: String) -> Decimal? {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }
}

struct CreatedTransactionDTO: Decodable {
    let transactionId: LossyDTO<String>?
    let redirectUrl: LossyDTO<String>?
}

struct TransactionStatusDTO: Decodable {
    let transactionId: LossyDTO<String>?
    let status: LossyDTO<String>?
    let transactionStatus: LossyDTO<String>?
    let transaction_status: LossyDTO<String>?

    /// The API has used three spellings; the first non-blank one wins, as on Android.
    var rawStatus: String? {
        status?.value.nonBlank ?? transactionStatus?.value.nonBlank ?? transaction_status?.value.nonBlank
    }
}

/// Error body: `{ "message": "...", "errors": { "field": [...] } }`.
/// Only the field names are kept from `errors`.
struct APIErrorBodyDTO: Decodable {
    let message: String?
    let fieldNames: [String]

    private enum CodingKeys: String, CodingKey {
        case message, errors
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        let errors = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: .errors)
        fieldNames = errors?.allKeys.map(\.stringValue) ?? []
    }
}

private extension Optional where Wrapped == String {
    /// Treats `nil`, blank text and the literal `"null"` as missing, like `orNullIfBlank`.
    var nonBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value != "null" else { return nil }
        return self
    }
}
