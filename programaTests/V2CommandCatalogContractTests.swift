import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Runtime check that `V2CommandCatalog.baseMethods` (compiled into the app) equals the
/// base (non-debug-only) method set in the checked-in `contracts/v2/methods.json`. This
/// catches the case `scripts/check-v2-contract.sh` cannot: someone hand-edits the
/// generated `V2CommandCatalog.swift` (or reverts a regeneration) without touching the
/// contract, so a source diff of the generator's output would still look "clean" against
/// the stale committed file, but the compiled catalog and the contract disagree.
final class V2CommandCatalogContractTests: XCTestCase {

    private struct Contract: Decodable {
        struct MethodEntry: Decodable {
            let debugOnly: Bool

            enum CodingKeys: String, CodingKey {
                case debugOnly = "debug_only"
            }
        }
        let methods: [String: MethodEntry]
    }

    private func loadContract() throws -> Contract {
        // programaTests/V2CommandCatalogContractTests.swift -> repo root is one level up.
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // programaTests/
            .deletingLastPathComponent() // repo root
        let contractURL = repoRoot
            .appendingPathComponent("contracts")
            .appendingPathComponent("v2")
            .appendingPathComponent("methods.json")

        let data = try Data(contentsOf: contractURL)
        return try JSONDecoder().decode(Contract.self, from: data)
    }

    func testBaseMethodsMatchContract() throws {
        let contract = try loadContract()
        let contractBaseMethods = Set(
            contract.methods.filter { !$0.value.debugOnly }.keys
        )
        let catalogBaseMethods = Set(V2CommandCatalog.baseMethods)

        XCTAssertEqual(
            catalogBaseMethods,
            contractBaseMethods,
            "V2CommandCatalog.baseMethods has drifted from contracts/v2/methods.json's "
                + "non-debug-only method set. Missing from catalog: "
                + "\(contractBaseMethods.subtracting(catalogBaseMethods).sorted()); "
                + "extra in catalog: \(catalogBaseMethods.subtracting(contractBaseMethods).sorted()). "
                + "Run: python3 scripts/gen-v2-contract.py"
        )
    }

    func testDebugMethodsMatchContract() throws {
        let contract = try loadContract()
        let contractDebugMethods = Set(
            contract.methods.filter { $0.value.debugOnly }.keys
        )
        let catalogDebugMethods = Set(V2CommandCatalog.debugMethods)

        XCTAssertEqual(
            catalogDebugMethods,
            contractDebugMethods,
            "V2CommandCatalog.debugMethods has drifted from contracts/v2/methods.json's "
                + "debug_only method set. Run: python3 scripts/gen-v2-contract.py"
        )
    }

    func testNoMethodAppearsInBothCatalogArrays() {
        let overlap = Set(V2CommandCatalog.baseMethods)
            .intersection(V2CommandCatalog.debugMethods)
        XCTAssertTrue(overlap.isEmpty, "Method(s) present in both baseMethods and debugMethods: \(overlap.sorted())")
    }
}
