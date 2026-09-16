use programa_domain::{
    Command, Core, LayoutNode, Pane, Snapshot, SplitDirection, Surface, Workspace,
};

fn create_workspace() -> Command {
    Command::CreateWorkspace {
        workspace_id: "workspace-a".into(),
        pane_id: "pane-a".into(),
        surface_id: "surface-a".into(),
        session_id: "session-a".into(),
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
                        },
                        Surface {
                            id: "surface-a".into(),
                            session_id: "session-a".into(),
                            is_pinned: false,
                        },
                        Surface {
                            id: "surface-tail".into(),
                            session_id: "session-tail".into(),
                            is_pinned: false,
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
fn move_surface_rejects_target_pane_in_another_workspace_without_mutation() {
    let mut core = Core::default();
    core.dispatch(create_workspace()).unwrap();
    core.dispatch(Command::CreateWorkspace {
        workspace_id: "workspace-b".into(),
        pane_id: "pane-b".into(),
        surface_id: "surface-b".into(),
        session_id: "session-b".into(),
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
            id: "workspace-a".into(),
            selected_pane_id: "pane-a".into(),
            panes: vec![Pane {
                id: "pane-a".into(),
                selected_surface_id: "surface-a".into(),
                surfaces: vec![Surface {
                    id: "surface-a".into(),
                    session_id: "mac-uuid".into(),
                    is_pinned: true,
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
