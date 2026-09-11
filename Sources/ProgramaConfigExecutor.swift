import AppKit
import Foundation

@MainActor
struct ProgramaConfigExecutor {

    static func execute(
        command: ProgramaCommandDefinition,
        tabManager: TabManager,
        baseCwd: String,
        configSourcePath: String?,
        globalConfigPath: String
    ) {
        var parameterValues: [String: String] = [:]
        if let parameters = command.parameters, !parameters.isEmpty {
            guard let collected = collectParameterValues(parameters, entryName: command.name) else { return }
            parameterValues = collected
        }

        let resolvedCommand = command.command.map { substituteParameters(in: $0, values: parameterValues) }

        guard confirmIfUntrusted(
            kind: .command,
            confirmFlag: command.confirm == true,
            detail: describeForConfirmation(command, resolvedCommand: resolvedCommand),
            configSourcePath: configSourcePath,
            globalConfigPath: globalConfigPath
        ) else { return }

        if let workspace = command.workspace {
            executeWorkspaceCommand(command: command, workspace: workspace, tabManager: tabManager, baseCwd: baseCwd)
        } else if let rawCommand = resolvedCommand {
            guard let terminal = tabManager.selectedWorkspace?.focusedTerminalPanel else { return }
            terminal.sendInput(sanitizeForExecution(rawCommand) + "\n")
        }
    }

    /// A recipe never runs anything directly -- after parameter substitution and the same trust
    /// gate `execute(command:...)` uses, the substituted prompt is typed into the focused
    /// terminal WITHOUT a trailing newline. The user reviews the literal text sitting in their
    /// terminal and presses Return themselves; that manual step, not the confirmation dialog
    /// alone, is what keeps attacker-influenced prompt text from firing straight at an agent.
    static func executeRecipe(
        recipe: ProgramaRecipeDefinition,
        tabManager: TabManager,
        configSourcePath: String?,
        globalConfigPath: String
    ) {
        var parameterValues: [String: String] = [:]
        if let parameters = recipe.parameters, !parameters.isEmpty {
            guard let collected = collectParameterValues(parameters, entryName: recipe.name) else { return }
            parameterValues = collected
        }

        let resolvedPrompt = substituteParameters(in: recipe.prompt, values: parameterValues)

        guard confirmIfUntrusted(
            kind: .recipe,
            confirmFlag: false,
            detail: describeForConfirmation(recipe, resolvedPrompt: resolvedPrompt),
            configSourcePath: configSourcePath,
            globalConfigPath: globalConfigPath
        ) else { return }

        guard let terminal = tabManager.selectedWorkspace?.focusedTerminalPanel else { return }
        guard insertRecipePrompt(resolvedPrompt, sendInput: terminal.sendInput) else {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "dialog.cmuxConfig.invalidRecipe.title",
                defaultValue: "Prompt Needs Correction"
            )
            alert.informativeText = String(
                localized: "dialog.cmuxConfig.invalidRecipe.message",
                defaultValue: "Recipe prompts and parameter values must be a single line without control characters. Remove any line breaks, tabs, or control characters and try again. Nothing was inserted into the terminal."
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            alert.runModal()
            return
        }
    }

    @discardableResult
    static func insertRecipePrompt(_ resolvedPrompt: String, sendInput: (String) -> Void) -> Bool {
        guard !resolvedPrompt.unicodeScalars.contains(where: {
            $0.value < 0x20 || (0x7F...0x9F).contains($0.value)
                || $0.value == 0x2028 || $0.value == 0x2029
        }) else { return false }
        sendInput(resolvedPrompt)
        return true
    }

    /// The security decision, isolated from the UI so it can be tested directly.
    ///
    /// | directory | `confirm:` | prompt? |
    /// |-----------|------------|---------|
    /// | untrusted | absent     | **yes** -- this is the case that used to run silently |
    /// | untrusted | true       | yes     |
    /// | trusted   | absent     | no      |
    /// | trusted   | true       | yes -- author's "ask me anyway" marker |
    static func requiresConfirmation(confirmFlag: Bool, isTrusted: Bool) -> Bool {
        if !isTrusted { return true }
        return confirmFlag
    }

    /// Which kind of entry is being gated, purely to pick the right dialog copy. Does not change
    /// the trust decision itself -- that is entirely `requiresConfirmation`'s job.
    private enum ConfirmationKind {
        case command
        case recipe
    }

