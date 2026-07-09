package main

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// --- Format string rendering ---

var tmuxFormatVarRe = regexp.MustCompile(`#\{[^}]+\}`)

func tmuxRenderFormat(format string, context map[string]string, fallback string) string {
	if format == "" {
		return fallback
	}
	rendered := format
	for key, value := range context {
		rendered = strings.ReplaceAll(rendered, "#{"+key+"}", value)
	}
	// Remove any remaining unresolved #{...} variables
	rendered = tmuxFormatVarRe.ReplaceAllString(rendered, "")
	rendered = strings.TrimSpace(rendered)
	if rendered == "" {
		return fallback
	}
	return rendered
}

// --- Format context building ---

func tmuxFormatContext(rc *rpcContext, workspaceId string, paneId string, surfaceId string) (map[string]string, error) {
	canonicalWsId, err := tmuxResolveWorkspaceId(rc, workspaceId)
	if err != nil {
		return nil, err
	}

	ctx := map[string]string{
		"session_name":  "programa",
		"session_id":    "$0",
		"window_id":     "@" + canonicalWsId,
		"window_uuid":   canonicalWsId,
		"window_active": "1",
		"window_flags":  "*",
		"pane_active":   "1",
	}

	// Get workspace list for index/title
	workspaces, err := tmuxWorkspaceItems(rc)
	if err == nil {
		for _, ws := range workspaces {
			wsId, _ := ws["id"].(string)
			wsRef, _ := ws["ref"].(string)
			if wsId == canonicalWsId || wsRef == workspaceId {
				if idx := intFromAnyGo(ws["index"]); idx >= 0 {
					ctx["window_index"] = fmt.Sprintf("%d", idx)
				}
				if title, _ := ws["title"].(string); strings.TrimSpace(title) != "" {
					ctx["window_name"] = strings.TrimSpace(title)
				}
				if paneCount := intFromAnyGo(ws["pane_count"]); paneCount >= 0 {
					ctx["window_panes"] = fmt.Sprintf("%d", paneCount)
				}
				break
			}
		}
	}

	// Get current surface info
	currentPayload, err := rc.call("surface.current", map[string]any{"workspace_id": canonicalWsId})
	if err != nil {
		return ctx, nil
	}

	resolvedPaneId := paneId
	if resolvedPaneId == "" {
		if pid, ok := currentPayload["pane_id"].(string); ok {
			resolvedPaneId = pid
		} else if pref, ok := currentPayload["pane_ref"].(string); ok {
			resolvedPaneId = pref
		}
	}

	resolvedSurfaceId := surfaceId
	if resolvedSurfaceId == "" && resolvedPaneId != "" {
		if sid, err := tmuxSelectedSurfaceId(rc, canonicalWsId, resolvedPaneId); err == nil {
			resolvedSurfaceId = sid
		}
	}
	if resolvedSurfaceId == "" {
		if sid, ok := currentPayload["surface_id"].(string); ok {
			resolvedSurfaceId = sid
		}
	}

	if resolvedPaneId != "" {
		ctx["pane_id"] = "%" + resolvedPaneId
		ctx["pane_uuid"] = resolvedPaneId

		panePayload, err := rc.call("pane.list", map[string]any{"workspace_id": canonicalWsId})
		if err == nil {
			panes, _ := panePayload["panes"].([]any)
			for _, p := range panes {
				pane, _ := p.(map[string]any)
				if pane == nil {
					continue
				}
				if pid, _ := pane["id"].(string); pid == resolvedPaneId {
					if idx := intFromAnyGo(pane["index"]); idx >= 0 {
						ctx["pane_index"] = fmt.Sprintf("%d", idx)
					}
					break
				}
			}
		}
	}

	if resolvedSurfaceId != "" {
		ctx["surface_id"] = resolvedSurfaceId
		surfacePayload, err := rc.call("surface.list", map[string]any{"workspace_id": canonicalWsId})
		if err == nil {
			surfaces, _ := surfacePayload["surfaces"].([]any)
			for _, s := range surfaces {
				surface, _ := s.(map[string]any)
				if surface == nil {
					continue
				}
				if sid, _ := surface["id"].(string); sid == resolvedSurfaceId {
					if title, _ := surface["title"].(string); strings.TrimSpace(title) != "" {
						ctx["pane_title"] = strings.TrimSpace(title)
						if _, ok := ctx["window_name"]; !ok {
							ctx["window_name"] = strings.TrimSpace(title)
						}
					}
					break
				}
			}
		}
	}

	return ctx, nil
}

func tmuxEnrichContextWithGeometry(ctx map[string]string, pane map[string]any, containerFrame map[string]any) {
	isFocused, _ := pane["focused"].(bool)
	if isFocused {
		ctx["pane_active"] = "1"
	} else {
		ctx["pane_active"] = "0"
	}

	columns := intFromAnyGo(pane["columns"])
	rows := intFromAnyGo(pane["rows"])
	if columns < 0 || rows < 0 {
		return
	}
	ctx["pane_width"] = fmt.Sprintf("%d", columns)
	ctx["pane_height"] = fmt.Sprintf("%d", rows)

	cellW := intFromAnyGo(pane["cell_width_px"])
	cellH := intFromAnyGo(pane["cell_height_px"])
	if cellW <= 0 || cellH <= 0 {
		return
	}

	if frame, ok := pane["pixel_frame"].(map[string]any); ok {
		px := floatFromAny(frame["x"])
		py := floatFromAny(frame["y"])
		ctx["pane_left"] = fmt.Sprintf("%d", int(px)/cellW)
		ctx["pane_top"] = fmt.Sprintf("%d", int(py)/cellH)
	}

	if containerFrame != nil {
		cw := floatFromAny(containerFrame["width"])
		ch := floatFromAny(containerFrame["height"])
		ww := int(cw) / cellW
		wh := int(ch) / cellH
		if ww < 1 {
			ww = 1
		}
		if wh < 1 {
			wh = 1
		}
		ctx["window_width"] = fmt.Sprintf("%d", ww)
		ctx["window_height"] = fmt.Sprintf("%d", wh)
	}
}

func floatFromAny(v any) float64 {
	switch t := v.(type) {
	case float64:
		return t
	case int:
		return float64(t)
	case json.Number:
		f, _ := t.Float64()
		return f
	}
	return 0
}

func intFromAnyGo(v any) int {
	switch t := v.(type) {
	case float64:
		return int(t)
	case int:
		return t
	case json.Number:
		i, err := t.Int64()
		if err != nil {
			return -1
		}
		return int(i)
	}
	return -1
}
