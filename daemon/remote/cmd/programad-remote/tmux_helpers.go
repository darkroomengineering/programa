package main

import (
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
		if focused, _ := surf["focused"].(bool); focused {
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
