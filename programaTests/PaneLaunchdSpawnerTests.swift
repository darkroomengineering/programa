import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class PaneLaunchdSpawnerTests: XCTestCase {
    func testLabelIsStableAndSeparatesSurfaces() {
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(PaneLaunchdSpawner.label(surfaceID: first), PaneLaunchdSpawner.label(surfaceID: first))
        XCTAssertNotEqual(PaneLaunchdSpawner.label(surfaceID: first), PaneLaunchdSpawner.label(surfaceID: second))
        XCTAssertTrue(PaneLaunchdSpawner.label(surfaceID: first).hasSuffix(first.uuidString.lowercased()))
    }

    func testEnvironmentPreservesEmptyValuesAndEqualsInValues() {
        let strings = ["EMPTY=", "TOKEN=a=b=c", "UNICODE=日本語", "INVALID"].map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) } + [nil]
        pointers.withUnsafeBufferPointer { buffer in
            XCTAssertEqual(PaneLaunchdSpawner.environmentDictionary(buffer.baseAddress!), [
                "EMPTY": "", "TOKEN": "a=b=c", "UNICODE": "日本語",
            ])
        }
    }
}
