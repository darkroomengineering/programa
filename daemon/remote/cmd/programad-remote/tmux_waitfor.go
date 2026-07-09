package main

import (
	"fmt"
	"strings"
)

// --- Wait-for (filesystem-based signaling) ---

func tmuxWaitForSignalPath(name string) string {
	var sanitized strings.Builder
	for _, c := range name {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
			c == '.' || c == '_' || c == '-' {
			sanitized.WriteRune(c)
		} else {
			sanitized.WriteByte('_')
		}
	}
	return fmt.Sprintf("/tmp/programa-wait-for-%s.sig", sanitized.String())
}
