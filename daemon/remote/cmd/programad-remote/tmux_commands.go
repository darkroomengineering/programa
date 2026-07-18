package main

import (
	"fmt"
	"math"
	"os"
	"strings"
	"time"
)

// --- Command implementations ---

// tmuxCreateWorkspace implements the body shared by `new-session` and
// `new-window`: create a workspace (optionally routed into the macOS window
// that owns targetWsId, mirroring tmux's "new window goes into the target's
// session"), rename it, and pipe in a shell command if one was given.
func tmuxCreateWorkspace(rc *rpcContext, p *tmuxParsed, title string, targetWsId string) (string, error) {
	params := map[string]any{"focus": false}
	if cwd := p.value("-c"); cwd != "" {
		params["cwd"] = cwd
	}
	if targetWsId != "" {
		// Route the new workspace into the same top-level window as the
		// resolved target instead of always landing in the active window.
		params["workspace_id"] = targetWsId
	}
	created, err := rc.call("workspace.create", params)
	if err != nil {
		return "", err
	}
	wsId, _ := created["workspace_id"].(string)
	if wsId == "" {
		return "", fmt.Errorf("workspace.create did not return workspace_id")
	}
	if strings.TrimSpace(title) != "" {
		rc.call("workspace.rename", map[string]any{"workspace_id": wsId, "title": title})
	}
	if text := tmuxShellCommandText(p.positional, p.value("-c")); text != "" {
		surfaceId, err := tmuxGetFirstSurface(rc, wsId)
		if err == nil {
			rc.call("surface.send_text", map[string]any{"workspace_id": wsId, "surface_id": surfaceId, "text": text})
		}
	}
	return wsId, nil
}

// tmuxPrintWorkspaceRef prints the `-P`/`-F` formatted reference for a
// newly created workspace, shared by `new-session` and `new-window`.
func tmuxPrintWorkspaceRef(rc *rpcContext, p *tmuxParsed, wsId string) {
	if !p.hasFlag("-P") {
		return
	}
	ctx, err := tmuxFormatContext(rc, wsId, "", "")
	if err != nil {
		fmt.Printf("@%s\n", wsId)
		return
	}
	fmt.Println(tmuxRenderFormat(p.value("-F"), ctx, "@"+wsId))
}

func tmuxNewSession(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-c", "-F", "-n", "-s"}, []string{"-A", "-d", "-P"})
	if p.hasFlag("-A") {
		return fmt.Errorf("new-session -A is not supported")
	}
	title := firstNonEmpty(p.value("-n"), p.value("-s"))
	wsId, err := tmuxCreateWorkspace(rc, p, title, "")
	if err != nil {
		return err
	}
	tmuxPrintWorkspaceRef(rc, p, wsId)
	return nil
}

func tmuxNewWindow(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-c", "-F", "-n", "-t"}, []string{"-d", "-P"})

	targetWsId := ""
	if raw := strings.TrimSpace(p.value("-t")); raw != "" {
		resolved, err := tmuxResolveWorkspaceTarget(rc, raw)
		if err != nil {
			return err
		}
		targetWsId = resolved
	}

	wsId, err := tmuxCreateWorkspace(rc, p, p.value("-n"), targetWsId)
	if err != nil {
		return err
	}
	tmuxPrintWorkspaceRef(rc, p, wsId)
	return nil
}

