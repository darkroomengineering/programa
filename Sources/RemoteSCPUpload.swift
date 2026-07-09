import Foundation

/// Uploads each item in `items` via `performUpload`, tracking which remote paths have
/// been recorded so far. If any upload throws (including cancellation surfaced by
/// `checkCancelled`), invokes `cleanup` with whatever remote paths were recorded before
/// the failure, then rethrows the original error.
///
/// This is the shared control flow behind the two previously-independent
/// scp-upload-with-cancel-cleanup routines: the ad-hoc detected-SSH-session path
/// (`TerminalSSHSessionDetector.swift`) and the daemon-relay managed-workspace path
/// (`WorkspaceRemoteSession.swift`). The two differ in how a single file is transferred
/// (which executable/argument builder they use) and in whether they record a file's
/// remote destination before or after the transfer completes — both differences are
/// preserved by leaving them to `performUpload`, which decides when to call `record`.
/// Refs #92.
func performSCPUploadWithCancelCleanup<Item>(
    items: [Item],
    checkCancelled: () throws -> Void,
    performUpload: (_ item: Item, _ record: (String) -> Void) throws -> Void,
    cleanup: (_ uploadedRemotePaths: [String]) -> Void
) throws -> [String] {
    guard !items.isEmpty else { return [] }

    var uploadedRemotePaths: [String] = []
    do {
        for item in items {
            try checkCancelled()
            try performUpload(item) { uploadedRemotePaths.append($0) }
        }
        return uploadedRemotePaths
    } catch {
        cleanup(uploadedRemotePaths)
        throw error
    }
}