    /// The single gate in front of everything a `programa.json` can run or send. Returns false
    /// when the user declined, in which case the caller must not proceed.
    ///
    /// Trust is the app's decision, not the config file's. It previously was not: the gate ran
    /// only `if command.confirm == true`, and `confirm` is a field in the very file we are
    /// deciding whether to trust, so any config could opt out of being checked by simply
    /// omitting it. `workspace`-type commands were never gated at all, despite being able to
    /// carry an arbitrary `command` and `env` per surface. Between them, cloning a repo and
    /// picking a plausible-looking entry out of the command palette ran arbitrary shell with no
    /// prompt. Recipes are the same shape of risk with a different payload: a cloned repo could
    /// ship a recipe whose prompt text is chosen by an attacker and fired at the user's coding
    /// agent, so they go through this exact same gate rather than a parallel path.
    ///
    /// Now:
    ///  - untrusted directory: always confirm, whatever the file says, for every entry type;
    ///  - trusted directory: run, unless the author set `confirm: true`, which stays meaningful
    ///    as a "this one is destructive, ask me anyway" marker (commands only -- recipes have no
    ///    `confirm` field and always pass `confirmFlag: false`, since they never auto-submit);
    ///  - no source path: the global config at `~/.config/programa/`, which the user wrote
    ///    themselves. `ProgramaDirectoryTrust.isTrusted` already treats it as trusted, and
    ///    `ProgramaConfigSourceTrackingTests` pins the invariant that local commands and recipes
    ///    always carry a source path, so nil really does mean global.
    private static func confirmIfUntrusted(
        kind: ConfirmationKind,
        confirmFlag: Bool,
        detail: String,
        configSourcePath: String?,
        globalConfigPath: String
    ) -> Bool {
        // No source path means the global config in ~/.config/programa, written by the user.
        let trustState: ProgramaDirectoryTrust.TrustState = configSourcePath.map {
            ProgramaDirectoryTrust.shared.trustState(configPath: $0, globalConfigPath: globalConfigPath)
        } ?? .trusted
        let trusted = trustState == .trusted
        let configChanged = trustState == .changed

        guard configChanged || requiresConfirmation(confirmFlag: confirmFlag, isTrusted: trusted) else {
            return true
        }

        let title: String
        let messageFormat: String
        let affirmativeButtonTitle: String
        switch kind {
        case .command:
            title = String(
                localized: "dialog.cmuxConfig.confirmCommand.title",
                defaultValue: "Run Command"
            )
            messageFormat = String(
                localized: "dialog.cmuxConfig.confirmCommand.messageWithCommand",
                defaultValue: "This will run the following command:\n\n%@"
            )
            affirmativeButtonTitle = String(
                localized: "dialog.cmuxConfig.confirmCommand.run",
                defaultValue: "Run"
            )
        case .recipe:
            title = String(
                localized: "dialog.cmuxConfig.confirmRecipe.title",
                defaultValue: "Insert Prompt"
            )
            // Single literal, not a `+` expression: `defaultValue` takes a
            // `String.LocalizationValue`, which only accepts a literal.
            messageFormat = String(
                localized: "dialog.cmuxConfig.confirmRecipe.messageWithPrompt",
                defaultValue: "This will insert the following prompt into the focused terminal (it will not be sent until you press Return):\n\n%@"
            )
            affirmativeButtonTitle = String(
                localized: "dialog.cmuxConfig.confirmRecipe.insert",
                defaultValue: "Insert"
            )
        }

        return showConfirmDialog(
            title: title,
            messageFormat: messageFormat,
            affirmativeButtonTitle: affirmativeButtonTitle,
            detail: detail,
            configPath: trusted ? nil : configSourcePath,
            configChanged: configChanged
        )
    }

