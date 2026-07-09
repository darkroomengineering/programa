package main

import "strings"

// --- Special key translation ---

func tmuxSpecialKeyText(token string) string {
	switch strings.ToLower(token) {
	case "enter", "c-m", "kpenter":
		return "\r"
	case "tab", "c-i":
		return "\t"
	case "space":
		return " "
	case "bspace", "backspace":
		return "\x7f"
	case "escape", "esc", "c-[":
		return "\x1b"
	case "c-c":
		return "\x03"
	case "c-d":
		return "\x04"
	case "c-z":
		return "\x1a"
	case "c-l":
		return "\x0c"
	default:
		return ""
	}
}

func tmuxSendKeysText(tokens []string, literal bool) string {
	if literal {
		return strings.Join(tokens, " ")
	}
	var result strings.Builder
	pendingSpace := false
	for _, token := range tokens {
		if special := tmuxSpecialKeyText(token); special != "" {
			result.WriteString(special)
			pendingSpace = false
			continue
		}
		if pendingSpace {
			result.WriteByte(' ')
		}
		result.WriteString(token)
		pendingSpace = true
	}
	return result.String()
}

func tmuxShellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func tmuxShellCommandText(positional []string, cwd string) string {
	cwd = strings.TrimSpace(cwd)
	cmd := strings.TrimSpace(strings.Join(positional, " "))
	if cwd == "" && cmd == "" {
		return ""
	}
	var pieces []string
	if cwd != "" {
		pieces = append(pieces, "cd -- "+tmuxShellQuote(cwd))
	}
	if cmd != "" {
		pieces = append(pieces, cmd)
	}
	return strings.Join(pieces, " && ") + "\r"
}
