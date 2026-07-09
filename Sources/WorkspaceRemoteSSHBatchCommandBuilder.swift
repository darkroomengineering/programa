// Extracted from WorkspaceRemoteDaemon.swift (nuclear-review #98): SSH argument builders for daemon-transport batch commands.

import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CryptoKit
import Darwin
import Network
import CoreText

enum WorkspaceRemoteSSHBatchCommandBuilder {
    static func daemonTransportArguments(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String
    ) -> [String] {
        let script = "exec \(RemoteSSHConnectionPolicy.shellSingleQuoted(remotePath)) serve --stdio"
        let command = "sh -c \(RemoteSSHConnectionPolicy.shellSingleQuoted(script))"
        return ["-T"]
            + batchArguments(configuration: configuration)
            + ["-o", "RequestTTY=no", configuration.destination, command]
    }

    static func reverseRelayControlMasterArguments(
        configuration: WorkspaceRemoteConfiguration,
        controlCommand: String,
        forwardSpec: String
    ) -> [String]? {
        guard let controlPath = RemoteSSHConnectionPolicy.optionValue(named: "ControlPath", in: configuration.sshOptions)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !controlPath.isEmpty,
              controlPath.lowercased() != "none" else {
            return nil
        }

        var args = batchArguments(configuration: configuration)
        args += ["-O", controlCommand, "-R", forwardSpec, configuration.destination]
        return args
    }

    private static func batchArguments(configuration: WorkspaceRemoteConfiguration) -> [String] {
        let effectiveSSHOptions = RemoteSSHConnectionPolicy.backgroundOptions(configuration.sshOptions)
        var args = RemoteSSHConnectionPolicy.keepaliveArguments
        args += RemoteSSHConnectionPolicy.strictHostKeyCheckingArguments(unlessSetIn: effectiveSSHOptions)
        // Batch helpers may reuse an existing ControlPath, but must not negotiate a new master.
        args += RemoteSSHConnectionPolicy.batchModeArguments
        if let port = configuration.port {
            args += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }
        return args
    }
}
