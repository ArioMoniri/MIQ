import Foundation

/// Lenient accessors over `JSONSerialization` output.
///
/// Foundation's JSON numbers surface as `NSNumber` on Darwin but as native
/// `Int`/`Double`/`Bool` on swift-corelibs-foundation (the Linux test harness),
/// so every read goes through these helpers rather than a bare `as? Int`.
enum ZarrJSON {
    typealias Object = [String: Any]

    /// Parses a JSON object from `url`. `nil` when the file is missing; throws a
    /// `malformedFile` when it exists but is not a JSON object.
    static func object(at url: URL) throws -> Object? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? Object else {
            throw MIQError.malformedFile("\(url.lastPathComponent) is not a JSON object")
        }
        return object
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: return v
        case let v as Int64: return Int(exactly: v)
        case let v as UInt64: return Int(exactly: v)
        case let v as Double: return v.isFinite && v == v.rounded() && abs(v) < 9.0e18 ? Int(v) : nil
        case let v as NSNumber: return v.intValue
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as Float: return Double(v)
        case let v as NSNumber: return v.doubleValue
        default: return nil
        }
    }

    static func intArray(_ value: Any?) -> [Int]? {
        guard let array = value as? [Any] else { return nil }
        var result: [Int] = []
        result.reserveCapacity(array.count)
        for element in array {
            guard let v = int(element) else { return nil }
            result.append(v)
        }
        return result
    }

    static func doubleArray(_ value: Any?) -> [Double]? {
        guard let array = value as? [Any] else { return nil }
        var result: [Double] = []
        result.reserveCapacity(array.count)
        for element in array {
            guard let v = double(element) else { return nil }
            result.append(v)
        }
        return result
    }
}