    /// Human-readable summary of everything a command would run, for the confirmation dialog.
    /// A `workspace` command can spawn several surfaces each with its own shell command, so
    /// showing only the workspace name would hide exactly the part worth reviewing.
    ///
    /// `resolvedCommand`, when supplied, is the parameter-substituted `command` text and is
    /// shown instead of the raw template -- substitution happens before this is ever called, so
    /// the user consents to the actual final string, never to a template still containing
    /// `{{name}}`. Callers that have no parameters to substitute simply omit it and this falls
    /// back to `command.command` unchanged, preserving prior behavior exactly.
    ///
    /// Internal rather than private so `ProgramaConfigConsentDisclosureTests` can assert the
    /// exact text the user is shown. What this returns *is* the security boundary: the gate
    /// only obtains meaningful consent if this discloses everything the entry would do.
    static func describeForConfirmation(_ command: ProgramaCommandDefinition, resolvedCommand: String? = nil) -> String {
        if let rawCommand = resolvedCommand ?? command.command {
            return sanitizeForDisplay(rawCommand)
        }

        guard let workspace = command.workspace else {
            return sanitizeForDisplay(command.name)
        }

        let workspaceName = workspace.name ?? command.name
        var lines = [String(
            format: String(
                localized: "dialog.cmuxConfig.confirmCommand.workspaceSummary",
                defaultValue: "Open workspace \"%@\""
            ),
            sanitizeForDisplay(workspaceName)
        )]

        let surfaceLines = workspace.layout.map(surfaceDescriptions(in:)) ?? []
        if surfaceLines.isEmpty {
            return lines[0]
        }
        lines.append("")
        lines.append(contentsOf: surfaceLines.map { "  " + $0 })
        return lines.joined(separator: "\n")
    }

    /// Human-readable summary of a recipe for the confirmation dialog: the fully
    /// parameter-substituted prompt, never the recipe's name and never its `{{name}}` template.
    static func describeForConfirmation(_ recipe: ProgramaRecipeDefinition, resolvedPrompt: String) -> String {
        sanitizeForDisplay(resolvedPrompt)
    }

    /// Every observable thing a layout's surfaces would do, depth-first in layout order.
    ///
    /// A surface with no `command` can still run code: `env` reaches the process
    /// unfiltered (only Programa's own `PROGRAMA_*` identity keys are protected, see
    /// `protectedStartupEnvironmentKeys` in TerminalSurface.swift), so `ZDOTDIR` /
    /// `BASH_ENV` / `ENV` set here execute a repo-controlled shell startup file the
    /// moment the surface spawns. Filtering surfaces down to "has a command" -- as this
    /// function used to -- let such a surface contribute nothing to the dialog, so the
    /// user would approve a workspace the dialog claimed ran nothing. Every surface that
    /// sets `command`, `cwd`, or `env` must produce a visible line.
    private static func surfaceDescriptions(in node: ProgramaLayoutNode) -> [String] {
        switch node {
        case let .pane(pane):
            return pane.surfaces.compactMap(describeSurface)
        case let .split(split):
            return split.children.flatMap(surfaceDescriptions(in:))
        }
    }

    /// Human-readable summary of one surface's observable effects, or nil if it does
    /// nothing (no command, cwd, or env). Every attacker-controlled string is sanitized
    /// individually before composition.
    private static func describeSurface(_ surface: ProgramaSurfaceDefinition) -> String? {
        var parts: [String] = []

        if let command = surface.command, !command.isEmpty {
            parts.append(sanitizeForDisplay(command))
        }
        if let cwd = surface.cwd, !cwd.isEmpty {
            parts.append("cwd=" + sanitizeForDisplay(cwd))
        }
        if let env = surface.env, !env.isEmpty {
            let pairs = env.keys.sorted().map { key in
                "\(sanitizeForDisplay(key))=\(sanitizeForDisplay(env[key] ?? ""))"
            }
            parts.append("env: " + pairs.joined(separator: " "))
        }

        guard !parts.isEmpty else { return nil }

        if let name = surface.name, !name.isEmpty {
            return "\(sanitizeForDisplay(name)): \(parts.joined(separator: "  "))"
        }
        return parts.joined(separator: "  ")
    }

