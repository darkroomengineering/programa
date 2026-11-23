use programa_domain::{
    Command, Core, LayoutNode, Pane, Snapshot, SplitDirection, Surface, Workspace,
};

fn create_workspace() -> Command {
    Command::CreateWorkspace {
        workspace_id: "workspace-a".into(),
        pane_id: "pane-a".into(),
        surface_id: "surface-a".into(),
        session_id: "session-a".into(),
        placement: Default::default(),
    }
}

fn add_surface(core: &mut Core, suffix: &str) {
    core.dispatch(Command::CreateSurface {
        workspace_id: "workspace-a".into(),
        pane_id: "pane-a".into(),
        surface_id: format!("surface-{suffix}"),
        session_id: format!("session-{suffix}"),
    })
    .unwrap();
}

#[test]
fn workspace_lifecycle_updates_selection_and_revision() {
    let mut core = Core::default();
    core.dispatch(create_workspace()).unwrap();
    assert_eq!(core.snapshot().revision, 1);
    assert_eq!(
        core.snapshot().selected_workspace_id.as_deref(),
        Some("workspace-a")
    );
    core.dispatch(Command::CloseWorkspace {
        workspace_id: "workspace-a".into(),
    })
    .unwrap();
    assert_eq!(core.snapshot().revision, 2);
    assert!(core.snapshot().workspaces.is_empty());
}

#[test]
fn closing_final_surface_closes_final_workspace() {
    let mut core = Core::default();
    core.dispatch(create_workspace()).unwrap();
    core.dispatch(Command::CloseSurface {
        workspace_id: "workspace-a".into(),
        pane_id: "pane-a".into(),
        surface_id: "surface-a".into(),
    })
    .unwrap();

    assert_eq!(core.snapshot().revision, 2);
    assert!(core.snapshot().workspaces.is_empty());
    assert_eq!(core.snapshot().selected_workspace_id, None);
}

#[test]
fn reorder_matches_insert_before_and_preserves_session_and_selection() {
    let mut core = Core::default();
    core.dispatch(create_workspace()).unwrap();
    add_surface(&mut core, "b");
    add_surface(&mut core, "c");
    core.dispatch(Command::ReorderSurface {
        workspace_id: "workspace-a".into(),
        pane_id: "pane-a".into(),
        surface_id: "surface-a".into(),
        before_surface_id: Some("surface-c".into()),
    })
    .unwrap();
    let pane = &core.snapshot().workspaces[0].panes[0];
    assert_eq!(
        pane.surfaces
            .iter()
            .map(|surface| surface.id.as_str())
            .collect::<Vec<_>>(),
        ["surface-b", "surface-a", "surface-c"]
    );
    assert_eq!(pane.surfaces[1].session_id, "session-a");
    assert_eq!(pane.selected_surface_id, "surface-c");
}

#[test]
fn reorder_clamps_pinned_and_unpinned_surfaces_at_boundary() {
    let mut core = Core::default();
    core.dispatch(Command::SeedSnapshot {
        snapshot: Snapshot {
            abi_version: 1,
            revision: 40,
            selected_workspace_id: Some("workspace-a".into()),
            workspaces: vec![Workspace {
                title: None,
                pinned: false,
                color: None,
                description: None,
                parent_id: None,
                collapsed: false,
                worktree_repo: None,
                id: "workspace-a".into(),
                selected_pane_id: "pane-a".into(),
                panes: vec![Pane {
                    id: "pane-a".into(),
                    selected_surface_id: "surface-pinned".into(),
                    surfaces: vec![
                        Surface {
                            id: "surface-pinned".into(),
                            session_id: "session-pinned".into(),
                            is_pinned: true,
                            title: None,
                        },
                        Surface {
                            id: "surface-a".into(),
                            session_id: "session-a".into(),
                            is_pinned: false,
                            title: None,
                        },
                        Surface {
                            id: "surface-tail".into(),
                            session_id: "session-tail".into(),
                            is_pinned: false,
                            title: None,
                        },
                    ],
                }],
                layout: LayoutNode::Pane {
                    pane_id: "pane-a".into(),
                },
            }],
        },
    })
    .unwrap();

    core.dispatch(Command::ReorderSurface {
        workspace_id: "workspace-a".into(),
        pane_id: "pane-a".into(),
        surface_id: "surface-tail".into(),
        before_surface_id: Some("surface-pinned".into()),
    })
    .unwrap();
    let revision_after_unpinned_move = core.snapshot().revision;
    core.dispatch(Command::ReorderSurface {
        workspace_id: "workspace-a".into(),
        pane_id: "pane-a".into(),
        surface_id: "surface-pinned".into(),
        before_surface_id: None,
    })
    .unwrap();

    let pane = &core.snapshot().workspaces[0].panes[0];
    assert_eq!(
        pane.surfaces
            .iter()
            .map(|surface| surface.id.as_str())
            .collect::<Vec<_>>(),
        ["surface-pinned", "surface-tail", "surface-a"]
    );
    assert_eq!(pane.selected_surface_id, "surface-pinned");
    assert_eq!(pane.surfaces[0].session_id, "session-pinned");
    assert_eq!(core.snapshot().revision, revision_after_unpinned_move);
}

