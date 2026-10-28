import Foundation

@main
struct CoordinatesTests {
    static func main() throws {
        let valid: [(String, String, Double, Double)] = [
            ("0", "0", 0, 0), ("90", "180", 90, 180), ("-90", "-180", -90, -180),
            ("37.3346", "-122.009", 37.3346, -122.009), (" +0.5 ", " -.25\n", 0.5, -0.25),
            ("-0", "180.000000", -0.0, 180), ("89.999999", "179.999999", 89.999999, 179.999999),
        ]
        for (lat, lon, expectedLat, expectedLon) in valid {
            let result = try Coordinates.parse(latitude: lat, longitude: lon)
            precondition(result.latitude == expectedLat && result.longitude == expectedLon)
        }
        let invalid: [(String, String)] = [
            ("", "0"), ("0", ""), (" \n", "0"), ("91", "0"), ("-90.00001", "0"),
            ("0", "180.00001"), ("0", "-181"), ("nan", "0"), ("0", "inf"),
            ("Infinity", "0"), ("abc", "0"), ("0", "1,234"), ("0", "122,5"),
            ("1 2", "0"), ("--2", "0"), (".", "0"), ("1e1000", "0"),
        ]
        for (lat, lon) in invalid {
            do {
                _ = try Coordinates.parse(latitude: lat, longitude: lon)
                fatalError("Unexpected valid coordinate: \(lat), \(lon)")
            } catch is CoordinateValidationError { }
        }
        print("Passed \(valid.count + invalid.count) coordinate validation cases")
    }
}
