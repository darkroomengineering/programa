package main

import (
	"fmt"
	"os"
	"strings"
)

// --- Target resolution ---

func tmuxCallerWorkspaceHandle() string {
	return strings.TrimSpace(os.Getenv("PROGRAMA_WORKSPACE_ID"))
}

func tmuxCallerSurfaceHandle() string {
	return strings.TrimSpace(os.Getenv("PROGRAMA_SURFACE_ID"))
}

func tmuxResolvedCallerWorkspaceId(rc *rpcContext) string {
	caller := tmuxCallerWorkspaceHandle()
	if caller == "" {
		return ""
	}
	wsId, err := tmuxResolveWorkspaceId(rc, caller)
	if err != nil {
		return ""
	}
	return wsId
}

func tmuxCallerPaneHandle() string {
	for _, key := range []string{"TMUX_PANE", "PROGRAMA_PANE_ID"} {
		v := strings.TrimSpace(os.Getenv(key))
		if v != "" {
			return strings.TrimPrefix(v, "%")
		}
	}
	return ""
}

func tmuxWorkspaceItems(rc *rpcContext) ([]map[string]any, error) {
	payload, err := rc.call("workspace.list", nil)
	if err != nil {
		return nil, err
	}
	items, _ := payload["workspaces"].([]any)
	var result []map[string]any
	for _, item := range items {
		if m, ok := item.(map[string]any); ok {
			result = append(result, m)
		}
	}
	return result, nil
}

func isUUIDish(s string) bool {
	// Simple UUID check: 8-4-4-4-12 hex
	if len(s) != 36 {
		return false
	}
	for i, c := range s {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
		} else if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return false
		}
	}
	return true
}

func tmuxResolveWorkspaceId(rc *rpcContext, raw string) (string, error) {
	if raw == "" || raw == "current" {
		if caller := tmuxCallerWorkspaceHandle(); caller != "" {
			if isUUIDish(caller) {
				return caller, nil
			}
			// Resolve ref
			return tmuxResolveWorkspaceId(rc, caller)
		}
		payload, err := rc.call("workspace.current", nil)
		if err != nil {
			return "", fmt.Errorf("no workspace selected: %w", err)
		}
		if wsId, ok := payload["workspace_id"].(string); ok {
			return wsId, nil
		}
		return "", fmt.Errorf("no workspace selected")
	}

	if isUUIDish(raw) {
		return raw, nil
	}

	// Try to resolve as ref or index
	items, err := tmuxWorkspaceItems(rc)
	if err != nil {
		return "", err
	}
	for _, item := range items {
		if ref, _ := item["ref"].(string); ref == raw {
			if id, _ := item["id"].(string); id != "" {
				return id, nil
			}
		}
	}

	// Try name match
	needle := strings.TrimSpace(raw)
	for _, item := range items {
		title, _ := item["title"].(string)
		if strings.TrimSpace(title) == needle {
			if id, _ := item["id"].(string); id != "" {
				return id, nil
			}
		}
	}

	return "", fmt.Errorf("workspace not found: %s", raw)
}

func tmuxResolveWorkspaceTarget(rc *rpcContext, raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		if caller := tmuxCallerWorkspaceHandle(); caller != "" {
			return tmuxResolveWorkspaceId(rc, caller)
		}
		return tmuxResolveWorkspaceId(rc, "")
	}

	if raw == "!" || raw == "^" || raw == "-" {
		payload, err := rc.call("workspace.last", nil)
		if err != nil {
			return "", fmt.Errorf("previous workspace not found: %w", err)
		}
		if wsId, ok := payload["workspace_id"].(string); ok {
			return wsId, nil
		}
		return "", fmt.Errorf("previous workspace not found")
	}

	// Strip session:window.pane format
	token := raw
	if dot := strings.LastIndex(token, "."); dot >= 0 {
		token = token[:dot]
	}
	if colon := strings.LastIndex(token, ":"); colon >= 0 {
		suffix := token[colon+1:]
		if suffix != "" {
			token = suffix
		} else {
			token = token[:colon]
		}
	}
	token = strings.TrimPrefix(token, "@")

	return tmuxResolveWorkspaceId(rc, token)
}

func tmuxPaneSelector(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if strings.HasPrefix(raw, "%") {
		return raw[1:]
	}
	if strings.HasPrefix(raw, "pane:") {
		return raw
	}
	if dot := strings.LastIndex(raw, "."); dot >= 0 {
		return raw[dot+1:]
	}
	return ""
}

func tmuxWindowSelector(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if strings.HasPrefix(raw, "%") || strings.HasPrefix(raw, "pane:") {
		return ""
	}
	if dot := strings.LastIndex(raw, "."); dot >= 0 {
		return raw[:dot]
	}
	return raw
}