#[test]
fn reorder_rejects_target_from_another_pane_without_mutation() {
    let mut core = Core::default();
    core.dispatch(create_workspace()).unwrap();
    core.dispatch(Command::SplitPane {
        workspace_id: "workspace-a".into(),
        pane_id: "pane-a".into(),
        split_id: "split-a".into(),
        new_pane_id: "pane-b".into(),
        new_surface_id: "surface-b".into(),
        session_id: "session-b".into(),
        direction: SplitDirection::Horizontal,
        ratio: 0.5,
        insert_first: false,
    })
    .unwrap();
    let before = core.snapshot().clone();
    assert!(core
        .dispatch(Command::ReorderSurface {
            workspace_id: "workspace-a".into(),
            pane_id: "pane-a".into(),
            surface_id: "surface-a".into(),
            before_surface_id: Some("surface-b".into()),
        })
        .is_err());
    assert_eq!(core.snapshot(), &before);
}

#[test]
fn split_and_resize_retain_existing_session() {
    let mut core = Core::default();
    core.dispatch(create_workspace()).unwrap();
    core.dispatch(Command::SplitPane {
        workspace_id: "workspace-a".into(),
        pane_id: "pane-a".into(),
        split_id: "split-a".into(),
        new_pane_id: "pane-b".into(),
        new_surface_id: "surface-b".into(),
        session_id: "session-b".into(),
        direction: SplitDirection::Vertical,
        ratio: 0.4,
        insert_first: false,
    })
    .unwrap();
    core.dispatch(Command::ResizeSplit {
        workspace_id: "workspace-a".into(),
        split_id: "split-a".into(),
        ratio: 0.6,
    })
    .unwrap();
    let workspace = &core.snapshot().workspaces[0];
    assert_eq!(workspace.panes[0].surfaces[0].session_id, "session-a");
    assert_eq!(workspace.selected_pane_id, "pane-b");
    assert!(matches!(
        workspace.layout,
        LayoutNode::Split {
            direction: SplitDirection::Vertical,
            ratio,
            ..
        } if ratio == 0.6
    ));
}

#[test]
fn a_split_to_the_left_puts_the_new_pane_first_with_the_same_share() {
    let mut core = Core::default();
    core.dispatch(create_workspace()).unwrap();
    core.dispatch(Command::SplitPane {
        workspace_id: "workspace-a".into(),
        pane_id: "pane-a".into(),
        split_id: "split-a".into(),
        new_pane_id: "pane-b".into(),
        new_surface_id: "surface-b".into(),
        session_id: "session-b".into(),
        direction: SplitDirection::Vertical,
        ratio: 0.7,
        insert_first: true,
    })
    .unwrap();
    let workspace = &core.snapshot().workspaces[0];
    assert_eq!(workspace.selected_pane_id, "pane-b");
    match &workspace.layout {
        LayoutNode::Split {
            ratio,
            first,
            second,
            ..
        } => {
            assert!((ratio - 0.3).abs() < 1e-9);
            assert_eq!(
                **first,
                LayoutNode::Pane {
                    pane_id: "pane-b".into()
                }
            );
            assert_eq!(
                **second,
                LayoutNode::Pane {
                    pane_id: "pane-a".into()
                }
            );
        }
        other => panic!("expected a split, got {other:?}"),
    }
}

