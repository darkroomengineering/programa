package main

import (
	"fmt"
	"strings"
)

// --- Tmux argument parsing ---

type tmuxParsed struct {
	flags      map[string]bool     // boolean flags like -d, -P
	options    map[string][]string // value flags like -t <target>
	positional []string
}

func (p *tmuxParsed) hasFlag(f string) bool {
	return p.flags[f]
}

func (p *tmuxParsed) value(f string) string {
	vals := p.options[f]
	if len(vals) == 0 {
		return ""
	}
	return vals[len(vals)-1]
}

func splitTmuxCmd(args []string) (string, []string, error) {
	globalValueFlags := map[string]bool{"-L": true, "-S": true, "-f": true}
	globalBoolFlags := map[string]bool{"-V": true, "-v": true}

	i := 0
	for i < len(args) {
		arg := args[i]
		if !strings.HasPrefix(arg, "-") || arg == "-" {
			return strings.ToLower(arg), args[i+1:], nil
		}
		if arg == "--" {
			break
		}
		if globalBoolFlags[arg] {
			return arg, nil, nil
		}
		if globalValueFlags[arg] {
			// Skip the value
			i++
		}
		i++
	}
	return "", nil, fmt.Errorf("tmux shim requires a command")
}

func parseTmuxArgs(args []string, valueFlags, boolFlags []string) *tmuxParsed {
	vSet := make(map[string]bool, len(valueFlags))
	for _, f := range valueFlags {
		vSet[f] = true
	}
	bSet := make(map[string]bool, len(boolFlags))
	for _, f := range boolFlags {
		bSet[f] = true
	}

	p := &tmuxParsed{
		flags:   make(map[string]bool),
		options: make(map[string][]string),
	}
	pastTerminator := false

	for i := 0; i < len(args); i++ {
		arg := args[i]
		if pastTerminator {
			p.positional = append(p.positional, arg)
			continue
		}
		if arg == "--" {
			pastTerminator = true
			continue
		}
		if !strings.HasPrefix(arg, "-") || arg == "-" {
			p.positional = append(p.positional, arg)
			continue
		}
		if strings.HasPrefix(arg, "--") {
			p.positional = append(p.positional, arg)
			continue
		}

		// Cluster parsing: -dPh etc.
		cluster := []rune(arg[1:])
		cursor := 0
		recognized := false
		for cursor < len(cluster) {
			flag := "-" + string(cluster[cursor])
			if bSet[flag] {
				p.flags[flag] = true
				cursor++
				recognized = true
				continue
			}
			if vSet[flag] {
				remainder := string(cluster[cursor+1:])
				var value string
				if remainder != "" {
					value = remainder
				} else if i+1 < len(args) {
					i++
					value = args[i]
				}
				p.options[flag] = append(p.options[flag], value)
				recognized = true
				cursor = len(cluster)
				continue
			}
			recognized = false
			break
		}
		if !recognized {
			p.positional = append(p.positional, arg)
		}
	}
	return p
}
