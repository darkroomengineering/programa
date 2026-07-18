package main

import (
	"encoding/json"
	"fmt"
	"hash/fnv"
	"os"
	"path/filepath"
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
		"session_name":      "programa",
		"session_id":        "$" + tmuxStableNumericId(canonicalWsId),
		"session_attached":  "1",
		"window_id":         "@" + tmuxStableNumericId(canonicalWsId),
		"window_uuid":       canonicalWsId,
		"window_active":     "0",
		"window_flags":      "",
		"window_width":      "80",
		"window_height":     "24",
		"pane_active":       "1",
		"pane_width":        "80",
		"pane_height":       "24",
		"pane_current_path": tmuxFallbackCurrentPath(),
	}
	activeWorkspaceId := tmuxActiveWorkspaceId(rc)
	activeByCaller := activeWorkspaceId == canonicalWsId
	if activeByCaller {
		tmuxSetWindowActive(ctx, true)
	}

	// Get workspace list for index/title
	workspaces, err := tmuxWorkspaceItems(rc)
	if err == nil {
		for _, ws := range workspaces {
			wsId, _ := ws["id"].(string)
			wsRef, _ := ws["ref"].(string)
			if wsId == canonicalWsId || wsRef == workspaceId {
				if active, ok := boolFromAnyGo(ws["active"]); ok && !activeByCaller {
					tmuxSetWindowActive(ctx, active)
				} else if focused, ok := boolFromAnyGo(ws["focused"]); ok && !activeByCaller {
					tmuxSetWindowActive(ctx, focused)
				} else if selected, ok := boolFromAnyGo(ws["selected"]); ok && !activeByCaller {
					tmuxSetWindowActive(ctx, selected)
				}
				if idx := intFromAnyGo(ws["index"]); idx >= 0 {
					ctx["window_index"] = fmt.Sprintf("%d", idx)
				}
				if title, _ := ws["title"].(string); strings.TrimSpace(title) != "" {
					ctx["window_name"] = strings.TrimSpace(title)
				}
				if path := tmuxPathFromObject(ws); path != "" {
					ctx["pane_current_path"] = path
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

	resolvedPaneId := ""
	if paneId != "" {
		if pid, err := tmuxCanonicalPaneId(rc, paneId, canonicalWsId); err == nil {
			resolvedPaneId = pid
		} else {
			resolvedPaneId = paneId
		}
	}
	if resolvedPaneId == "" {
		if pid, ok := currentPayload["pane_id"].(string); ok {
			resolvedPaneId = pid
		} else if pref, ok := currentPayload["pane_ref"].(string); ok {
			if pid, err := tmuxCanonicalPaneId(rc, pref, canonicalWsId); err == nil {
				resolvedPaneId = pid
			} else {
				resolvedPaneId = pref
			}
		}
	}

	resolvedSurfaceId := ""
	if surfaceId != "" {
		if sid, err := tmuxCanonicalSurfaceId(rc, surfaceId, canonicalWsId); err == nil {
			resolvedSurfaceId = sid
		} else {
			resolvedSurfaceId = surfaceId
		}
	}
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
		ctx["pane_id"] = "%" + tmuxStableNumericId(resolvedPaneId)
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
					if focused, ok := boolFromAnyGo(pane["focused"]); ok {
						if focused {
							ctx["pane_active"] = "1"
						} else {
							ctx["pane_active"] = "0"
						}
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
					if path := tmuxPathFromObject(surface); path != "" {
						ctx["pane_current_path"] = path
					}
					break
				}
			}
		}
	}

	return ctx, nil
}

func tmuxEnrichContextWithGeometry(ctx map[string]string, pane map[string]any, containerFrame map[string]any) {
	isFocused, _ := boolFromAnyGo(pane["focused"])
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

// tmuxStableNumericId hashes a canonical UUID/ref into a small positive
// decimal string so tmux-compat can emit ids that look like real tmux
// numeric ids ($0, @3, %12) instead of leaking the raw UUID or (worse)
// hardcoding the same literal for every session/window/pane. The hash is
// stable across calls for the same input, so a script that reads
// #{pane_id} and later selects on it with -t will resolve back to the
// same pane via tmuxNumericIdMatches.
func tmuxStableNumericId(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		raw = "programa"
	}
	h := fnv.New64a()
	_, _ = h.Write([]byte(raw))
	value := h.Sum64() & 0x7fffffffffffffff
	if value == 0 {
		value = 1
	}
	return fmt.Sprintf("%d", value)
}

// tmuxSetWindowActive sets window_active/window_flags to reflect real
// focus state instead of the old hardcoded "always active" values.
func tmuxSetWindowActive(ctx map[string]string, active bool) {
	if active {
		ctx["window_active"] = "1"
		ctx["window_flags"] = "*"
	} else {
		ctx["window_active"] = "0"
		ctx["window_flags"] = ""
	}
}

// tmuxNormalizePath expands ~ and resolves relative paths to an absolute,
// cleaned path. Returns "" if it cannot produce an absolute path.
func tmuxNormalizePath(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if strings.HasPrefix(raw, "~/") || raw == "~" {
		if home, err := os.UserHomeDir(); err == nil && home != "" {
			if raw == "~" {
				raw = home
			} else {
				raw = filepath.Join(home, raw[2:])
			}
		}
	}
	if !filepath.IsAbs(raw) {
		if abs, err := filepath.Abs(raw); err == nil {
			raw = abs
		}
	}
	if filepath.IsAbs(raw) {
		return filepath.Clean(raw)
	}
	return ""
}

func tmuxFirstPath(values ...string) string {
	for _, value := range values {
		if path := tmuxNormalizePath(value); path != "" {
			return path
		}
	}
	return ""
}

// tmuxPathFromObject pulls a working-directory-ish path off a
// workspace/pane/surface RPC payload item, trying the field names programa
// actually populates.
func tmuxPathFromObject(item map[string]any) string {
	if item == nil {
		return ""
	}
	return tmuxFirstPath(
		stringFromAnyGo(item["pane_current_path"]),
		stringFromAnyGo(item["current_directory"]),
		stringFromAnyGo(item["requested_working_directory"]),
		stringFromAnyGo(item["working_directory"]),
		stringFromAnyGo(item["cwd"]),
	)
}

// tmuxFallbackCurrentPath returns a best-effort absolute path to use as
// pane_current_path when nothing more specific is available.
func tmuxFallbackCurrentPath() string {
	if path := tmuxNormalizePath(os.Getenv("PWD")); path != "" {
		return path
	}
	if cwd, err := os.Getwd(); err == nil {
		if path := tmuxNormalizePath(cwd); path != "" {
			return path
		}
	}
	if home, err := os.UserHomeDir(); err == nil {
		if path := tmuxNormalizePath(home); path != "" {
			return path
		}
	}
	return "/"
}
