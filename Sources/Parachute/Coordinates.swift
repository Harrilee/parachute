import Foundation

struct Coordinates: Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    /// Keep the entered precision when reopening the editor; display formatting is separate.
    var latitudeText: String { String(latitude) }
    var longitudeText: String { String(longitude) }

    static func parse(latitude: String, longitude: String) throws -> Coordinates {
        let lat = try decimal(latitude)
        let lon = try decimal(longitude)
        guard (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) else {
            throw CoordinateValidationError.outOfRange
        }
        return Coordinates(latitude: lat, longitude: lon)
    }

    private static func decimal(_ input: String) throws -> Double {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Both supported UI languages use a decimal point. Never interpret a comma
        // as a thousands separator: a pasted coordinate such as 1,234 is ambiguous.
        guard text.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              let value = Double(text), value.isFinite else {
            throw CoordinateValidationError.invalidNumber
        }
        return value
    }
}

enum CoordinateValidationError: Error, Equatable {
    case invalidNumber
    case outOfRange
}