func tmuxSplitWindow(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-c", "-F", "-l", "-t"}, []string{"-P", "-b", "-d", "-h", "-v"})

	targetWs, _, targetSurface, err := tmuxResolveSurfaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}

	direction := "down"
	if p.hasFlag("-h") {
		direction = "right"
		if p.hasFlag("-b") {
			direction = "left"
		}
	} else if p.hasFlag("-b") {
		direction = "up"
	}

	// Anchor splits to the leader surface for agent teams.
	callerWorkspace := tmuxCallerWorkspaceHandle()
	anchoredCallerSurface := ""
	if callerWorkspace != "" {
		if wsId, err := tmuxResolveWorkspaceId(rc, callerWorkspace); err == nil {
			if anchored := tmuxAnchoredSplitTarget(rc, wsId); anchored != nil {
				targetWs = wsId
				targetSurface = anchored.targetSurfaceId
				direction = anchored.direction
				anchoredCallerSurface = anchored.callerSurfaceId
			}
		}
	}

	focusNewPane := !p.hasFlag("-d")
	created, err := rc.call("surface.split", map[string]any{
		"workspace_id": targetWs,
		"surface_id":   targetSurface,
		"direction":    direction,
		"focus":        focusNewPane,
	})
	if err != nil {
		return err
	}
	surfaceId, _ := created["surface_id"].(string)
	if surfaceId == "" {
		return fmt.Errorf("surface.split did not return surface_id")
	}
	newPaneId, _ := created["pane_id"].(string)

	// Track for main-vertical layout
	store := loadTmuxCompatStore()
	store.LastSplitSurface[targetWs] = surfaceId
	if _, ok := store.MainVerticalLayouts[targetWs]; ok {
		mvs := store.MainVerticalLayouts[targetWs]
		mvs.LastColumnSurfaceId = surfaceId
		store.MainVerticalLayouts[targetWs] = mvs
	} else if direction == "right" && anchoredCallerSurface != "" {
		store.MainVerticalLayouts[targetWs] = mainVerticalState{
			MainSurfaceId:       anchoredCallerSurface,
			LastColumnSurfaceId: surfaceId,
		}
	}
	saveTmuxCompatStore(store)

	// Equalize vertical splits
	rc.call("workspace.equalize_splits", map[string]any{
		"workspace_id": targetWs,
		"orientation":  "vertical",
	})

	if text := tmuxShellCommandText(p.positional, p.value("-c")); text != "" {
		rc.call("surface.send_text", map[string]any{
			"workspace_id": targetWs,
			"surface_id":   surfaceId,
			"text":         text,
		})
	}

	if p.hasFlag("-P") {
		ctx, err := tmuxFormatContext(rc, targetWs, newPaneId, surfaceId)
		if err != nil {
			fmt.Println(surfaceId)
			return nil
		}
		fallback := surfaceId
		if pid, ok := ctx["pane_id"]; ok {
			fallback = pid
		}
		fmt.Println(tmuxRenderFormat(p.value("-F"), ctx, fallback))
	}
	return nil
}

func tmuxSelectWindow(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	wsId, err := tmuxResolveWorkspaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	_, err = rc.call("workspace.select", map[string]any{"workspace_id": wsId})
	return err
}

func tmuxSelectPane(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-P", "-T", "-t"}, nil)
	// -P (style) and -T (title) are no-ops
	if p.value("-P") != "" || p.value("-T") != "" {
		return nil
	}
	wsId, paneId, err := tmuxResolvePaneTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	_, err = rc.call("pane.focus", map[string]any{"workspace_id": wsId, "pane_id": paneId})
	return err
}

func tmuxKillWindow(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	wsId, err := tmuxResolveWorkspaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	_, err = rc.call("workspace.close", map[string]any{"workspace_id": wsId})
	if err != nil {
		return err
	}
	_ = tmuxPruneCompatWorkspaceState(wsId)
	return nil
}

func tmuxKillPane(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	wsId, _, surfId, err := tmuxResolveSurfaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	_, err = rc.call("surface.close", map[string]any{"workspace_id": wsId, "surface_id": surfId})
	if err != nil {
		return err
	}
	_ = tmuxPruneCompatSurfaceState(wsId, surfId)
	// Re-equalize after removal
	rc.call("workspace.equalize_splits", map[string]any{"workspace_id": wsId, "orientation": "vertical"})
	return nil
}

func tmuxSendKeys(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, []string{"-l"})
	wsId, _, surfId, err := tmuxResolveSurfaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	text := tmuxSendKeysText(p.positional, p.hasFlag("-l"))
	if text != "" {
		_, err = rc.call("surface.send_text", map[string]any{
			"workspace_id": wsId,
			"surface_id":   surfId,
			"text":         text,
		})
	}
	return err
}

func tmuxCapturePane(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-E", "-S", "-t"}, []string{"-J", "-N", "-p"})
	wsId, _, surfId, err := tmuxResolveSurfaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	params := map[string]any{
		"workspace_id": wsId,
		"surface_id":   surfId,
		"scrollback":   true,
	}
	if start := p.value("-S"); start != "" {
		if lines := parseInt(start); lines < 0 {
			params["lines"] = int(math.Abs(float64(lines)))
		}
	}
	payload, err := rc.call("surface.read_text", params)
	if err != nil {
		return err
	}
	text, _ := payload["text"].(string)
	if p.hasFlag("-p") {
		fmt.Print(text)
	} else {
		store := loadTmuxCompatStore()
		store.Buffers["default"] = text
		saveTmuxCompatStore(store)
	}
	return nil
}

