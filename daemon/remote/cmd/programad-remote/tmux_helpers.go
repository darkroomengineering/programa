package main

import (
	"encoding/json"
	"fmt"
	"strings"
)

// --- Helpers ---

func tmuxGetFirstSurface(rc *rpcContext, workspaceId string) (string, error) {
	payload, err := rc.call("surface.list", map[string]any{"workspace_id": workspaceId})
	if err != nil {
		return "", err
	}
	surfaces, _ := payload["surfaces"].([]any)
	if len(surfaces) == 0 {
		return "", fmt.Errorf("workspace has no surfaces")
	}
	// Prefer focused surface
	for _, s := range surfaces {
		surf, _ := s.(map[string]any)
		if focused, _ := boolFromAnyGo(surf["focused"]); focused {
			if id, _ := surf["id"].(string); id != "" {
				return id, nil
			}
		}
	}
	if surf, ok := surfaces[0].(map[string]any); ok {
		if id, _ := surf["id"].(string); id != "" {
			return id, nil
		}
	}
	return "", fmt.Errorf("workspace has no surfaces")
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

func parseInt(s string) int {
	s = strings.TrimSpace(s)
	var n int
	fmt.Sscanf(s, "%d", &n)
	return n
}

func parseFloat(s string) float64 {
	s = strings.TrimSpace(s)
	var f float64
	fmt.Sscanf(s, "%f", &f)
	return f
}

// boolFromAnyGo normalizes RPC-payload boolean fields that may arrive as a
// native bool, a stringy "1"/"true"/"yes"/"on" (or "0"/"false"/"no"/"off"),
// or a numeric 0/1. The second return value reports whether v was
// recognized as a boolean at all, so callers can distinguish "false" from
// "field absent".
func boolFromAnyGo(v any) (bool, bool) {
	switch t := v.(type) {
	case bool:
		return t, true
	case string:
		switch strings.ToLower(strings.TrimSpace(t)) {
		case "1", "true", "yes", "on":
			return true, true
		case "0", "false", "no", "off":
			return false, true
		}
	case float64:
		if t == 0 {
			return false, true
		}
		if t == 1 {
			return true, true
		}
	case int:
		if t == 0 {
			return false, true
		}
		if t == 1 {
			return true, true
		}
	case json.Number:
		i, err := t.Int64()
		if err == nil && (i == 0 || i == 1) {
			return i == 1, true
		}
	}
	return false, false
}

// stringFromAnyGo extracts a trimmed string from an RPC payload field,
// returning "" if the field is missing or not a string.
func stringFromAnyGo(value any) string {
	if s, ok := value.(string); ok {
		return strings.TrimSpace(s)
	}
	return ""
}