func tmuxCanonicalPaneId(rc *rpcContext, handle string, workspaceId string) (string, error) {
	if isUUIDish(handle) {
		return handle, nil
	}
	payload, err := rc.call("pane.list", map[string]any{"workspace_id": workspaceId})
	if err != nil {
		return "", err
	}
	panes, _ := payload["panes"].([]any)
	for _, p := range panes {
		pane, _ := p.(map[string]any)
		if pane == nil {
			continue
		}
		if ref, _ := pane["ref"].(string); ref == handle {
			if id, _ := pane["id"].(string); id != "" {
				return id, nil
			}
		}
		if id, _ := pane["id"].(string); id == handle {
			return id, nil
		}
	}
	return "", fmt.Errorf("pane not found: %s", handle)
}

func tmuxCanonicalSurfaceId(rc *rpcContext, handle string, workspaceId string) (string, error) {
	payload, err := rc.call("surface.list", map[string]any{"workspace_id": workspaceId})
	if err != nil {
		return "", err
	}
	surfaces, _ := payload["surfaces"].([]any)
	for _, s := range surfaces {
		surface, _ := s.(map[string]any)
		if surface == nil {
			continue
		}
		if ref, _ := surface["ref"].(string); ref == handle {
			if id, _ := surface["id"].(string); id != "" {
				return id, nil
			}
		}
		if id, _ := surface["id"].(string); id == handle {
			return id, nil
		}
	}
	return "", fmt.Errorf("surface not found: %s", handle)
}

func tmuxFocusedPaneId(rc *rpcContext, workspaceId string) (string, error) {
	payload, err := rc.call("surface.current", map[string]any{"workspace_id": workspaceId})
	if err != nil {
		return "", err
	}
	if pid, ok := payload["pane_id"].(string); ok {
		return pid, nil
	}
	if pref, ok := payload["pane_ref"].(string); ok {
		return tmuxCanonicalPaneId(rc, pref, workspaceId)
	}
	return "", fmt.Errorf("pane not found")
}

func tmuxWorkspaceIdForPaneHandle(rc *rpcContext, handle string) (string, error) {
	if !isUUIDish(handle) {
		return "", fmt.Errorf("not a UUID")
	}
	workspaces, err := tmuxWorkspaceItems(rc)
	if err != nil {
		return "", err
	}
	for _, ws := range workspaces {
		wsId, _ := ws["id"].(string)
		if wsId == "" {
			continue
		}
		payload, err := rc.call("pane.list", map[string]any{"workspace_id": wsId})
		if err != nil {
			continue
		}
		panes, _ := payload["panes"].([]any)
		for _, p := range panes {
			pane, _ := p.(map[string]any)
			if pane == nil {
				continue
			}
			if pid, _ := pane["id"].(string); pid == handle {
				return wsId, nil
			}
			if pref, _ := pane["ref"].(string); pref == handle {
				return wsId, nil
			}
		}
	}
	return "", fmt.Errorf("pane not found in any workspace")
}

func tmuxResolvePaneTarget(rc *rpcContext, raw string) (workspaceId string, paneId string, err error) {
	raw = strings.TrimSpace(raw)
	paneSelector := tmuxPaneSelector(raw)
	windowSelector := tmuxWindowSelector(raw)

	if windowSelector != "" {
		workspaceId, err = tmuxResolveWorkspaceTarget(rc, windowSelector)
		if err != nil {
			return "", "", err
		}
	} else if paneSelector != "" {
		workspaceId, err = tmuxWorkspaceIdForPaneHandle(rc, paneSelector)
		if err != nil {
			workspaceId, err = tmuxResolveWorkspaceTarget(rc, "")
			if err != nil {
				return "", "", err
			}
		}
	} else {
		workspaceId, err = tmuxResolveWorkspaceTarget(rc, "")
		if err != nil {
			return "", "", err
		}
	}

	if paneSelector != "" {
		paneId, err = tmuxCanonicalPaneId(rc, paneSelector, workspaceId)
		if err != nil {
			return "", "", err
		}
	} else if callerWs := tmuxResolvedCallerWorkspaceId(rc); callerWs == workspaceId {
		if callerPane := tmuxCallerPaneHandle(); callerPane != "" {
			if pid, err2 := tmuxCanonicalPaneId(rc, callerPane, workspaceId); err2 == nil {
				paneId = pid
			}
		}
	}

	if paneId == "" {
		paneId, err = tmuxFocusedPaneId(rc, workspaceId)
		if err != nil {
			return "", "", err
		}
	}
	return workspaceId, paneId, nil
}

func tmuxSelectedSurfaceId(rc *rpcContext, workspaceId string, paneId string) (string, error) {
	payload, err := rc.call("pane.surfaces", map[string]any{"workspace_id": workspaceId, "pane_id": paneId})
	if err != nil {
		return "", err
	}
	surfaces, _ := payload["surfaces"].([]any)
	for _, s := range surfaces {
		surface, _ := s.(map[string]any)
		if surface == nil {
			continue
		}
		if sel, _ := surface["selected"].(bool); sel {
			if id, _ := surface["id"].(string); id != "" {
				return id, nil
			}
		}
	}
	// Fall back to first surface
	if len(surfaces) > 0 {
		if surface, ok := surfaces[0].(map[string]any); ok {
			if id, _ := surface["id"].(string); id != "" {
				return id, nil
			}
		}
	}
	return "", fmt.Errorf("pane has no surface")
}

