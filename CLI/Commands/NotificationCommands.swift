import Foundation

extension ProgramaCLI {
    func notificationDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["notify"],
                helpLines: ["notify --title <text> [--subtitle <text>] [--body <text>] [--workspace <id|ref>] [--surface <id|ref>]"],
                detailedUsage: """
                Usage: programa notify [flags]

                Send a notification to a workspace/surface.

                Flags:
                  --title <text>         Notification title (default: "Notification")
                  --subtitle <text>      Notification subtitle
                  --body <text>          Notification body
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)

                Example:
                  programa notify --title "Build done" --body "All tests passed"
                  programa notify --title "Error" --subtitle "test.swift" --body "Line 42: syntax error"
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["title", "subtitle", "body", "workspace", "surface"]),
                execute: { ctx in
                    let title = self.optionValue(ctx.commandArgs, name: "--title") ?? "Notification"
                    let subtitle = self.optionValue(ctx.commandArgs, name: "--subtitle") ?? ""
                    let body = self.optionValue(ctx.commandArgs, name: "--body") ?? ""

                    let explicitWorkspaceArg = self.optionValue(ctx.commandArgs, name: "--workspace")
                    let preferTTYFallback = ctx.windowId == nil && ProcessInfo.processInfo.environment["TMUX"] != nil
                    let callerWorkspaceArg = preferTTYFallback
                        ? nil
                        : (ctx.windowId == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
                    let workspaceArg = explicitWorkspaceArg ?? callerWorkspaceArg
                    let explicitSurfaceArg = self.optionValue(ctx.commandArgs, name: "--surface")
                    let envWorkspaceArg = ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"]
                    let callerSurfaceArg = explicitSurfaceArg == nil
                        && preferTTYFallback == false
                        && ctx.windowId == nil
                        && (explicitWorkspaceArg == nil || explicitWorkspaceArg == envWorkspaceArg)
                        ? ProcessInfo.processInfo.environment["PROGRAMA_SURFACE_ID"]
                        : nil
                    let surfaceArg = explicitSurfaceArg ?? callerSurfaceArg

                    let targetWorkspace = try {
                        if explicitWorkspaceArg != nil {
                            return try self.resolveWorkspaceId(workspaceArg, client: ctx.client)
                        }
                        return try self.resolveWorkspaceIdAllowingFallback(workspaceArg, client: ctx.client)
                    }()
                    let targetSurface = try {
                        if explicitSurfaceArg != nil {
                            return try self.resolveSurfaceId(surfaceArg, workspaceId: targetWorkspace, client: ctx.client)
                        }
                        return try self.resolveSurfaceIdAllowingFallback(
                            surfaceArg,
                            workspaceId: targetWorkspace,
                            client: ctx.client
                        )
                    }()

                    let payload = try ctx.client.sendV2(method: V2MethodNames.notificationCreateForTarget, params: [
                        "workspace_id": targetWorkspace,
                        "surface_id": targetSurface,
                        "title": title,
                        "subtitle": subtitle,
                        "body": body,
                    ])
                    self.printV2Payload(payload, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: "OK")
                }
            ),

            CommandDescriptor(
                names: ["list-notifications"],
                helpLines: ["list-notifications"],
                detailedUsage: """
                Usage: programa list-notifications

                List queued notifications.
                """,
                grammar: CLIArgumentGrammar(),
                execute: { ctx in
                    let listed = try ctx.client.sendV2(method: V2MethodNames.notificationList)
                    let notifications = listed["notifications"] as? [[String: Any]] ?? []
                    if ctx.jsonOutput {
                        let payload = notifications.enumerated().map { _, item -> [String: Any] in
                            var dict: [String: Any] = [
                                "id": (item["id"] as? String) ?? "",
                                "workspace_id": (item["workspace_id"] as? String) ?? "",
                                "is_read": (item["is_read"] as? Bool) ?? false,
                                "title": (item["title"] as? String) ?? "",
                                "subtitle": (item["subtitle"] as? String) ?? "",
                                "body": (item["body"] as? String) ?? "",
                            ]
                            dict["surface_id"] = item["surface_id"] as? String ?? NSNull()
                            return dict
                        }
                        print(self.jsonString(["notifications": payload]))
                    } else if notifications.isEmpty {
                        print("No notifications")
                    } else {
                        let lines = notifications.enumerated().map { index, item -> String in
                            let surfaceText = (item["surface_id"] as? String) ?? "none"
                            let readText = ((item["is_read"] as? Bool) ?? false) ? "read" : "unread"
                            let id = (item["id"] as? String) ?? ""
                            let workspaceId = (item["workspace_id"] as? String) ?? ""
                            let title = (item["title"] as? String) ?? ""
                            let subtitle = (item["subtitle"] as? String) ?? ""
                            let body = (item["body"] as? String) ?? ""
                            return "\(index):\(id)|\(workspaceId)|\(surfaceText)|\(readText)|\(title)|\(subtitle)|\(body)"
                        }
                        print(lines.joined(separator: "\n"))
                    }
                }
            ),

            CommandDescriptor(
                names: ["clear-notifications"],
                helpLines: ["clear-notifications [--workspace <id|ref>]"],
                detailedUsage: """
                Usage: programa clear-notifications [--workspace <id|ref>]

                Clear queued notifications. Run from a Programa terminal, it clears only
                that terminal's workspace ($PROGRAMA_WORKSPACE_ID). Run anywhere else, or
                with the global --window option, it clears every notification.

                Flags:
                  --workspace <id|ref>   Clear only this workspace's notifications

                Example:
                  programa clear-notifications
                  programa clear-notifications --workspace workspace:2
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace"]),
                execute: { ctx in
                    let response: [String: Any]
                    if let wsFlag = self.optionValue(ctx.commandArgs, name: "--workspace") {
                        let wsId = try self.resolveWorkspaceId(wsFlag, client: ctx.client)
                        response = try ctx.client.sendV2(method: V2MethodNames.notificationClear, params: ["workspace_id": wsId])
                    } else if ctx.windowId == nil,
                              let envWs = ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"],
                              let wsId = try? self.resolveWorkspaceId(envWs, client: ctx.client) {
                        response = try ctx.client.sendV2(method: V2MethodNames.notificationClear, params: ["workspace_id": wsId])
                    } else {
                        response = try ctx.client.sendV2(method: V2MethodNames.notificationClear)
                    }
                    self.printV2Payload(response.merging(["ok": true]) { $1 }, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, fallbackText: "OK")
                }
            ),
        ]
    }
}