#[test]
fn closing_final_surface_in_pane_collapses_split_and_selects_neighbor() {
    let mut core = Core::default();
    core.dispatch(create_workspace()).unwrap();
    core.dispatch(Command::SplitPane {
        workspace_id: "workspace-a".into(),
        pane_id: "pane-a".into(),
        split_id: "split-a".into(),
        new_pane_id: "pane-b".into(),
        new_surface_id: "surface-b".into(),
        session_id: "session-b".into(),
        direction: SplitDirection::Horizontal,
        ratio: 0.5,
        insert_first: false,
    })
    .unwrap();
    core.dispatch(Command::CloseSurface {
        workspace_id: "workspace-a".into(),
        pane_id: "pane-b".into(),
        surface_id: "surface-b".into(),
    })
    .unwrap();

    let workspace = &core.snapshot().workspaces[0];
    assert_eq!(workspace.selected_pane_id, "pane-a");
    assert_eq!(workspace.panes.len(), 1);
    assert_eq!(workspace.panes[0].surfaces[0].session_id, "session-a");
    assert_eq!(
        workspace.layout,
        LayoutNode::Pane {
            pane_id: "pane-a".into()
        }
    );
}

#[test]
fn move_surface_collapses_empty_source_and_preserves_full_surface() {
    let mut core = Core::default();
    core.dispatch(create_workspace()).unwrap();
    core.dispatch(Command::SplitPane {
        workspace_id: "workspace-a".into(),
        pane_id: "pane-a".into(),
        split_id: "split-a".into(),
        new_pane_id: "pane-b".into(),
        new_surface_id: "surface-b".into(),
        session_id: "session-b".into(),
        direction: SplitDirection::Vertical,
        ratio: 0.4,
        insert_first: false,
    })
    .unwrap();
    core.dispatch(Command::SeedSnapshot {
        snapshot: {
            let mut snapshot = core.snapshot().clone();
            snapshot.workspaces[0].panes[0].surfaces[0].is_pinned = true;
            snapshot
        },
    })
    .unwrap();

    core.dispatch(Command::MoveSurface {
        workspace_id: "workspace-a".into(),
        source_pane_id: "pane-a".into(),
        target_pane_id: "pane-b".into(),
        surface_id: "surface-a".into(),
        before_surface_id: None,
    })
    .unwrap();

    let workspace = &core.snapshot().workspaces[0];
    assert_eq!(workspace.selected_pane_id, "pane-b");
    assert_eq!(workspace.panes.len(), 1);
    assert_eq!(
        workspace.layout,
        LayoutNode::Pane {
            pane_id: "pane-b".into()
        }
    );
    let target = &workspace.panes[0];
    assert_eq!(target.selected_surface_id, "surface-a");
    assert_eq!(
        target
            .surfaces
            .iter()
            .map(|surface| surface.id.as_str())
            .collect::<Vec<_>>(),
        ["surface-a", "surface-b"]
    );
    assert_eq!(target.surfaces[0].session_id, "session-a");
    assert!(target.surfaces[0].is_pinned);
}

#[test]
fn move_surface_same_pane_reorders_and_selects_moved_surface() {
    let mut core = Core::default();
    core.dispatch(create_workspace()).unwrap();
    add_surface(&mut core, "b");

    core.dispatch(Command::MoveSurface {
        workspace_id: "workspace-a".into(),
        source_pane_id: "pane-a".into(),
        target_pane_id: "pane-a".into(),
        surface_id: "surface-a".into(),
        before_surface_id: None,
    })
    .unwrap();

    let pane = &core.snapshot().workspaces[0].panes[0];
    assert_eq!(pane.selected_surface_id, "surface-a");
    assert_eq!(
        pane.surfaces
            .iter()
            .map(|surface| surface.id.as_str())
            .collect::<Vec<_>>(),
        ["surface-b", "surface-a"]
    );
    assert_eq!(pane.surfaces[1].session_id, "session-a");
}