    /// Show a confirmation dialog with the command text and, when `configPath` is non-nil, a
    /// "trust this directory" checkbox. Returns true if the user chose to proceed.
    ///
    /// `configPath` is nil when the directory is already trusted and we are only here because
    /// the author marked this entry `confirm: true`. Offering "always trust this folder" there
    /// would be misleading -- the folder is already trusted, and ticking it would not stop the
    /// prompt, because a `confirm: true` entry is meant to ask every time.
    private static func showConfirmDialog(
        title: String,
        messageFormat: String,
        affirmativeButtonTitle: String,
        detail: String,
        configPath: String?,
        configChanged: Bool = false
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        // `detail` is already the fully composed, per-component-sanitized summary from
        // `describeForConfirmation` -- re-running sanitizeForDisplay on the whole string here
        // would collapse the real newlines between entries that the caller relies on to keep
        // each surface on its own line.
        var informativeText = String(format: messageFormat, detail)
        if configChanged {
            let changedWarning = String(
                localized: "dialog.cmuxConfig.confirmCommand.configChanged",
                defaultValue: "This folder's programa.json has changed since you trusted it."
            )
            informativeText = changedWarning + "\n\n" + informativeText
        }
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: affirmativeButtonTitle)
        alert.addButton(withTitle: String(
            localized: "dialog.cmuxConfig.confirmCommand.cancel",
            defaultValue: "Cancel"
        ))

        var checkbox: NSButton?
        if configPath != nil {
            let box = NSButton(checkboxWithTitle: String(
                localized: "dialog.cmuxConfig.confirmCommand.trustDirectory",
                defaultValue: "Always trust commands from this folder"
            ), target: nil, action: nil)
            box.state = .off
            alert.accessoryView = box
            checkbox = box
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return false }

        if let configPath, checkbox?.state == .on {
            ProgramaDirectoryTrust.shared.trust(configPath: configPath)
        }

