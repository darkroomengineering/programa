import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class TypeSafeCredentialStoreTests: XCTestCase {
    func testSavedCredentialWinsWithoutConsultingEnvironment() {
        let backend = FakeCredentialBackend(saved: .value("  saved-token  "), environment: "environment-token")

        XCTAssertEqual(
            backend.store.credential(discoverEnvironment: true),
            .available(TypeSafeCredential(value: "saved-token", source: .saved))
        )
        XCTAssertEqual(backend.environmentReadCount, 0, "saved credentials must not expose environment state")
    }

    func testEnvironmentDiscoveryIsOptionalAndRejectsBlankValues() {
        let backend = FakeCredentialBackend(environment: "  environment-token  ")

        XCTAssertEqual(
            backend.store.credential(discoverEnvironment: true),
            .available(TypeSafeCredential(value: "environment-token", source: .environment))
        )

        backend.environment = " \n\t "
        XCTAssertEqual(backend.store.credential(discoverEnvironment: true), .missing)
    }

    func testDisabledDiscoveryDoesNotReadEnvironment() {
        let backend = FakeCredentialBackend(environment: "environment-token")

        XCTAssertEqual(backend.store.credential(discoverEnvironment: false), .missing)
        XCTAssertEqual(backend.environmentReadCount, 0, "opt-out must prevent even probing the process environment")
    }

    func testStorageFailureIsUnavailableWithoutEnvironmentFallback() {
        let backend = FakeCredentialBackend(saved: .unavailable, environment: "environment-token")

        XCTAssertEqual(backend.store.credential(discoverEnvironment: true), .unavailable)
        XCTAssertEqual(backend.environmentReadCount, 0, "a Keychain failure must not silently change credential source")
    }

    func testSuccessfulSaveAndRemoveDriveLookupTransitions() {
        let backend = FakeCredentialBackend()

        XCTAssertEqual(backend.store.save("  saved-token  "), .success)
        XCTAssertEqual(backend.writeAttempts, ["saved-token"], "only the normalized credential may reach secure storage")
        XCTAssertEqual(
            backend.store.credential(discoverEnvironment: false),
            .available(TypeSafeCredential(value: "saved-token", source: .saved))
        )

        XCTAssertEqual(backend.store.remove(), .success)
        XCTAssertEqual(backend.removeAttemptCount, 1)
        XCTAssertEqual(backend.store.credential(discoverEnvironment: false), .missing)
    }

    func testValidationAndFailedMutationsDoNotReplaceSavedCredentialOrLeakCandidate() {
        let backend = FakeCredentialBackend(saved: .value("kept-token"))

        XCTAssertEqual(backend.store.save("   \n"), .blank)
        XCTAssertEqual(backend.store.save("token with-space"), .invalidCharacters)
        XCTAssertTrue(backend.writeAttempts.isEmpty, "invalid candidates must be rejected before secure storage")

        let secret = "candidate-that-must-not-leak"
        backend.writeSucceeds = false
        let failedSave = backend.store.save(secret)
        XCTAssertEqual(failedSave, .unavailable)
        XCTAssertFalse(String(describing: failedSave).contains(secret))
        XCTAssertEqual(backend.saved, .value("kept-token"), "a failed write must preserve the previous credential")

        backend.removeSucceeds = false
        let failedRemove = backend.store.remove()
        XCTAssertEqual(failedRemove, .unavailable)
        XCTAssertFalse(String(describing: failedRemove).contains("kept-token"))
        XCTAssertEqual(backend.saved, .value("kept-token"), "a failed removal must preserve the previous credential")
    }
}

private final class FakeCredentialBackend {
    var saved: TypeSafeCredentialStorageRead
    var environment: String?
    var writeSucceeds = true
    var removeSucceeds = true
    private(set) var environmentReadCount = 0
    private(set) var writeAttempts: [String] = []
    private(set) var removeAttemptCount = 0

    init(saved: TypeSafeCredentialStorageRead = .missing, environment: String? = nil) {
        self.saved = saved
        self.environment = environment
    }

    var store: TypeSafeCredentialStore {
        TypeSafeCredentialStore(
            readSavedCredential: { self.saved },
            writeSavedCredential: { candidate in
                self.writeAttempts.append(candidate)
                guard self.writeSucceeds else { return false }
                self.saved = .value(candidate)
                return true
            },
            removeSavedCredential: {
                self.removeAttemptCount += 1
                guard self.removeSucceeds else { return false }
                self.saved = .missing
                return true
            },
            readEnvironmentCredential: {
                self.environmentReadCount += 1
                return self.environment
            }
        )
    }
}