#[test]
fn new_workspaces_go_where_the_placement_says_after_pinned_ones_and_past_worktree_children() {
    use programa_domain::WorkspacePlacement::{AfterCurrent, End, Top};
    let mut core = Core::default();
    let mut add = |core: &mut Core, name: &str, placement| {
        core.dispatch(Command::CreateWorkspace {
            workspace_id: format!("w-{name}"),
            pane_id: format!("p-{name}"),
            surface_id: format!("s-{name}"),
            session_id: format!("session-{name}"),
            placement,
        })
        .unwrap();
    };
    let order = |core: &Core| {
        core.snapshot()
            .workspaces
            .iter()
            .map(|w| w.id.trim_start_matches("w-").to_owned())
            .collect::<Vec<_>>()
            .join(" ")
    };
    add(&mut core, "a", End);
    add(&mut core, "b", End);
    add(&mut core, "c", End);
    core.dispatch(Command::SetWorkspacePinned {
        workspace_id: "w-a".into(),
        pinned: true,
    })
    .unwrap();
    core.dispatch(Command::SetWorkspaceParent {
        workspace_id: "w-c".into(),
        parent_id: Some("w-b".into()),
    })
    .unwrap();
    core.dispatch(Command::SelectWorkspace {
        workspace_id: "w-b".into(),
    })
    .unwrap();
    // After b's worktree child, not between them; the new one is selected.
    add(&mut core, "d", AfterCurrent);
    assert_eq!(order(&core), "a b c d");
    add(&mut core, "e", Top);
    assert_eq!(order(&core), "a e b c d");
    core.dispatch(Command::SelectWorkspace {
        workspace_id: "w-a".into(),
    })
    .unwrap();
    add(&mut core, "f", AfterCurrent);
    assert_eq!(order(&core), "a f e b c d");
}

#[test]
fn move_surface_rejects_target_pane_in_another_workspace_without_mutation() {
    let mut core = Core::default();
    core.dispatch(create_workspace()).unwrap();
    core.dispatch(Command::CreateWorkspace {
        workspace_id: "workspace-b".into(),
        pane_id: "pane-b".into(),
        surface_id: "surface-b".into(),
        session_id: "session-b".into(),
        placement: Default::default(),
    })
    .unwrap();
    let before = core.snapshot().clone();

    let error = core
        .dispatch(Command::MoveSurface {
            workspace_id: "workspace-a".into(),
            source_pane_id: "pane-a".into(),
            target_pane_id: "pane-b".into(),
            surface_id: "surface-a".into(),
            before_surface_id: None,
        })
        .unwrap_err();

    assert_eq!(error.code(), "not_found");
    assert_eq!(core.snapshot(), &before);
}

#[test]
fn no_op_does_not_advance_revision() {
    let mut core = Core::default();
    core.dispatch(create_workspace()).unwrap();
    core.dispatch(Command::SelectWorkspace {
        workspace_id: "workspace-a".into(),
    })
    .unwrap();
    core.dispatch(Command::ReorderSurface {
        workspace_id: "workspace-a".into(),
        pane_id: "pane-a".into(),
        surface_id: "surface-a".into(),
        before_surface_id: None,
    })
    .unwrap();
    assert_eq!(core.snapshot().revision, 1);
}

#[test]
fn seed_validates_snapshot_and_uses_local_monotonic_revision() {
    let mut core = Core::default();
    let seeded = Snapshot {
        abi_version: 1,
        revision: 99,
        selected_workspace_id: Some("workspace-a".into()),
        workspaces: vec![Workspace {
            title: None,
            pinned: false,
            color: None,
            description: None,
            parent_id: None,
            collapsed: false,
            worktree_repo: None,
            id: "workspace-a".into(),
            selected_pane_id: "pane-a".into(),
            panes: vec![Pane {
                id: "pane-a".into(),
                selected_surface_id: "surface-a".into(),
                surfaces: vec![Surface {
                    id: "surface-a".into(),
                    session_id: "mac-uuid".into(),
                    is_pinned: true,
                    title: None,
                }],
            }],
            layout: LayoutNode::Pane {
                pane_id: "pane-a".into(),
            },
        }],
    };
    core.dispatch(Command::SeedSnapshot { snapshot: seeded })
        .unwrap();
    assert_eq!(core.snapshot().revision, 1);
    assert_eq!(
        core.snapshot().workspaces[0].panes[0].surfaces[0].session_id,
        "mac-uuid"
    );
}