        return true
    }

    /// Prompts once per declared parameter, in declaration order, via a simple `NSAlert` with an
    /// `NSTextField` accessory. Returns nil (aborting the whole run) if the user cancels at any
    /// point -- a partially-collected set of values must never be used to substitute and run.
    private static func collectParameterValues(
        _ parameters: [ProgramaParameterDefinition],
        entryName: String
    ) -> [String: String]? {
        guard !parameters.isEmpty else { return [:] }

        var values: [String: String] = [:]
        let sanitizedEntryName = sanitizeForDisplay(entryName)

        for parameter in parameters {
            let label = sanitizeForDisplay(parameter.prompt ?? parameter.name)

            let alert = NSAlert()
            alert.messageText = label
            alert.informativeText = String.localizedStringWithFormat(
                String(
                    localized: "dialog.cmuxConfig.parameter.message",
                    defaultValue: "Enter a value for \"%@\"."
                ),
                sanitizedEntryName
            )
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(
                localized: "dialog.cmuxConfig.parameter.continue",
                defaultValue: "Continue"
            ))
            alert.addButton(withTitle: String(
                localized: "dialog.cmuxConfig.confirmCommand.cancel",
                defaultValue: "Cancel"
            ))

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.stringValue = parameter.default ?? ""
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            values[parameter.name] = field.stringValue
        }

        return values
    }

    /// Replaces every `{{name}}` occurrence in `template` with `values[name]`. A `{{...}}` whose
    /// inner name matches no entry in `values` (i.e. no declared parameter) is left literal --
    /// including its braces -- rather than errored or stripped, so an author's unrelated use of
    /// double braces in a command/prompt is never silently mangled.
    static func substituteParameters(in template: String, values: [String: String]) -> String {
        guard !values.isEmpty, template.contains("{{") else { return template }
        guard let regex = try? NSRegularExpression(pattern: "\\{\\{([^{}]*)\\}\\}") else { return template }

        let nsTemplate = template as NSString
        let fullRange = NSRange(location: 0, length: nsTemplate.length)
        var result = ""
        var lastEnd = 0

        for match in regex.matches(in: template, range: fullRange) {
            let matchRange = match.range
            result += nsTemplate.substring(with: NSRange(location: lastEnd, length: matchRange.location - lastEnd))

            let name = nsTemplate.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if let value = values[name] {
                result += value
            } else {
                result += nsTemplate.substring(with: matchRange)
            }
            lastEnd = matchRange.location + matchRange.length
        }
        result += nsTemplate.substring(from: lastEnd)
        return result
    }

    /// Max characters kept from a single attacker-controlled value before truncating. Bounds
    /// how much text one value can contribute to the dialog, so a crafted string can't push
    /// the rest of the summary out of `NSAlert.informativeText`'s non-scrolling area or pad
    /// itself with fake trailing "system" text. This only bounds a single value -- callers
    /// still join multiple sanitized values with real newlines to build the full summary.
    private static let maxDisplayValueLength = 200

    /// Scalars that can make displayed text lie about itself: zero-width joiners and the
    /// bidi override/isolate family, which can visually reorder a command so the dangerous
    /// part renders somewhere harmless.
    private static let dangerousScalars: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
        "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
        "\u{FEFF}",
    ]

    private static func strippingDangerousScalars(_ text: String) -> String {
        String(text.unicodeScalars.filter { !dangerousScalars.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What actually gets typed into the terminal. Strips the spoofing scalars and trims, and
    /// does NOTHING else.
    ///
    /// This must never collapse newlines or truncate. `sanitizeForDisplay` grew both of those
    /// to stop a crafted value from flooding the confirmation dialog, but `execute` was also
    /// running the *display* sanitizer over the command on its way to the shell -- so from
    /// 3f97866968 until this fix, any command over 200 characters was silently truncated and
    /// executed with "… (truncated)" appended to it. Display hardening and execution hygiene
    /// are different jobs; they get different functions.
    /// Internal rather than private so `ProgramaConfigExecutionSanitizerTests` can pin that it
    /// never truncates. That is the whole point of it existing separately.
    static func sanitizeForExecution(_ text: String) -> String {
        strippingDangerousScalars(text)
    }

    /// What the confirmation dialog shows. Bounded on purpose: a value with thousands of
    /// characters or embedded newlines could otherwise push the real payload out of
    /// `NSAlert`'s non-scrolling text area, or fake trailing UI copy.
    ///
    /// The truncation marker is deliberately visible -- a user who sees it knows there is more
    /// they are not being shown and can decline. That is a weaker guarantee than full
    /// disclosure, but a bounded and *signposted* one, which running a silently truncated
    /// command was not.
    private static func sanitizeForDisplay(_ text: String) -> String {
        // Collapse newlines WITHIN this single value -- the composed multi-line summary
        // still needs real newlines BETWEEN entries, which callers add after this returns.
        let collapsed = strippingDangerousScalars(text).replacingOccurrences(
            of: "[\\r\\n]+",
            with: " ",
            options: .regularExpression
        )
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count > maxDisplayValueLength else { return trimmed }
        let truncationMarker = String(
            localized: "dialog.cmuxConfig.confirmCommand.truncated",
            defaultValue: "… (truncated)"
        )
        return trimmed.prefix(maxDisplayValueLength) + truncationMarker
    }

    private static func executeWorkspaceCommand(
        command: ProgramaCommandDefinition,
        workspace wsDef: ProgramaWorkspaceDefinition,
        tabManager: TabManager,
        baseCwd: String
    ) {
        let workspaceName = wsDef.name ?? command.name
        let restart = command.restart ?? .ignore

        if let existing = tabManager.tabs.first(where: { $0.customTitle == workspaceName }) {
            switch restart {
            case .ignore:
                tabManager.selectWorkspace(existing)
                return
            case .recreate:
                tabManager.closeWorkspace(existing)
            case .confirm:
                let alert = NSAlert()
                alert.messageText = String(
                    localized: "dialog.cmuxConfig.confirmRestart.title",
                    defaultValue: "Workspace Already Exists"
                )
                alert.informativeText = String(
                    localized: "dialog.cmuxConfig.confirmRestart.message",
                    defaultValue: "A workspace with this name already exists. Close it and create a new one?"
                )
                alert.alertStyle = .warning
                alert.addButton(withTitle: String(localized: "dialog.cmuxConfig.confirmRestart.recreate", defaultValue: "Recreate"))
                alert.addButton(withTitle: String(localized: "dialog.cmuxConfig.confirmRestart.cancel", defaultValue: "Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else {
                    tabManager.selectWorkspace(existing)
                    return
                }
                tabManager.closeWorkspace(existing)
            }
        }

        let resolvedCwd = ProgramaConfigStore.resolveCwd(wsDef.cwd, relativeTo: baseCwd)
        let newWorkspace = tabManager.addWorkspace(workingDirectory: resolvedCwd)
        newWorkspace.setCustomTitle(workspaceName)
        if let color = wsDef.color {
            newWorkspace.setCustomColor(color)
        }

        guard let layout = wsDef.layout else { return }
        newWorkspace.applyCustomLayout(layout, baseCwd: resolvedCwd)
    }
}
