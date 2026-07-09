package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// --- TmuxCompatStore (local JSON state) ---

type mainVerticalState struct {
	MainSurfaceId       string `json:"mainSurfaceId"`
	LastColumnSurfaceId string `json:"lastColumnSurfaceId,omitempty"`
}

type tmuxCompatStore struct {
	Buffers             map[string]string            `json:"buffers,omitempty"`
	Hooks               map[string]string            `json:"hooks,omitempty"`
	MainVerticalLayouts map[string]mainVerticalState `json:"mainVerticalLayouts,omitempty"`
	LastSplitSurface    map[string]string            `json:"lastSplitSurface,omitempty"`
}

func tmuxCompatStoreURL() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".programaterm", "tmux-compat-store.json")
}

func loadTmuxCompatStore() tmuxCompatStore {
	data, err := os.ReadFile(tmuxCompatStoreURL())
	if err != nil {
		return tmuxCompatStore{
			Buffers:             make(map[string]string),
			Hooks:               make(map[string]string),
			MainVerticalLayouts: make(map[string]mainVerticalState),
			LastSplitSurface:    make(map[string]string),
		}
	}
	var store tmuxCompatStore
	if err := json.Unmarshal(data, &store); err != nil {
		return tmuxCompatStore{
			Buffers:             make(map[string]string),
			Hooks:               make(map[string]string),
			MainVerticalLayouts: make(map[string]mainVerticalState),
			LastSplitSurface:    make(map[string]string),
		}
	}
	if store.Buffers == nil {
		store.Buffers = make(map[string]string)
	}
	if store.Hooks == nil {
		store.Hooks = make(map[string]string)
	}
	if store.MainVerticalLayouts == nil {
		store.MainVerticalLayouts = make(map[string]mainVerticalState)
	}
	if store.LastSplitSurface == nil {
		store.LastSplitSurface = make(map[string]string)
	}
	return store
}

func saveTmuxCompatStore(store tmuxCompatStore) error {
	path := tmuxCompatStoreURL()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	data, err := json.Marshal(store)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}

func tmuxPruneCompatWorkspaceState(workspaceId string) error {
	store := loadTmuxCompatStore()
	changed := false
	if _, ok := store.MainVerticalLayouts[workspaceId]; ok {
		delete(store.MainVerticalLayouts, workspaceId)
		changed = true
	}
	if _, ok := store.LastSplitSurface[workspaceId]; ok {
		delete(store.LastSplitSurface, workspaceId)
		changed = true
	}
	if changed {
		return saveTmuxCompatStore(store)
	}
	return nil
}

func tmuxPruneCompatSurfaceState(workspaceId string, surfaceId string) error {
	store := loadTmuxCompatStore()
	changed := false
	if lastSplit := store.LastSplitSurface[workspaceId]; lastSplit == surfaceId {
		delete(store.LastSplitSurface, workspaceId)
		changed = true
	}
	if layout, ok := store.MainVerticalLayouts[workspaceId]; ok {
		if layout.MainSurfaceId == surfaceId {
			delete(store.MainVerticalLayouts, workspaceId)
			delete(store.LastSplitSurface, workspaceId)
			changed = true
		} else if layout.LastColumnSurfaceId == surfaceId {
			layout.LastColumnSurfaceId = ""
			store.MainVerticalLayouts[workspaceId] = layout
			changed = true
		}
	}
	if changed {
		return saveTmuxCompatStore(store)
	}
	return nil
}
