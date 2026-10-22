import Foundation

struct GitHubIssue {
    let number: Int
    let title: String
    let body: String
    let url: String
}

extension ProgramaCLI {
    func parseWorktreeIssueNumber(_ raw: String) throws -> Int {
        guard !raw.isEmpty,
              raw.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let number = Int(raw), number > 0 else {
            throw CLIError(message: "worktree create: --from-issue must be a positive issue number, got '\(raw)'")
        }
        return number
    }

    func validateWorktreeIssueAgent(_ raw: String, issueNumber: Int?) throws -> String {
        guard issueNumber != nil else {
            throw CLIError(message: "worktree create: --agent requires --from-issue <number>")
        }
        let agent = raw.lowercased()
        guard Self.raceSupportedAgents.contains(agent) else {
            throw CLIError(message: "worktree create: --agent must be one of \(Self.raceSupportedAgents.joined(separator: ", "))")
        }
        return agent
    }

    /// Runs `gh issue view` in `repo` so gh resolves the GitHub repository from that checkout's remotes.
    func fetchGitHubIssue(number: Int, repo: String) throws -> GitHubIssue {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["gh", "issue", "view", String(number), "--json", "number,title,body,url"],
            timeout: 30,
            currentDirectoryPath: repo
        )
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstErrorLine = stderr.split(separator: "\n").first.map(String.init) ?? ""
        if result.timedOut {
            throw CLIError(message: "worktree create: 'gh issue view \(number)' timed out")
        }
        // env exits 127 when it cannot find the program on PATH.
        if result.status == 127 {
            throw CLIError(message: "worktree create: --from-issue needs the GitHub CLI (gh) on PATH; install it from https://cli.github.com")
        }
        // gh exits 4 when the command needs authentication.
        if result.status == 4 || stderr.contains("gh auth login") {
            throw CLIError(message: "worktree create: gh is not logged in to GitHub; run 'gh auth login' and try again")
        }
        if stderr.contains("Could not resolve to an issue") {
            throw CLIError(message: "worktree create: issue #\(number) not found for the repository at \(repo)")
        }
        guard result.status == 0 else {
            let detail = firstErrorLine.isEmpty ? "exit status \(result.status)" : firstErrorLine
            throw CLIError(message: "worktree create: 'gh issue view \(number)' failed: \(detail)")
        }

        guard let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: "worktree create: 'gh issue view \(number)' returned unexpected output")
        }
        return GitHubIssue(
            number: (object["number"] as? Int) ?? number,
            title: title,
            body: (object["body"] as? String) ?? "",
            url: (object["url"] as? String) ?? ""
        )
    }

    /// `issue-<number>-<slug>`: the slug keeps ASCII letters and digits of the lowercased
    /// title, joins every other run of characters into one `-`, and stops at 40 characters.
    func worktreeIssueBranchName(_ issue: GitHubIssue) -> String {
        var slug = ""
        var pendingSeparator = false
        for scalar in issue.title.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingSeparator, !slug.isEmpty { slug.append("-") }
                pendingSeparator = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingSeparator = true
            }
        }
        slug = String(slug.prefix(40))
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "issue-\(issue.number)" : "issue-\(issue.number)-\(slug)"
    }

    /// The agent reads the issue from this file after the CLI exits, so the file is left in place;
    /// each new write removes prompt files older than 7 days.
    func writeWorktreeIssuePromptFile(_ issue: GitHubIssue) throws -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("programa-issue-prompts", isDirectory: true)
        let file = directory.appendingPathComponent(
            "issue-\(issue.number)-\(UUID().uuidString.prefix(8).lowercased()).md",
            isDirectory: false
        )
        let content = """
        # \(issue.title)

        GitHub issue #\(issue.number): \(issue.url)

        \(issue.body)

        """
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CLIError(message: "worktree create: could not create \(directory.path): \(error.localizedDescription)")
        }
        removeWorktreeIssuePromptFiles(in: directory, olderThan: Date().addingTimeInterval(-7 * 24 * 60 * 60))
        guard FileManager.default.createFile(
            atPath: file.path,
            contents: Data(content.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CLIError(message: "worktree create: could not write the issue prompt to \(file.path)")
        }
        return file.path
    }

    private func removeWorktreeIssuePromptFiles(in directory: URL, olderThan cutoff: Date) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return }
        for entry in entries where entry.pathExtension == "md" {
            guard let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    /// The typed command carries only the issue number and the prompt file path. The issue
    /// text is untrusted, so it reaches the agent through the file and never through the shell.
    func worktreeIssueAgentLaunchCommand(agent: String, issueNumber: Int, promptFile: String) -> String {
        let prompt = "Work on GitHub issue #\(issueNumber). Its title, link and description are in \(promptFile); read that file first."
        return raceAgentLaunchCommand(agent: agent, prompt: prompt)
    }
}
