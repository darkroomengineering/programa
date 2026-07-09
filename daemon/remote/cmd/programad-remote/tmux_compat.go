package main

import (
	"encoding/json"
	"fmt"
	"os"
)

// runTmuxCompat handles `programa __tmux-compat <args...>`, translating tmux
// commands into programa JSON-RPC calls over the relay socket.
func runTmuxCompat(socketPath string, args []string, refreshAddr func() string) int {
	command, cmdArgs, err := splitTmuxCmd(args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "programa __tmux-compat: %v\n", err)
		return 1
	}

	rc := &rpcContext{socketPath: socketPath, refreshAddr: refreshAddr}
	if err := dispatchTmuxCommand(rc, command, cmdArgs); err != nil {
		fmt.Fprintf(os.Stderr, "programa __tmux-compat: %v\n", err)
		return 1
	}
	return 0
}

// rpcContext holds connection info for making JSON-RPC calls.
type rpcContext struct {
	socketPath  string
	refreshAddr func() string
}

// call makes a JSON-RPC call and returns the parsed result.
func (rc *rpcContext) call(method string, params map[string]any) (map[string]any, error) {
	resp, err := socketRoundTripV2(rc.socketPath, method, params, rc.refreshAddr)
	if err != nil {
		return nil, err
	}
	var result map[string]any
	if err := json.Unmarshal([]byte(resp), &result); err != nil {
		// Some responses are bare values (string, null)
		return nil, nil
	}
	return result, nil
}

// --- Main dispatch ---
//
// The rest of the tmux-compat shim is split by section across this
// package: tmux_args.go (argument parsing), tmux_format.go (format
// string rendering/context), tmux_target.go (session/window/pane target
// resolution), tmux_store.go (local JSON state), tmux_keys.go (special
// key translation), tmux_waitfor.go (wait-for signaling path), tmux_commands.go
// (per-command implementations), and tmux_helpers.go (small shared helpers).

func dispatchTmuxCommand(rc *rpcContext, command string, args []string) error {
	switch command {
	case "-v", "-V":
		fmt.Println("tmux 3.4")
		return nil

	case "new-session", "new":
		return tmuxNewSession(rc, args)
	case "new-window", "neww":
		return tmuxNewWindow(rc, args)
	case "split-window", "splitw":
		return tmuxSplitWindow(rc, args)
	case "select-window", "selectw":
		return tmuxSelectWindow(rc, args)
	case "select-pane", "selectp":
		return tmuxSelectPane(rc, args)
	case "kill-window", "killw":
		return tmuxKillWindow(rc, args)
	case "kill-pane", "killp":
		return tmuxKillPane(rc, args)
	case "send-keys", "send":
		return tmuxSendKeys(rc, args)
	case "capture-pane", "capturep":
		return tmuxCapturePane(rc, args)
	case "display-message", "display", "displayp":
		return tmuxDisplayMessage(rc, args)
	case "list-windows", "lsw":
		return tmuxListWindows(rc, args)
	case "list-panes", "lsp":
		return tmuxListPanes(rc, args)
	case "rename-window", "renamew":
		return tmuxRenameWindow(rc, args)
	case "resize-pane", "resizep":
		return tmuxResizePane(rc, args)
	case "wait-for":
		return tmuxWaitFor(rc, args)
	case "last-pane":
		return tmuxLastPane(rc, args)
	case "has-session", "has":
		return tmuxHasSession(rc, args)
	case "select-layout":
		return tmuxSelectLayout(rc, args)
	case "show-buffer", "showb":
		return tmuxShowBuffer(args)
	case "save-buffer", "saveb":
		return tmuxSaveBuffer(args)

	// No-ops
	case "set-option", "set", "set-window-option", "setw", "source-file",
		"refresh-client", "attach-session", "detach-client",
		"last-window", "next-window", "previous-window",
		"set-hook", "set-buffer", "list-buffers":
		return nil

	default:
		return fmt.Errorf("unsupported tmux command: %s", command)
	}
}
