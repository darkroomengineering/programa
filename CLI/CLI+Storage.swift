import Foundation

extension ProgramaCLI {
    /// `storage scan` / `storage clean`, registered from `commandDescriptors()` (programa.swift).
    func storageDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["storage"],
                helpLines: ["storage <scan|clean> [--dry-run] [--include-external] [--now] [--xcode|--android|--packages|--caches] [--item <id>] [--path <dir>] [--json]"],
                detailedUsage: """
                Usage: programa storage scan [--json]
                       programa storage clean [--dry-run] [--include-external] [--now]
                           [--xcode] [--android] [--packages] [--caches] [--item <id>] [--path <dir>] [--json]

                Find git worktrees in the repos open in Programa and under the worktrees.directory
                setting, and show how much disk each one uses.

                Subcommands:
                  scan
                      List each worktree with its branch and size, and either "removable" or why
                      it is kept, followed by totals. Also list developer caches by category,
                      with size, item id, automatic cleanup eligibility and running-tool blockers.

                  clean [--dry-run] [--include-external] [--now]
                      Remove worktrees that are merged into the remote default branch (or whose
                      upstream branch was deleted), have no uncommitted or untracked changes, hold
                      no ignored env files (.env*, outside node_modules), are not open in a
                      workspace, have no process running inside, and were not used
                      for worktrees.autoRemoveAfterHours (default 24). Uses 'git worktree remove'
                      without --force and never deletes branches. Nothing is fetched first.

                Flags:
                  --dry-run            Show what clean would remove without removing it.
                  --include-external   Also remove worktrees outside worktrees.directory.
                  --now                Skip the unused-for-hours check (e.g. right after merging).
                  --xcode              Also clean Xcode caches.
                  --android            Also clean Android and Gradle caches.
                  --packages           Also clean package manager caches, excluding node_modules.
                  --caches             Also clean all three cache categories.
                  --item <id>          Select a specific cache item; repeatable. Restricts any
                                       chosen categories to those ids; works without category flags.
                  --path <dir>         Restrict worktrees to this directory or its descendants;
                                       repeatable. Does not restrict caches.
                  --json               Print the raw result.

                Cache cleanup rechecks safety before removal. Category flags include manual-only
                caches; the background pass removes only eligible, unblocked automatic items.

                Example:
                  programa storage scan
                  programa storage clean --dry-run
                  programa storage clean --now
                """,
                grammar: CLIArgumentGrammar(
                    valueOptions: ["item", "path"],
                    repeatableValueOptions: ["item", "path"],
                    booleanOptions: ["json", "dry-run", "include-external", "now", "xcode", "android", "packages", "caches"],
                    minPositionals: 1,
                    maxPositionals: 1
                ),
                execute: { ctx in
                    try self.runStorageCommand(ctx: ctx)
                }
            ),
        ]
    }

    /// A scan walks every worktree (up to 30 s each), well past the default 15 s response wait.
    private static let storageResponseTimeout: TimeInterval = 600

    private func runStorageCommand(ctx: CommandContext) throws {
        let args = ctx.commandArgs
        let values = try storageRepeatedOptions(args)
        let subcommand = values.remaining.first { !$0.hasPrefix("--") }
        let jsonOutput = ctx.jsonOutput || args.contains("--json")
        switch subcommand {
        case "scan":
            if let flag = args.first(where: { ["--dry-run", "--include-external", "--now", "--xcode", "--android", "--packages", "--caches", "--item", "--path"].contains($0.components(separatedBy: "=")[0]) }) {
                throw CLIError(message: "storage scan: \(flag) only applies to 'storage clean'")
            }
            let payload = try ctx.client.sendV2(
                method: V2MethodNames.storageScan,
                minimumReceiveTimeout: Self.storageResponseTimeout
            )
            if jsonOutput {
                print(jsonString(payload))
            } else {
                printStorageScan(payload)
            }
        case "clean":
            let dryRun = args.contains("--dry-run")
            let categories = ["xcode", "android", "packages"].filter { args.contains("--\($0)") || args.contains("--caches") }
            let payload = try ctx.client.sendV2(
                method: V2MethodNames.storageClean,
                params: [
                    "dry_run": dryRun,
                    "include_external": args.contains("--include-external"),
                    "ignore_grace_period": args.contains("--now"),
                    "categories": categories,
                    "items": values.items,
                    "paths": values.paths.map { (resolvePath($0) as NSString).standardizingPath },
                ],
                minimumReceiveTimeout: Self.storageResponseTimeout
            )
            if jsonOutput {
                print(jsonString(payload))
            } else {
                printStorageClean(payload, dryRun: dryRun)
            }
        default:
            throw CLIError(message: "storage: unknown subcommand '\(subcommand ?? "")'; expected scan or clean")
        }
    }

    private func storageRepeatedOptions(_ args: [String]) throws -> (items: [String], paths: [String], remaining: [String]) {
        let (items, withoutItems) = parseRepeatedOption(args, name: "--item")
        let (paths, remaining) = parseRepeatedOption(withoutItems, name: "--path")
        guard (items + paths).allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else {
            throw CLIError(message: "storage: item and path values must be nonempty")
        }
        return (items, paths, remaining)
    }

    private func printStorageScan(_ payload: [String: Any]) {
        let worktrees = payload["worktrees"] as? [[String: Any]] ?? []
        if worktrees.isEmpty {
            print("No git worktrees found")
        }
        var rows: [[String]] = [["PATH", "BRANCH", "SIZE", "STATUS"]]
        for worktree in worktrees {
            let partial = worktree["size_partial"] as? Bool == true ? "+" : ""
            let status: String
            if worktree["removable"] as? Bool == true {
                status = "removable"
            } else {
                status = storageBlockerText(worktree["blocker"] as? String, message: nil)
            }
            rows.append([
                worktree["path"] as? String ?? "",
                worktree["branch"] as? String ?? "(detached)",
                storageByteText(worktree["size_bytes"]) + partial,
                status,
            ])
        }
        let widths = (0..<3).map { column in rows.map { $0[column].count }.max() ?? 0 }
        for row in rows {
            let padded = (0..<3).map { row[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
            print((padded + [row[3]]).joined(separator: "  "))
        }
        print("")
        print("Total: \(storageByteText(payload["total_bytes"])) in \(worktrees.count) worktree(s); reclaimable: \(storageByteText(payload["reclaimable_bytes"]))")
        if worktrees.contains(where: { $0["size_partial"] as? Bool == true }) {
            print("+ size walk stopped early; the real size is larger")
        }
        let caches = payload["caches"] as? [[String: Any]] ?? []
        for category in ["xcode", "android", "packages"] {
            let items = caches.filter { $0["category"] as? String == category }
            guard !items.isEmpty else { continue }
            print("\n\(category):")
            for item in items {
                let status = (item["blocker"] as? String).map { "blocked: \($0)" }
                    ?? (item["auto_cleanable"] as? Bool == true ? "auto-clean" : "manual only")
                let partial = item["size_partial"] as? Bool == true ? "+" : ""
                print("  \(item["id"] as? String ?? "")  \(storageByteText(item["size_bytes"]))\(partial)  \(status)")
                print("    \(item["title"] as? String ?? "")\( (item["path"] as? String).map { "  " + $0 } ?? "")")
            }
        }
    }

    private func printStorageClean(_ payload: [String: Any], dryRun: Bool) {
        let removed = payload["removed"] as? [String] ?? []
        let kept = payload["kept"] as? [[String: Any]] ?? []
        let bytes = storageByteText(payload["reclaimed_bytes"])
        if removed.isEmpty {
            print(dryRun ? "Nothing to remove" : "Removed nothing")
        } else {
            print(dryRun ? "Would remove \(removed.count) worktree(s), \(bytes):" : "Removed \(removed.count) worktree(s), reclaimed \(bytes):")
            for path in removed {
                print("  \(path)")
            }
        }
        if !kept.isEmpty {
            print("Kept \(kept.count):")
            for item in kept {
                let path = item["path"] as? String ?? ""
                print("  \(path)  \(storageBlockerText(item["blocker"] as? String, message: item["message"] as? String))")
            }
        }
        let cachesRemoved = payload["caches_removed"] as? [[String: Any]] ?? []
        let cachesKept = payload["caches_kept"] as? [[String: Any]] ?? []
        if !cachesRemoved.isEmpty {
            print("\(dryRun ? "Would remove" : "Removed") \(cachesRemoved.count) cache item(s), \(storageByteText(payload["caches_reclaimed_bytes"])):")
            for item in cachesRemoved { print("  \(item["id"] as? String ?? "")") }
        }
        if !cachesKept.isEmpty {
            print("Kept \(cachesKept.count) cache item(s):")
            for item in cachesKept { print("  \(item["id"] as? String ?? "")  \(item["blocker"] as? String ?? "kept")") }
        }
    }

    private func storageBlockerText(_ blocker: String?, message: String?) -> String {
        guard let blocker else { return "kept" }
        switch blocker {
        case "external": return "outside worktrees.directory"
        case "status_unknown": return "git status unknown"
        case "dirty": return "uncommitted changes"
        case "env_files": return "ignored env files"
        case "not_merged": return "not merged"
        case "open_in_workspace": return "open in a workspace"
        case "process_running": return "process running inside"
        case "recently_used": return "used recently"
        case "git_refused": return "git refused: \(message ?? "")"
        default: return blocker
        }
    }

    private func storageByteText(_ value: Any?) -> String {
        let bytes = (value as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
