import Foundation
import Darwin
import Security
import Bonsplit

// MARK: - Wire format

/// Fixed-size frame format shared by every message on the escrow control
/// connection. Always exactly `frameSize` bytes so the read side never
/// needs to peek a length prefix -- see the file-level "Protocol" doc
/// comment.
enum EscrowWireFormat {
    static let sessionIdSize = 36 // UUID string, e.g. TerminalSurface.id.uuidString
    static let tokenSize = 32
    static let childPIDSize = 4
    static let payloadSize = sessionIdSize + tokenSize + childPIDSize
    static let frameSize = 1 + payloadSize

    static let heartbeatType: UInt8 = 0x01
    static let escrowType: UInt8 = 0x02
    /// Issue #182 slice 2: app -> holder, session id + token, no ancillary
    /// fd. See the file-level "Retrieval protocol" doc comment.
    static let retrieveRequestType: UInt8 = 0x03
    /// Issue #182 slice 2: holder -> app, session id + a one-byte
    /// granted/denied flag (packed into the childPID field's bytes, unused
    /// otherwise by this type). Carries the live master fd as `SCM_RIGHTS`
    /// ancillary data iff granted.
    static let retrieveResponseType: UInt8 = 0x04
    /// App -> holder: this session was closed by the user for real, so drop
    /// it instead of holding its pty master open. Session id + token, no
    /// ancillary fd, no response.
    ///
    /// Without this the holder has no way to learn that a session ended: it
    /// holds a dup of the pty master, so freeing the app-side surface never
    /// hangs up the terminal and the shell (with whatever agent is running
    /// in it) survives. A session closed while the app keeps running is not
    /// even covered by `unclaimedSessionTTL`, which only applies once a
    /// session is draining -- so it would be held until the holder exits.
    ///
    /// Only sent past the close-undo grace period (see
    /// `ClosedTerminalUndoStore`), never on app quit: quitting must keep
    /// escrowing so the next launch can reattach.
    ///
    /// Holders that predate this frame fall into `serve`'s `default` branch,
    /// which logs and skips, degrading to the previous behavior.
    static let releaseType: UInt8 = 0x05
    static let acknowledgedEscrowType: UInt8 = 0x06
    static let escrowAcknowledgementType: UInt8 = 0x07
    static let acknowledgedReleaseType: UInt8 = 0x08

    /// Why the holder denied a retrieve. Carried in the FIRST byte of the
    /// response frame's otherwise-unused 32-byte token padding
    /// (`retrieveDenyReasonOffset`), so pre-reason holders -- which
    /// zero-pad that region -- decode as `.unspecified` and the frame size
    /// never changes. This matters across an app UPDATE specifically: the
    /// holder outlives the app, so a new client routinely talks to a holder
    /// built from the previous version. `notDraining` is the only reason a
    /// rightful successor should retry (the holder resolves it on its own
    /// within `heartbeatStaleAfter`); every other reason is permanent.
    enum RetrieveDenyReason: UInt8 {
        case unspecified = 0
        case unknownSession = 1
        case tokenMismatch = 2
        case notDraining = 3
        case drainStopTimeout = 4
    }
    static let retrieveDenyReasonOffset = 1 + sessionIdSize

    struct Decoded {
        let type: UInt8
        let sessionId: String?
        let token: [UInt8]?
        let childPID: Int32?
        /// Only meaningful when `type == retrieveResponseType`: whether the
        /// holder granted the retrieval.
        let retrieveGranted: Bool?
        /// Only meaningful when `type == retrieveResponseType` and
        /// `retrieveGranted == false`. `.unspecified` for frames from
        /// pre-reason holders (zero padding) and for reason bytes this
        /// build does not know.
        let retrieveDenyReason: RetrieveDenyReason?
    }

    static func heartbeatFrame() -> Data {
        var data = Data(count: frameSize)
        data[0] = heartbeatType
        return data
    }

    static func encodeEscrowFrame(sessionId: String, token: [UInt8], childPID: Int32) -> Data? {
        guard sessionId.utf8.count == sessionIdSize, token.count == tokenSize else { return nil }
        var data = Data(capacity: frameSize)
        data.append(escrowType)
        data.append(contentsOf: Array(sessionId.utf8))
        data.append(contentsOf: token)
        withUnsafeBytes(of: childPID.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    static func encodeRetrieveRequestFrame(sessionId: String, token: [UInt8]) -> Data? {
        guard sessionId.utf8.count == sessionIdSize, token.count == tokenSize else { return nil }
        var data = Data(capacity: frameSize)
        data.append(retrieveRequestType)
        data.append(contentsOf: Array(sessionId.utf8))
        data.append(contentsOf: token)
        data.append(Data(count: childPIDSize)) // unused padding for this type
        return data
    }

    static func encodeReleaseFrame(sessionId: String, token: [UInt8]) -> Data? {
        guard sessionId.utf8.count == sessionIdSize, token.count == tokenSize else { return nil }
        var data = Data(capacity: frameSize)
        data.append(releaseType)
        data.append(contentsOf: Array(sessionId.utf8))
        data.append(contentsOf: token)
        data.append(Data(count: childPIDSize)) // unused padding for this type
        return data
    }

    static func encodeRetrieveResponseFrame(
        sessionId: String,
        granted: Bool,
        denyReason: RetrieveDenyReason = .unspecified
    ) -> Data? {
        guard sessionId.utf8.count == sessionIdSize else { return nil }
        var data = Data(capacity: frameSize)
        data.append(retrieveResponseType)
        data.append(contentsOf: Array(sessionId.utf8))
        var padding = Data(count: tokenSize) // unused by pre-reason decoders
        padding[0] = granted ? 0 : denyReason.rawValue
        data.append(padding)
        data.append(contentsOf: [granted ? 1 : 0, 0, 0, 0])
        return data
    }

    static func decode(_ data: Data) -> Decoded? {
        guard data.count == frameSize else { return nil }
        let bytes = [UInt8](data)
        let type = bytes[0]
        switch type {
        case escrowType, acknowledgedEscrowType, retrieveRequestType, releaseType, acknowledgedReleaseType:
            var offset = 1
            let sessionIdBytes = Array(bytes[offset..<(offset + sessionIdSize)])
            offset += sessionIdSize
            let tokenBytes = Array(bytes[offset..<(offset + tokenSize)])
            offset += tokenSize
            let pidBytes = Array(bytes[offset..<(offset + childPIDSize)])
            guard let sessionId = String(bytes: sessionIdBytes, encoding: .utf8) else { return nil }
            let rawPID = pidBytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            let childPID: Int32? = (type == escrowType || type == acknowledgedEscrowType) ? Int32(littleEndian: rawPID) : nil
            return Decoded(type: type, sessionId: sessionId, token: tokenBytes, childPID: childPID, retrieveGranted: nil, retrieveDenyReason: nil)
        case retrieveResponseType, escrowAcknowledgementType:
            let offset = 1 + sessionIdSize + tokenSize
            let sessionIdBytes = Array(bytes[1..<(1 + sessionIdSize)])
            guard let sessionId = String(bytes: sessionIdBytes, encoding: .utf8) else { return nil }
            let grantedByte = bytes[offset]
            let denyReason = RetrieveDenyReason(rawValue: bytes[retrieveDenyReasonOffset]) ?? .unspecified
            return Decoded(type: type, sessionId: sessionId, token: nil, childPID: nil, retrieveGranted: grantedByte == 1, retrieveDenyReason: denyReason)
        default:
            return Decoded(type: type, sessionId: nil, token: nil, childPID: nil, retrieveGranted: nil, retrieveDenyReason: nil)
        }
    }
}
