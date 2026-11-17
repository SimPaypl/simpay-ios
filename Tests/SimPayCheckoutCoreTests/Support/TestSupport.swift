import Foundation
@testable import SimPayCheckoutCore

/// Loads the shared, platform independent contract from the repository's `Contract/`
/// directory. `name` is a path relative to that directory, without the `.json` extension,
/// for example `"api/status-mapping"`.
///
/// The files are read in place rather than copied into the test bundle, so the contract
/// exists exactly once. This works for `swift test` on macOS and for the iOS simulator,
/// which both run on the machine that holds the checkout.
enum Fixture {

    static let contractDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Support
        .deletingLastPathComponent()   // SimPayCheckoutCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent("Contract", isDirectory: true)

    static func load<T: Decodable>(_ type: T.Type, named name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: data(named: name))
    }

    static func data(named name: String) throws -> Data {
        try Data(contentsOf: url(named: name))
    }

    static func url(named name: String) -> URL {
        contractDirectory.appendingPathComponent(name + ".json")
    }

    /// Every JSON file of a contract directory, sorted by name.
    static func files(in directory: String) throws -> [String] {
        let url = contractDirectory.appendingPathComponent(directory, isDirectory: true)
        return try FileManager.default.contentsOfDirectory(atPath: url.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .map { directory + "/" + String($0.dropLast(5)) }
    }
}

/// Captures the typed error of a throwing builder, or `nil` when it succeeds.
func caughtError<T>(_ build: () throws(SimPayCheckoutError) -> T) -> SimPayCheckoutError? {
    do {
        _ = try build()
        return nil
    } catch {
        return error
    }
}

/// Everything a value can reveal through printing, debugging and reflection.
func everyTextualForm(of value: Any) -> String {
    var dumped = ""
    dump(value, to: &dumped)
    return [String(describing: value), String(reflecting: value), dumped].joined(separator: "\n")
}

enum Sample {
    static let transactionID = TransactionID("3f2504e0-4f89-41d3-9a0c-0305e82c3301")!
    static let token = "mobsdk_test_eyJhbGciOiJIUzI1NiJ9.secret-payload.signature"
    static let email = "jan.kowalski@example.com"
    static let ip = "203.0.113.10"
}
