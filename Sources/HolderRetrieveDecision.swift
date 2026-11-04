import Foundation
import Darwin
import Security
import Bonsplit

/// The holder's grant/deny rule for one retrieve request, separated from
/// the socket I/O in `SessionEscrowHolder.handleRetrieveRequest`.
enum HolderRetrieveDecision: Equatable {
    case grant
    case deny(EscrowWireFormat.RetrieveDenyReason)

    /// Unknown session, then token mismatch, then not draining. A session
    /// that is not draining may still belong to a live app -- only that
    /// app's EOF (or a stale heartbeat from a dead pid) proves otherwise --
    /// so the caller gets `notDraining`, which it retries briefly instead
    /// of falling back for good (the 2026-08-10 mass-drain).
    static func decide(sessionExists: Bool, tokenMatches: Bool, isDraining: Bool) -> HolderRetrieveDecision {
        guard sessionExists else { return .deny(.unknownSession) }
        guard tokenMatches else { return .deny(.tokenMismatch) }
        guard isDraining else { return .deny(.notDraining) }
        return .grant
    }

    static func label(for reason: EscrowWireFormat.RetrieveDenyReason) -> String {
        switch reason {
        case .unknownSession: return "unknown"
        case .tokenMismatch: return "token_mismatch"
        case .notDraining: return "not_draining"
        case .drainStopTimeout: return "drain_stop_timeout"
        case .unspecified: return "unspecified"
        }
    }
}