func tmuxDisplayMessage(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-F", "-t"}, []string{"-p"})
	wsId, paneId, surfId, err := tmuxResolveSurfaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	ctx, err := tmuxFormatContext(rc, wsId, paneId, surfId)
	if err != nil {
		ctx = map[string]string{}
	}

	// Enrich with geometry
	panePayload, err := rc.call("pane.list", map[string]any{"workspace_id": wsId})
	if err == nil {
		panes, _ := panePayload["panes"].([]any)
		containerFrame, _ := panePayload["container_frame"].(map[string]any)
		var matchingPane map[string]any
		if paneId != "" {
			for _, p := range panes {
				pn, _ := p.(map[string]any)
				if pid, _ := pn["id"].(string); pid == paneId {
					matchingPane = pn
					break
				}
			}
		}
		if matchingPane == nil {
			for _, p := range panes {
				pn, _ := p.(map[string]any)
				if focused, _ := boolFromAnyGo(pn["focused"]); focused {
					matchingPane = pn
					break
				}
			}
		}
		if matchingPane == nil && len(panes) > 0 {
			matchingPane, _ = panes[0].(map[string]any)
		}
		if matchingPane != nil {
			tmuxEnrichContextWithGeometry(ctx, matchingPane, containerFrame)
		}
	}

	format := p.value("-F")
	if len(p.positional) > 0 {
		format = strings.Join(p.positional, " ")
	}
	rendered := tmuxRenderFormat(format, ctx, "")
	if p.hasFlag("-p") || rendered != "" {
		fmt.Println(rendered)
	}
	return nil
}

func tmuxListWindows(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-F", "-t"}, nil)
	items, err := tmuxWorkspaceItems(rc)
	if err != nil {
		return err
	}
	for _, item := range items {
		wsId, _ := item["id"].(string)
		if wsId == "" {
			continue
		}
		ctx, err := tmuxFormatContext(rc, wsId, "", "")
		if err != nil {
			continue
		}
		fallback := ""
		if idx, ok := ctx["window_index"]; ok {
			fallback = idx
		} else {
			fallback = "?"
		}
		if name, ok := ctx["window_name"]; ok {
			fallback += " " + name
		} else {
			fallback += " " + wsId
		}
		fmt.Println(tmuxRenderFormat(p.value("-F"), ctx, fallback))
	}
	return nil
}

func tmuxListPanes(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-F", "-t"}, nil)

	target := p.value("-t")
	var wsId string
	var err error

	if target != "" && tmuxPaneSelector(target) != "" {
		wsId, _, err = tmuxResolvePaneTarget(rc, target)
	} else {
		wsId, err = tmuxResolveWorkspaceTarget(rc, target)
	}
	if err != nil {
		return err
	}

	payload, err := rc.call("pane.list", map[string]any{"workspace_id": wsId})
	if err != nil {
		return err
	}
	panes, _ := payload["panes"].([]any)
	containerFrame, _ := payload["container_frame"].(map[string]any)

	for _, p2 := range panes {
		pane, _ := p2.(map[string]any)
		if pane == nil {
			continue
		}
		paneId, _ := pane["id"].(string)
		if paneId == "" {
			continue
		}
		ctx, err := tmuxFormatContext(rc, wsId, paneId, "")
		if err != nil {
			continue
		}
		tmuxEnrichContextWithGeometry(ctx, pane, containerFrame)
		fallback := "%" + paneId
		if pid, ok := ctx["pane_id"]; ok {
			fallback = pid
		}
		fmt.Println(tmuxRenderFormat(p.value("-F"), ctx, fallback))
	}
	return nil
}

func tmuxRenameWindow(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	title := strings.TrimSpace(strings.Join(p.positional, " "))
	if title == "" {
		return fmt.Errorf("rename-window requires a title")
	}
	wsId, err := tmuxResolveWorkspaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	_, err = rc.call("workspace.rename", map[string]any{"workspace_id": wsId, "title": title})
	return err
}

func tmuxResizePane(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t", "-x", "-y"}, []string{"-D", "-L", "-R", "-U"})
	wsId, paneId, err := tmuxResolvePaneTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}

	hasDirectional := p.hasFlag("-L") || p.hasFlag("-R") || p.hasFlag("-U") || p.hasFlag("-D")

	if !hasDirectional {
		if absWidthStr := p.value("-x"); absWidthStr != "" {
			absWidth := parseInt(strings.ReplaceAll(absWidthStr, "%", ""))
			// Get current width to compute delta
			panePayload, err := rc.call("pane.list", map[string]any{"workspace_id": wsId})
			if err != nil {
				return err
			}
			panes, _ := panePayload["panes"].([]any)
			for _, pp := range panes {
				pane, _ := pp.(map[string]any)
				if pane == nil {
					continue
				}
				if pid, _ := pane["id"].(string); pid == paneId {
					cellW := intFromAnyGo(pane["cell_width_px"])
					currentCols := intFromAnyGo(pane["columns"])
					if cellW > 0 && currentCols >= 0 {
						delta := absWidth - currentCols
						if delta != 0 {
							dir := "right"
							if delta < 0 {
								dir = "left"
								delta = -delta
							}
							rc.call("pane.resize", map[string]any{
								"workspace_id": wsId,
								"pane_id":      paneId,
								"direction":    dir,
								"amount":       delta * cellW,
							})
						}
					}
					break
				}
			}
			return nil
		}
	}

	if hasDirectional {
		dir := "right"
		if p.hasFlag("-L") {
			dir = "left"
		} else if p.hasFlag("-U") {
			dir = "up"
		} else if p.hasFlag("-D") {
			dir = "down"
		}
		rawAmount := firstNonEmpty(p.value("-x"), p.value("-y"), "5")
		rawAmount = strings.ReplaceAll(rawAmount, "%", "")
		amount := parseInt(rawAmount)
		if amount <= 0 {
			amount = 5
		}
		_, err := rc.call("pane.resize", map[string]any{
			"workspace_id": wsId,
			"pane_id":      paneId,
			"direction":    dir,
			"amount":       amount,
		})
		return err
	}
	return nil
}