#[test]
fn rename_workspace_sets_trims_and_clears_the_title() {
    let mut core = Core::default();
    core.dispatch(create_workspace()).unwrap();
    let rename = |title: Option<&str>| Command::RenameWorkspace {
        workspace_id: "workspace-a".into(),
        title: title.map(Into::into),
    };

    core.dispatch(rename(Some("  api  "))).unwrap();
    assert_eq!(core.snapshot().workspaces[0].title.as_deref(), Some("api"));
    assert_eq!(core.snapshot().revision, 2);

    // Same title: a valid no-op that keeps the revision.
    core.dispatch(rename(Some("api"))).unwrap();
    assert_eq!(core.snapshot().revision, 2);

    // Blank clears it.
    core.dispatch(rename(Some("   "))).unwrap();
    assert_eq!(core.snapshot().workspaces[0].title, None);

    let missing = core.dispatch(Command::RenameWorkspace {
        workspace_id: "nope".into(),
        title: None,
    });
    assert_eq!(missing.unwrap_err().code(), "not_found");
}

#[test]
fn rename_surface_sets_and_clears_the_tab_title() {
    let mut core = Core::default();
    core.dispatch(create_workspace()).unwrap();
    let rename = |title: Option<&str>| Command::RenameSurface {
        workspace_id: "workspace-a".into(),
        pane_id: "pane-a".into(),
        surface_id: "surface-a".into(),
        title: title.map(Into::into),
    };
    let title = |core: &Core| {
        core.snapshot().workspaces[0].panes[0].surfaces[0]
            .title
            .clone()
    };

    core.dispatch(rename(Some(" server "))).unwrap();
    assert_eq!(title(&core).as_deref(), Some("server"));
    core.dispatch(rename(None)).unwrap();
    assert_eq!(title(&core), None);
    let missing = core.dispatch(Command::RenameSurface {
        workspace_id: "workspace-a".into(),
        pane_id: "pane-a".into(),
        surface_id: "nope".into(),
        title: None,
    });
    assert_eq!(missing.unwrap_err().code(), "not_found");
}

#[test]
fn pinned_workspaces_stay_on_top_and_moves_keep_their_group() {
    let mut core = Core::default();
    for name in ["a", "b", "c", "d"] {
        core.dispatch(Command::CreateWorkspace {
            workspace_id: format!("workspace-{name}"),
            pane_id: format!("pane-{name}"),
            surface_id: format!("surface-{name}"),
            session_id: format!("session-{name}"),
            placement: Default::default(),
        })
        .unwrap();
    }
    let order = |core: &Core| {
        core.snapshot()
            .workspaces
            .iter()
            .map(|w| w.id.trim_start_matches("workspace-").to_owned())
            .collect::<String>()
    };
    let pin = |id: &str, pinned| Command::SetWorkspacePinned {
        workspace_id: format!("workspace-{id}"),
        pinned,
    };
    core.dispatch(pin("c", true)).unwrap();
    core.dispatch(pin("d", true)).unwrap();
    assert_eq!(order(&core), "cdab");
    let revision = core.snapshot().revision;
    core.dispatch(pin("d", true)).unwrap();
    assert_eq!(core.snapshot().revision, revision);

    // A pinned workspace stays among the pinned; an unpinned one never passes them.
    let move_to = |id: &str, index| Command::MoveWorkspace {
        workspace_id: format!("workspace-{id}"),
        index,
    };
    core.dispatch(move_to("d", 9)).unwrap();
    assert_eq!(order(&core), "cdab");
    core.dispatch(move_to("b", 0)).unwrap();
    assert_eq!(order(&core), "cdba");
    core.dispatch(pin("c", false)).unwrap();
    assert_eq!(order(&core), "dcba");
}

