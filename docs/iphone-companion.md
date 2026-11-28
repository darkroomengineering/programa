# iPhone companion

Programa for iPhone sends coding tasks to Programa on an awake Mac. The Mac creates a Git
worktree for each conversation, runs Claude Code there, and saves the conversation. A reply
continues the Claude session for that worktree. The iPhone can reconnect over cellular through
an Iroh relay. The connection is encrypted between the iPhone and Mac.

## Build the pilot

- Build the Mac app with `./scripts/reload.sh --tag ios-cellular` and open the tagged app.
- On the iPhone, use a development build of the `Programa` scheme in the generated iOS project.
  Generate it with `xcodegen generate --spec ios/project.yml`. Open
  `ios/Programa.xcodeproj` in Xcode, select a development signing team and a connected iPhone,
  then run the scheme. The iPhone requires iOS 26 or later.
- Sign in to Claude Code on the Mac. The pilot expects Claude Code 2.1.332 or later with support
  for `--restricted` and `--permission-prompts none`.

## Pair and send a task

1. On the Mac, open **File → iPhone Companion**. Select the Git checkout and Claude Code
   executable, then enable the companion and generate a pairing code.
2. On the iPhone, open Programa and scan the Mac's QR code or paste the pairing link. The code
   expires after five minutes and enrolls one phone. Use the Mac pairing window to revoke access.
3. Start a task with **New Chat**. Start a second conversation for independent work. Replies in
   an existing conversation use that conversation's worktree and Claude session.
4. After a reply appears, use the conversation's workspace link to find the worktree on the
   Mac. In that workspace, choose **Open Review Panel** from the command palette for the diff.

The Mac continues running a task when the iPhone app closes. Reopen the conversation to fetch
its latest messages. If Programa quits mid-turn, the worktree stays on disk and the conversation
shows it was interrupted. Start a new conversation to run more work after inspecting the
interrupted worktree. Disabling access revokes the phone. Jobs stay visible in their worktrees
on the Mac and remain private to the phone identity that created them.

The pilot gives the Claude worker file tools scoped to its worktree. Shell commands, browser
automation, remote permission buttons, and iOS push notifications are outside the pilot.
The relay sees routing metadata such as IP addresses and timing.

## Verify cellular on device

With the Mac on its normal network and the iPhone's Wi-Fi switched off, pair the phone, start
two jobs, and confirm they open two worktrees. Reply to one, confirm only that conversation
changes, then use its workspace link to find its diff on the Mac. Relaunch the iPhone app and
confirm both conversations return. Revoke the phone on the Mac and confirm the iPhone loses access.
