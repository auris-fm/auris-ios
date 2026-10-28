import Foundation

/// ECMAScript `Number::toString` rendering for RFC 8785 (JCS) canonical JSON.
///
/// Why this exists as its own type: the digest binds the record, so the canonical text must match
/// the SERVER's encoder byte-for-byte or a compliant record is rejected. A naive
/// `String(describing:)`/`NSNumber` route gets the boolean, negative-zero and exponent cases wrong
/// (`false` → `0`, `-0` → `-0`, `1e-7` → `1e-07`), and every audio block contains a boolean, so
/// that is not an edge case.
///
/// Digit selection reuses Swift's own `Double.description`, which is already the shortest string
/// that round-trips to the same `Double` — the same guarantee ECMA-262 step 5 requires. The
/// PRESENTATION is rebuilt here from the digits and decimal exponent, following ECMA-262
/// `Number::toString` steps 14–20 exactly:
///   * `-0` renders as `0` (and `0` as `0`);
///   * exponent strictly between -6 and 21 (exclusive at 21) renders in fixed notation;
///   * otherwise exponential with an explicit `+`/`-` and no zero padding.
///
/// Precedent: the reviewed Android lane's `CanonicalJson.formatNumber`/`renderEs` does the same
/// rendering over its Ryu digits; this is the equivalent over Swift's shortest digits.
enum ES6NumberFormat {

    /// Canonical ES6 text for a finite `Double`, or nil for non-finite input (RFC 8785 refuses it).
    static func canonical(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        // ES6 renders both +0 and -0 as "0".
        if value == 0 { return "0" }

        let negative = value < 0
        let magnitude = negative ? -value : value
        let shortest = magnitude.description

        guard let (digits, exponent) = split(shortest) else { return nil }
        let body = render(digits: digits, exponent: exponent)
        return negative ? "-" + body : body
    }

    /// Splits a shortest round-trip literal into (significand digits, decimal exponent of the first
    /// digit). Handles both fixed (`16000.0`, `0.1`) and exponential (`1e-07`) forms.
    private static func split(_ literal: String) -> (digits: String, exponent: Int)? {
        var mantissa = literal
        var explicitExponent = 0
        if let eIndex = mantissa.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            guard let parsed = Int(mantissa[mantissa.index(after: eIndex)...]) else { return nil }
            explicitExponent = parsed
            mantissa = String(mantissa[mantissa.startIndex..<eIndex])
        }
        var integerPart = mantissa
        var fractionPart = ""
        if let dotIndex = mantissa.firstIndex(of: ".") {
            integerPart = String(mantissa[mantissa.startIndex..<dotIndex])
            fractionPart = String(mantissa[mantissa.index(after: dotIndex)...])
        }
        // Decimal exponent of the leading digit, before stripping zeros.
        let leadingExponent = integerPart.count - 1 + explicitExponent
        var digits = integerPart + fractionPart
        // Strip leading zeros (0.0012 → digits 12) adjusting the exponent per stripped digit.
        var adjusted = leadingExponent
        while digits.count > 1, digits.first == "0" {
            digits.removeFirst()
            adjusted -= 1
        }
        // Strip trailing zeros: they change neither the value nor ES6 presentation.
        while digits.count > 1, digits.last == "0" {
            digits.removeLast()
        }
        return (digits, adjusted)
    }

    /// ECMA-262 steps 14–20: fixed when -6 <= e < 21, exponential otherwise.
    private static func render(digits: String, exponent: Int) -> String {
        let count = digits.count
        if exponent >= -6 && exponent < 21 {
            let integerLength = exponent + 1
            if integerLength <= 0 {
                return "0." + String(repeating: "0", count: -integerLength) + digits
            }
            if count <= integerLength {
                return digits + String(repeating: "0", count: integerLength - count)
            }
            let splitIndex = digits.index(digits.startIndex, offsetBy: integerLength)
            return String(digits[digits.startIndex..<splitIndex]) + "." + String(digits[splitIndex...])
        }
        let mantissa = count > 1
            ? String(digits.first!) + "." + String(digits.dropFirst())
            : digits
        return mantissa + "e" + (exponent < 0 ? "-" : "+") + String(abs(exponent))
    }
}