func tmuxResolveSurfaceTarget(rc *rpcContext, raw string) (workspaceId string, paneId string, surfaceId string, err error) {
	raw = strings.TrimSpace(raw)

	if tmuxPaneSelector(raw) != "" {
		workspaceId, paneId, err = tmuxResolvePaneTarget(rc, raw)
		if err != nil {
			return "", "", "", err
		}
		// When target pane matches caller's pane, prefer caller's surface
		callerPane := tmuxCallerPaneHandle()
		callerSurface := tmuxCallerSurfaceHandle()
		if callerPane != "" && callerSurface != "" {
			canonicalCallerPane, _ := tmuxCanonicalPaneId(rc, callerPane, workspaceId)
			if paneId == callerPane || paneId == canonicalCallerPane {
				surfaceId, err = tmuxCanonicalSurfaceId(rc, callerSurface, workspaceId)
				if err == nil {
					return
				}
			}
		}
		surfaceId, err = tmuxSelectedSurfaceId(rc, workspaceId, paneId)
		return
	}

	winSel := tmuxWindowSelector(raw)
	workspaceId, err = tmuxResolveWorkspaceTarget(rc, winSel)
	if err != nil {
		return "", "", "", err
	}

	// When no explicit target and caller workspace matches, use caller's surface
	if winSel == "" {
		if callerWs := tmuxResolvedCallerWorkspaceId(rc); callerWs == workspaceId {
			if callerSurface := tmuxCallerSurfaceHandle(); callerSurface != "" {
				surfaceId, err = tmuxCanonicalSurfaceId(rc, callerSurface, workspaceId)
				if err == nil {
					return
				}
			}
		}
	}

	// Fall back to focused surface
	payload, err := rc.call("surface.current", map[string]any{"workspace_id": workspaceId})
	if err == nil {
		if sid, ok := payload["surface_id"].(string); ok {
			surfaceId = sid
			return
		}
	}

	// Last resort: first surface in the workspace
	surfPayload, err := rc.call("surface.list", map[string]any{"workspace_id": workspaceId})
	if err == nil {
		surfs, _ := surfPayload["surfaces"].([]any)
		for _, s := range surfs {
			surf, _ := s.(map[string]any)
			if surf == nil {
				continue
			}
			if focused, _ := surf["focused"].(bool); focused {
				if id, _ := surf["id"].(string); id != "" {
					surfaceId = id
					return workspaceId, "", surfaceId, nil
				}
			}
		}
		if len(surfs) > 0 {
			if surf, ok := surfs[0].(map[string]any); ok {
				if id, _ := surf["id"].(string); id != "" {
					surfaceId = id
					return workspaceId, "", surfaceId, nil
				}
			}
		}
	}

	return "", "", "", fmt.Errorf("unable to resolve surface")
}

type tmuxSplitAnchor struct {
	targetSurfaceId string
	callerSurfaceId string
	direction       string
}

func tmuxAnchoredSplitTarget(rc *rpcContext, workspaceId string) *tmuxSplitAnchor {
	store := loadTmuxCompatStore()
	if mvState, ok := store.MainVerticalLayouts[workspaceId]; ok && mvState.LastColumnSurfaceId != "" {
		lastColumnId, err := tmuxCanonicalSurfaceId(rc, mvState.LastColumnSurfaceId, workspaceId)
		if err == nil {
			return &tmuxSplitAnchor{
				targetSurfaceId: lastColumnId,
				callerSurfaceId: "",
				direction:       "down",
			}
		}

		// Right-column anchors can outlive the pane they pointed at.
		// Drop stale state and rebuild from the caller surface instead.
		mvState.LastColumnSurfaceId = ""
		store.MainVerticalLayouts[workspaceId] = mvState
		delete(store.LastSplitSurface, workspaceId)
		_ = saveTmuxCompatStore(store)
	}

	candidateAnchors := []string{tmuxCallerSurfaceHandle()}
	if mvState, ok := store.MainVerticalLayouts[workspaceId]; ok && mvState.MainSurfaceId != "" {
		candidateAnchors = append(candidateAnchors, mvState.MainSurfaceId)
	}
	for _, candidate := range candidateAnchors {
		if candidate == "" {
			continue
		}
		anchorSurfaceId, err := tmuxCanonicalSurfaceId(rc, candidate, workspaceId)
		if err == nil {
			return &tmuxSplitAnchor{
				targetSurfaceId: anchorSurfaceId,
				callerSurfaceId: anchorSurfaceId,
				direction:       "right",
			}
		}
	}

	if _, ok := store.MainVerticalLayouts[workspaceId]; ok {
		delete(store.MainVerticalLayouts, workspaceId)
		delete(store.LastSplitSurface, workspaceId)
		_ = saveTmuxCompatStore(store)
	}
	return nil
}