#[test]
fn workspace_color_and_description_validate_and_clear() {
    let mut core = Core::default();
    core.dispatch(create_workspace()).unwrap();
    let color = |value: Option<&str>| Command::SetWorkspaceColor {
        workspace_id: "workspace-a".into(),
        color: value.map(Into::into),
    };
    core.dispatch(color(Some("#c0392b"))).unwrap();
    assert_eq!(
        core.snapshot().workspaces[0].color.as_deref(),
        Some("#C0392B")
    );
    assert_eq!(
        core.dispatch(color(Some("red"))).unwrap_err().code(),
        "invalid_color"
    );
    core.dispatch(color(Some(" "))).unwrap();
    assert_eq!(core.snapshot().workspaces[0].color, None);

    core.dispatch(Command::SetWorkspaceDescription {
        workspace_id: "workspace-a".into(),
        description: Some(" api server ".into()),
    })
    .unwrap();
    assert_eq!(
        core.snapshot().workspaces[0].description.as_deref(),
        Some("api server")
    );
}

#[test]
fn an_adopted_workspace_keeps_its_ids_and_is_selected() {
    let mut source = Core::default();
    source.dispatch(create_workspace()).unwrap();
    let moved = source.snapshot().workspaces[0].clone();

    let mut target = Core::default();
    target
        .dispatch(Command::CreateWorkspace {
            workspace_id: "workspace-b".into(),
            pane_id: "pane-b".into(),
            surface_id: "surface-b".into(),
            session_id: "session-b".into(),
            placement: Default::default(),
        })
        .unwrap();
    target
        .dispatch(Command::AdoptWorkspace {
            workspace: moved.clone(),
        })
        .unwrap();
    let snapshot = target.snapshot();
    assert_eq!(snapshot.workspaces[1], moved);
    assert_eq!(
        snapshot.selected_workspace_id.as_deref(),
        Some("workspace-a")
    );

    // Adopting it twice would duplicate its ids.
    let again = target.dispatch(Command::AdoptWorkspace { workspace: moved });
    assert!(again.is_err());
    assert_eq!(target.snapshot().workspaces.len(), 2);
}

#[test]
fn an_adopted_surface_joins_the_pane_where_it_was_dropped_and_is_selected() {
    let mut core = Core::default();
    core.dispatch(create_workspace()).unwrap();
    let workspace = core.snapshot().workspaces[0].clone();
    let pane_id = workspace.panes[0].id.clone();
    let existing = workspace.panes[0].surfaces[0].id.clone();
    let tab = |id: &str| Surface {
        id: id.into(),
        session_id: format!("session-{id}"),
        is_pinned: false,
        title: Some("server".into()),
    };
    core.dispatch(Command::AdoptSurface {
        workspace_id: workspace.id.clone(),
        pane_id: pane_id.clone(),
        surface: tab("moved"),
        before_surface_id: Some(existing.clone()),
    })
    .unwrap();
    let pane = &core.snapshot().workspaces[0].panes[0];
    let ids: Vec<&str> = pane.surfaces.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(ids, ["moved", existing.as_str()]);
    assert_eq!(pane.selected_surface_id, "moved");
    assert_eq!(pane.surfaces[0].title.as_deref(), Some("server"));

    // Its ids must be new here.
    let again = core.dispatch(Command::AdoptSurface {
        workspace_id: workspace.id.clone(),
        pane_id,
        surface: tab("moved"),
        before_surface_id: None,
    });
    assert!(again.is_err());
    assert_eq!(core.snapshot().workspaces[0].panes[0].surfaces.len(), 2);
}