func tmuxWaitFor(_ *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"--timeout"}, []string{"-S"})
	name := ""
	for _, pos := range p.positional {
		if !strings.HasPrefix(pos, "-") {
			name = pos
			break
		}
	}
	if name == "" {
		return fmt.Errorf("wait-for requires a name")
	}

	signalPath := tmuxWaitForSignalPath(name)

	if p.hasFlag("-S") {
		// Signal mode: create the file
		os.WriteFile(signalPath, []byte{}, 0644)
		fmt.Println("OK")
		return nil
	}

	// Wait mode: poll for the file
	timeoutStr := p.value("--timeout")
	timeout := 30.0
	if timeoutStr != "" {
		if t := parseFloat(timeoutStr); t > 0 {
			timeout = t
		}
	}

	deadline := time.Now().Add(time.Duration(timeout * float64(time.Second)))
	for time.Now().Before(deadline) {
		if _, err := os.Stat(signalPath); err == nil {
			os.Remove(signalPath)
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("wait-for timeout: %s", name)
}

func tmuxLastPane(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	wsId, err := tmuxResolveWorkspaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	_, err = rc.call("pane.last", map[string]any{"workspace_id": wsId})
	return err
}

func tmuxHasSession(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	_, err := tmuxResolveWorkspaceTarget(rc, p.value("-t"))
	return err
}

func tmuxSelectLayout(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	layoutName := ""
	if len(p.positional) > 0 {
		layoutName = p.positional[0]
	}

	// Resolve workspace from target (may be a pane reference)
	var wsId string
	var err error
	if target := p.value("-t"); target != "" {
		if tmuxPaneSelector(target) != "" {
			wsId, _, err = tmuxResolvePaneTarget(rc, target)
		} else {
			wsId, err = tmuxResolveWorkspaceTarget(rc, target)
		}
	} else {
		wsId, err = tmuxResolveWorkspaceTarget(rc, "")
	}
	if err != nil {
		return err
	}

	if layoutName == "main-vertical" || layoutName == "main-horizontal" {
		orientation := "vertical"
		if layoutName == "main-horizontal" {
			orientation = "horizontal"
		}
		rc.call("workspace.equalize_splits", map[string]any{
			"workspace_id": wsId,
			"orientation":  orientation,
		})
	} else {
		rc.call("workspace.equalize_splits", map[string]any{"workspace_id": wsId})
	}

	if layoutName == "main-vertical" {
		if callerSurface := tmuxCallerSurfaceHandle(); callerSurface != "" {
			store := loadTmuxCompatStore()
			existingColumn := ""
			if existing, ok := store.MainVerticalLayouts[wsId]; ok {
				existingColumn = existing.LastColumnSurfaceId
			}
			seedColumn := existingColumn
			if seedColumn == "" {
				seedColumn = store.LastSplitSurface[wsId]
			}
			store.MainVerticalLayouts[wsId] = mainVerticalState{
				MainSurfaceId:       callerSurface,
				LastColumnSurfaceId: seedColumn,
			}
			saveTmuxCompatStore(store)
		}
	} else if layoutName != "" {
		_ = tmuxPruneCompatWorkspaceState(wsId)
	}

	return nil
}

func tmuxShowBuffer(args []string) error {
	p := parseTmuxArgs(args, []string{"-b"}, nil)
	name := p.value("-b")
	if name == "" {
		name = "default"
	}
	store := loadTmuxCompatStore()
	if buf, ok := store.Buffers[name]; ok {
		fmt.Print(buf)
	}
	return nil
}

func tmuxSaveBuffer(args []string) error {
	p := parseTmuxArgs(args, []string{"-b"}, nil)
	name := p.value("-b")
	if name == "" {
		name = "default"
	}
	store := loadTmuxCompatStore()
	buf, ok := store.Buffers[name]
	if !ok {
		return fmt.Errorf("buffer not found: %s", name)
	}
	if len(p.positional) > 0 {
		outputPath := strings.TrimSpace(p.positional[len(p.positional)-1])
		if outputPath != "" {
			return os.WriteFile(outputPath, []byte(buf), 0644)
		}
	}
	fmt.Print(buf)
	return nil
}