#[test]
fn worktree_children_follow_their_parent_and_open_its_folder() {
    let mut core = Core::default();
    for name in ["repo", "other", "wt1", "wt2"] {
        core.dispatch(Command::CreateWorkspace {
            workspace_id: format!("workspace-{name}"),
            pane_id: format!("pane-{name}"),
            surface_id: format!("surface-{name}"),
            session_id: format!("session-{name}"),
            placement: Default::default(),
        })
        .unwrap();
    }
    let order = |core: &Core| {
        core.snapshot()
            .workspaces
            .iter()
            .map(|w| w.id.trim_start_matches("workspace-").to_owned())
            .collect::<Vec<_>>()
            .join(",")
    };
    let nest = |child: &str, parent: Option<&str>| Command::SetWorkspaceParent {
        workspace_id: format!("workspace-{child}"),
        parent_id: parent.map(|parent| format!("workspace-{parent}")),
    };
    core.dispatch(nest("wt1", Some("repo"))).unwrap();
    core.dispatch(nest("wt2", Some("repo"))).unwrap();
    assert_eq!(order(&core), "repo,wt1,wt2,other");

    // One level deep only.
    assert_eq!(
        core.dispatch(nest("other", Some("wt1")))
            .unwrap_err()
            .code(),
        "invalid_parent"
    );
    assert_eq!(
        core.dispatch(nest("repo", Some("other")))
            .unwrap_err()
            .code(),
        "invalid_parent"
    );

    // Moving the parent carries its children.
    core.dispatch(Command::MoveWorkspace {
        workspace_id: "workspace-other".into(),
        index: 0,
    })
    .unwrap();
    assert_eq!(order(&core), "other,repo,wt1,wt2");

    // Selecting a child of a collapsed parent opens it.
    core.dispatch(Command::SetWorkspaceCollapsed {
        workspace_id: "workspace-repo".into(),
        collapsed: true,
    })
    .unwrap();
    core.dispatch(Command::SelectWorkspace {
        workspace_id: "workspace-wt1".into(),
    })
    .unwrap();
    let repo = &core.snapshot().workspaces[1];
    assert!(!repo.collapsed);

    // A child made a worktree folder leaves its parent; a folder that stops being one lets its
    // children go.
    let folder = |id: &str, repo: Option<&str>| Command::SetWorkspaceWorktreeFolder {
        workspace_id: format!("workspace-{id}"),
        repo: repo.map(str::to_owned),
    };
    core.dispatch(folder("wt2", Some(r"C:\src\repo"))).unwrap();
    assert_eq!(order(&core), "other,repo,wt1,wt2");
    let wt2 = &core.snapshot().workspaces[3];
    assert_eq!(wt2.parent_id, None);
    assert_eq!(wt2.worktree_repo.as_deref(), Some(r"C:\src\repo"));
    core.dispatch(folder("repo", Some(r"C:\src\repo"))).unwrap();
    core.dispatch(folder("repo", None)).unwrap();
    assert!(core
        .snapshot()
        .workspaces
        .iter()
        .all(|w| w.parent_id.is_none()));
    assert_eq!(core.snapshot().workspaces[1].worktree_repo, None);
    // A parent that was never made a folder lets its children go too.
    core.dispatch(nest("wt1", Some("repo"))).unwrap();
    core.dispatch(folder("repo", None)).unwrap();
    assert!(core
        .snapshot()
        .workspaces
        .iter()
        .all(|w| w.parent_id.is_none()));
    core.dispatch(nest("wt1", Some("repo"))).unwrap();

    // Closing the parent leaves its children top level.
    core.dispatch(Command::CloseWorkspace {
        workspace_id: "workspace-repo".into(),
    })
    .unwrap();
    assert!(core
        .snapshot()
        .workspaces
        .iter()
        .all(|w| w.parent_id.is_none()));
}

#[test]
fn pinning_a_tab_moves_it_after_the_pinned_ones_and_unpinning_just_after_them() {
    let mut core = Core::default();
    core.dispatch(create_workspace()).unwrap();
    add_surface(&mut core, "b");
    add_surface(&mut core, "c");
    let pin = |core: &mut Core, id: &str, pinned: bool| {
        core.dispatch(Command::SetSurfacePinned {
            workspace_id: "workspace-a".into(),
            pane_id: "pane-a".into(),
            surface_id: id.into(),
            pinned,
        })
        .unwrap();
    };
    let order = |core: &Core| -> Vec<(String, bool)> {
        core.snapshot().workspaces[0].panes[0]
            .surfaces
            .iter()
            .map(|s| (s.id.clone(), s.is_pinned))
            .collect()
    };
    pin(&mut core, "surface-c", true);
    pin(&mut core, "surface-b", true);
    assert_eq!(
        order(&core),
        [
            ("surface-c".into(), true),
            ("surface-b".into(), true),
            ("surface-a".into(), false)
        ]
    );
    let revision = core.snapshot().revision;
    pin(&mut core, "surface-b", true);
    assert_eq!(core.snapshot().revision, revision);
    pin(&mut core, "surface-c", false);
    assert_eq!(
        order(&core),
        [
            ("surface-b".into(), true),
            ("surface-c".into(), false),
            ("surface-a".into(), false)
        ]
    );
}
