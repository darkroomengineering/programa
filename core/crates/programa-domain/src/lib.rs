use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const ABI_VERSION: u32 = 1;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    pub abi_version: u32,
    pub revision: u64,
    pub selected_workspace_id: Option<String>,
    pub workspaces: Vec<Workspace>,
}

impl Default for Snapshot {
    fn default() -> Self {
        Self {
            abi_version: ABI_VERSION,
            revision: 0,
            selected_workspace_id: None,
            workspaces: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Workspace {
    pub id: String,
    /// A name the user gave the workspace; frontends derive one when it is absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Pinned workspaces stay together at the top of the list.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub pinned: bool,
    /// The sidebar color, `#RRGGBB`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// A line the user wrote under the title.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// The workspace this one nests under in the sidebar (a git worktree under its repository's
    /// workspace). One level deep; the list keeps every child right after its parent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    /// A parent whose children the sidebar hides.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub collapsed: bool,
    /// The repository this workspace is the worktree folder of (macOS Use as Worktree Folder):
    /// new worktree workspaces of it nest here.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree_repo: Option<String>,
    pub selected_pane_id: String,
    pub panes: Vec<Pane>,
    pub layout: LayoutNode,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Pane {
    pub id: String,
    pub selected_surface_id: String,
    pub surfaces: Vec<Surface>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Surface {
    pub id: String,
    pub session_id: String,
    #[serde(default)]
    pub is_pinned: bool,
    /// A name the user gave the tab; frontends show the program's title when it is absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum LayoutNode {
    Pane {
        pane_id: String,
    },
    Split {
        id: String,
        direction: SplitDirection,
        ratio: f64,
        first: Box<LayoutNode>,
        second: Box<LayoutNode>,
    },
}

/// Where a new workspace goes in the list, as macOS's `app.newWorkspacePlacement`; pinned
/// workspaces stay first either way.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkspacePlacement {
    Top,
    AfterCurrent,
    #[default]
    End,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SplitDirection {
    Horizontal,
    Vertical,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "command", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    SeedSnapshot {
        snapshot: Snapshot,
    },
    CreateWorkspace {
        workspace_id: String,
        pane_id: String,
        surface_id: String,
        session_id: String,
        #[serde(default)]
        placement: WorkspacePlacement,
    },
    SelectWorkspace {
        workspace_id: String,
    },
    CloseWorkspace {
        workspace_id: String,
    },
    /// A null or blank title removes the custom name.
    RenameWorkspace {
        workspace_id: String,
        title: Option<String>,
    },
    /// Pinning moves the workspace to the end of the pinned ones at the top; unpinning, to just
    /// after them.
    SetWorkspacePinned {
        workspace_id: String,
        pinned: bool,
    },
    /// `#RRGGBB`; null or blank removes the color.
    SetWorkspaceColor {
        workspace_id: String,
        color: Option<String>,
    },
    /// A null or blank description removes it.
    SetWorkspaceDescription {
        workspace_id: String,
        description: Option<String>,
    },
    /// Moves the workspace to `index`, kept within its group (pinned or not).
    MoveWorkspace {
        workspace_id: String,
        index: usize,
    },
    /// Nests a workspace under another (null removes it): the parent must be top level and the
    /// child must have no children of its own.
    SetWorkspaceParent {
        workspace_id: String,
        parent_id: Option<String>,
    },
    /// Hides or shows a parent's children in the sidebar.
    SetWorkspaceCollapsed {
        workspace_id: String,
        collapsed: bool,
    },
    /// Makes a workspace its repository's worktree folder (a top-level one: it leaves its parent),
    /// or with null stops: its children go back to the top level.
    SetWorkspaceWorktreeFolder {
        workspace_id: String,
        repo: Option<String>,
    },
    /// Adds a whole workspace from another core as is (the Windows app moving it between
    /// windows), and selects it. Its ids must be new to this core.
    AdoptWorkspace {
        workspace: Workspace,
    },
    /// Adds one surface from another core (the Windows app moving a tab between windows) to a
    /// pane, before `before_surface_id` or at the end, and selects it. Its ids must be new here.
    AdoptSurface {
        workspace_id: String,
        pane_id: String,
        surface: Surface,
        before_surface_id: Option<String>,
    },
    /// A null or blank title removes the custom name.
    RenameSurface {
        workspace_id: String,
        pane_id: String,
        surface_id: String,
        title: Option<String>,
    },
    /// Pinning moves the tab to the end of its pane's pinned tabs; unpinning, to just after them.
    SetSurfacePinned {
        workspace_id: String,
        pane_id: String,
        surface_id: String,
        pinned: bool,
    },
    CreateSurface {
        workspace_id: String,
        pane_id: String,
        surface_id: String,
        session_id: String,
    },
    SelectSurface {
        workspace_id: String,
        pane_id: String,
        surface_id: String,
    },
    CloseSurface {
        workspace_id: String,
        pane_id: String,
        surface_id: String,
    },
    ReorderSurface {
        workspace_id: String,
        pane_id: String,
        surface_id: String,
        before_surface_id: Option<String>,
    },
    MoveSurface {
        workspace_id: String,
        source_pane_id: String,
        target_pane_id: String,
        surface_id: String,
        before_surface_id: Option<String>,
    },
    SplitPane {
        workspace_id: String,
        pane_id: String,
        split_id: String,
        new_pane_id: String,
        new_surface_id: String,
        session_id: String,
        direction: SplitDirection,
        ratio: f64,
        /// The new pane goes first: a split to the left or above. `ratio` stays the original pane's share.
        #[serde(default)]
        insert_first: bool,
    },
    ResizeSplit {
        workspace_id: String,
        split_id: String,
        ratio: f64,
    },
}

#[derive(Debug, Error, PartialEq, Eq)]
#[error("{message}")]
pub struct DomainError {
    code: &'static str,
    message: String,
}

impl DomainError {
    pub fn code(&self) -> &'static str {
        self.code
    }

    pub fn message(&self) -> &str {
        &self.message
    }

    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Core {
    snapshot: Snapshot,
}

impl Core {
    pub fn snapshot(&self) -> &Snapshot {
        &self.snapshot
    }

    pub fn dispatch(&mut self, command: Command) -> Result<&Snapshot, DomainError> {
        let mut candidate = self.snapshot.clone();
        let changed = candidate.apply(command)?;
        if changed {
            candidate.canonicalize_hierarchy();
        }
        candidate.validate()?;
        if changed {
            candidate.revision =
                self.snapshot.revision.checked_add(1).ok_or_else(|| {
                    DomainError::new("revision_overflow", "revision cannot advance")
                })?;
            candidate.abi_version = ABI_VERSION;
            self.snapshot = candidate;
        }
        Ok(&self.snapshot)
    }
}

impl Snapshot {
    fn apply(&mut self, command: Command) -> Result<bool, DomainError> {
        match command {
            Command::SeedSnapshot { mut snapshot } => {
                snapshot.validate()?;
                snapshot.abi_version = ABI_VERSION;
                snapshot.revision = self.revision;
                let changed = *self != snapshot;
                if changed {
                    *self = snapshot;
                }
                Ok(changed)
            }
            Command::CreateWorkspace {
                workspace_id,
                pane_id,
                surface_id,
                session_id,
                placement,
            } => {
                validate_new_ids(self, [&workspace_id, &pane_id, &surface_id])?;
                validate_id("session_id", &session_id)?;
                let index = new_workspace_index(self, placement);
                self.workspaces.insert(
                    index,
                    Workspace {
                        id: workspace_id.clone(),
                        title: None,
                        pinned: false,
                        color: None,
                        description: None,
                        parent_id: None,
                        collapsed: false,
                        worktree_repo: None,
                        selected_pane_id: pane_id.clone(),
                        panes: vec![Pane {
                            id: pane_id.clone(),
                            selected_surface_id: surface_id.clone(),
                            surfaces: vec![Surface {
                                id: surface_id,
                                session_id,
                                is_pinned: false,
                                title: None,
                            }],
                        }],
                        layout: LayoutNode::Pane { pane_id },
                    },
                );
                self.selected_workspace_id = Some(workspace_id);
                Ok(true)
            }
            Command::SelectWorkspace { workspace_id } => {
                let index = workspace_index(self, &workspace_id)?;
                // Selecting a hidden child opens its parent's folder.
                let parent = self.workspaces[index].parent_id.clone();
                let expanded =
                    match parent.and_then(|id| self.workspaces.iter_mut().find(|w| w.id == id)) {
                        Some(parent) if parent.collapsed => {
                            parent.collapsed = false;
                            true
                        }
                        _ => false,
                    };
                if self.selected_workspace_id.as_deref() == Some(&workspace_id) {
                    return Ok(expanded);
                }
                self.selected_workspace_id = Some(workspace_id);
                Ok(true)
            }
            Command::SetWorkspaceParent {
                workspace_id,
                parent_id,
            } => {
                let index = workspace_index(self, &workspace_id)?;
                if let Some(parent_id) = &parent_id {
                    let parent = &self.workspaces[workspace_index(self, parent_id)?];
                    let has_children = self
                        .workspaces
                        .iter()
                        .any(|w| w.parent_id.as_deref() == Some(workspace_id.as_str()));
                    if *parent_id == workspace_id || parent.parent_id.is_some() || has_children {
                        return Err(DomainError::new(
                            "invalid_parent",
                            "a workspace nests one level deep, under a top-level workspace",
                        ));
                    }
                }
                if self.workspaces[index].parent_id == parent_id {
                    return Ok(false);
                }
                self.workspaces[index].parent_id = parent_id;
                Ok(true)
            }
            Command::SetWorkspaceCollapsed {
                workspace_id,
                collapsed,
            } => {
                let workspace = workspace_mut(self, &workspace_id)?;
                if workspace.collapsed == collapsed {
                    return Ok(false);
                }
                workspace.collapsed = collapsed;
                Ok(true)
            }
            Command::SetWorkspaceWorktreeFolder { workspace_id, repo } => {
                let repo = repo
                    .map(|repo| repo.trim().to_owned())
                    .filter(|repo| !repo.is_empty());
                let index = workspace_index(self, &workspace_id)?;
                let mut changed = self.workspaces[index].worktree_repo != repo;
                if repo.is_none() {
                    for child in &mut self.workspaces {
                        if child.parent_id.as_deref() == Some(workspace_id.as_str()) {
                            child.parent_id = None;
                            changed = true;
                        }
                    }
                }
                let workspace = &mut self.workspaces[index];
                if repo.is_some() && workspace.parent_id.is_some() {
                    workspace.parent_id = None;
                    changed = true;
                }
                if changed {
                    workspace.collapsed = false;
                }
                workspace.worktree_repo = repo;
                Ok(changed)
            }
            Command::CloseWorkspace { workspace_id } => {
                let index = workspace_index(self, &workspace_id)?;
                remove_workspace(self, index);
                Ok(true)
            }
            Command::RenameWorkspace {
                workspace_id,
                title,
            } => {
                let title = title
                    .map(|title| title.trim().to_owned())
                    .filter(|title| !title.is_empty());
                let workspace = workspace_mut(self, &workspace_id)?;
                if workspace.title == title {
                    return Ok(false);
                }
                workspace.title = title;
                Ok(true)
            }
            Command::SetWorkspacePinned {
                workspace_id,
                pinned,
            } => {
                let index = workspace_index(self, &workspace_id)?;
                if self.workspaces[index].pinned == pinned {
                    return Ok(false);
                }
                let mut workspace = self.workspaces.remove(index);
                workspace.pinned = pinned;
                let pinned_count = self.workspaces.iter().filter(|w| w.pinned).count();
                self.workspaces.insert(pinned_count, workspace);
                Ok(true)
            }
            Command::SetWorkspaceColor {
                workspace_id,
                color,
            } => {
                let color = color
                    .map(|color| color.trim().to_ascii_uppercase())
                    .filter(|color| !color.is_empty());
                if let Some(color) = &color {
                    let hex = color.strip_prefix('#').unwrap_or_default();
                    if hex.len() != 6 || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
                        return Err(DomainError::new(
                            "invalid_color",
                            format!("{color} is not a #RRGGBB color"),
                        ));
                    }
                }
                let workspace = workspace_mut(self, &workspace_id)?;
                if workspace.color == color {
                    return Ok(false);
                }
                workspace.color = color;
                Ok(true)
            }
            Command::SetWorkspaceDescription {
                workspace_id,
                description,
            } => {
                let description = description
                    .map(|description| description.trim().to_owned())
                    .filter(|description| !description.is_empty());
                let workspace = workspace_mut(self, &workspace_id)?;
                if workspace.description == description {
                    return Ok(false);
                }
                workspace.description = description;
                Ok(true)
            }
            Command::AdoptWorkspace { workspace } => {
                let mut next = self.clone();
                let id = workspace.id.clone();
                // A pinned workspace joins the end of the pinned ones, any other the end of the list.
                let at = if workspace.pinned {
                    next.workspaces.iter().filter(|w| w.pinned).count()
                } else {
                    next.workspaces.len()
                };
                next.workspaces.insert(at, workspace);
                next.selected_workspace_id = Some(id);
                next.validate()?;
                *self = next;
                Ok(true)
            }
            Command::AdoptSurface {
                workspace_id,
                pane_id,
                surface,
                before_surface_id,
            } => {
                let mut next = self.clone();
                let workspace = workspace_mut(&mut next, &workspace_id)?;
                let pane = pane_mut(workspace, &pane_id)?;
                let at = match before_surface_id.as_deref() {
                    Some(before) => surface_index(pane, before)?,
                    None => pane.surfaces.len(),
                };
                pane.selected_surface_id = surface.id.clone();
                pane.surfaces.insert(at, surface);
                workspace.selected_pane_id = pane_id;
                next.selected_workspace_id = Some(workspace_id);
                next.validate()?;
                *self = next;
                Ok(true)
            }
            Command::MoveWorkspace {
                workspace_id,
                index,
            } => {
                let from = workspace_index(self, &workspace_id)?;
                let pinned_count = self.workspaces.iter().filter(|w| w.pinned).count();
                let (low, high) = if self.workspaces[from].pinned {
                    (0, pinned_count - 1)
                } else {
                    (pinned_count, self.workspaces.len() - 1)
                };
                let to = index.clamp(low, high);
                if to == from {
                    return Ok(false);
                }
                let workspace = self.workspaces.remove(from);
                self.workspaces.insert(to, workspace);
                Ok(true)
            }
            Command::RenameSurface {
                workspace_id,
                pane_id,
                surface_id,
                title,
            } => {
                let title = title
                    .map(|title| title.trim().to_owned())
                    .filter(|title| !title.is_empty());
                let pane = pane_mut(workspace_mut(self, &workspace_id)?, &pane_id)?;
                let index = surface_index(pane, &surface_id)?;
                let surface = &mut pane.surfaces[index];
                if surface.title == title {
                    return Ok(false);
                }
                surface.title = title;
                Ok(true)
            }
            Command::SetSurfacePinned {
                workspace_id,
                pane_id,
                surface_id,
                pinned,
            } => {
                let pane = pane_mut(workspace_mut(self, &workspace_id)?, &pane_id)?;
                let index = surface_index(pane, &surface_id)?;
                if pane.surfaces[index].is_pinned == pinned {
                    return Ok(false);
                }
                let mut surface = pane.surfaces.remove(index);
                surface.is_pinned = pinned;
                let pinned_count = pane.surfaces.iter().filter(|s| s.is_pinned).count();
                pane.surfaces.insert(pinned_count, surface);
                Ok(true)
            }
            Command::CreateSurface {
                workspace_id,
                pane_id,
                surface_id,
                session_id,
            } => {
                validate_new_ids(self, [&surface_id])?;
                validate_id("session_id", &session_id)?;
                let workspace = workspace_mut(self, &workspace_id)?;
                let pane = pane_mut(workspace, &pane_id)?;
                pane.surfaces.push(Surface {
                    id: surface_id.clone(),
                    session_id,
                    is_pinned: false,
                    title: None,
                });
                pane.selected_surface_id = surface_id;
                workspace.selected_pane_id = pane_id;
                self.selected_workspace_id = Some(workspace_id);
                Ok(true)
            }
            Command::SelectSurface {
                workspace_id,
                pane_id,
                surface_id,
            } => {
                let selected_workspace_changed =
                    self.selected_workspace_id.as_deref() != Some(&workspace_id);
                let workspace = workspace_mut(self, &workspace_id)?;
                let selected_pane_changed = workspace.selected_pane_id != pane_id;
                let pane = pane_mut(workspace, &pane_id)?;
                if !pane.surfaces.iter().any(|surface| surface.id == surface_id) {
                    return Err(not_found("surface", &surface_id));
                }
                let changed = selected_workspace_changed
                    || selected_pane_changed
                    || pane.selected_surface_id != surface_id;
                pane.selected_surface_id = surface_id;
                workspace.selected_pane_id = pane_id;
                self.selected_workspace_id = Some(workspace_id);
                Ok(changed)
            }
            Command::CloseSurface {
                workspace_id,
                pane_id,
                surface_id,
            } => {
                let workspace_index = workspace_index(self, &workspace_id)?;
                let pane_index = pane_index(&self.workspaces[workspace_index], &pane_id)?;
                let surface_index = surface_index(
                    &self.workspaces[workspace_index].panes[pane_index],
                    &surface_id,
                )?;
                let is_final_surface = self.workspaces[workspace_index].panes[pane_index]
                    .surfaces
                    .len()
                    == 1;

                if !is_final_surface {
                    let pane = &mut self.workspaces[workspace_index].panes[pane_index];
                    pane.surfaces.remove(surface_index);
                    if pane.selected_surface_id == surface_id {
                        pane.selected_surface_id = pane.surfaces
                            [surface_index.min(pane.surfaces.len() - 1)]
                        .id
                        .clone();
                    }
                } else if self.workspaces[workspace_index].panes.len() == 1 {
                    remove_workspace(self, workspace_index);
                } else {
                    remove_pane(&mut self.workspaces[workspace_index], pane_index)?;
                }
                Ok(true)
            }
            Command::ReorderSurface {
                workspace_id,
                pane_id,
                surface_id,
                before_surface_id,
            } => {
                let workspace = workspace_mut(self, &workspace_id)?;
                let pane = pane_mut(workspace, &pane_id)?;
                reorder_surface(pane, &surface_id, before_surface_id.as_deref())
            }
            Command::MoveSurface {
                workspace_id,
                source_pane_id,
                target_pane_id,
                surface_id,
                before_surface_id,
            } => {
                let workspace_index = workspace_index(self, &workspace_id)?;
                let workspace = &self.workspaces[workspace_index];
                let source_index = pane_index(workspace, &source_pane_id)?;
                let target_index = pane_index(workspace, &target_pane_id)?;
                surface_index(&workspace.panes[source_index], &surface_id)?;
                if let Some(before_surface_id) = before_surface_id.as_deref() {
                    surface_index(&workspace.panes[target_index], before_surface_id)?;
                }

                if source_index == target_index {
                    let selected_workspace_changed =
                        self.selected_workspace_id.as_deref() != Some(&workspace_id);
                    let workspace = &mut self.workspaces[workspace_index];
                    let selected_pane_changed = workspace.selected_pane_id != target_pane_id;
                    let pane = &mut workspace.panes[source_index];
                    let selected_surface_changed = pane.selected_surface_id != surface_id;
                    let reordered =
                        reorder_surface(pane, &surface_id, before_surface_id.as_deref())?;
                    pane.selected_surface_id = surface_id;
                    workspace.selected_pane_id = target_pane_id;
                    self.selected_workspace_id = Some(workspace_id);
                    return Ok(reordered
                        || selected_workspace_changed
                        || selected_pane_changed
                        || selected_surface_changed);
                }

                let moved = {
                    let source = &mut self.workspaces[workspace_index].panes[source_index];
                    let index = surface_index(source, &surface_id)?;
                    let moved = source.surfaces.remove(index);
                    if !source.surfaces.is_empty() && source.selected_surface_id == surface_id {
                        source.selected_surface_id = source.surfaces
                            [index.min(source.surfaces.len() - 1)]
                        .id
                        .clone();
                    }
                    moved
                };

                if self.workspaces[workspace_index].panes[source_index]
                    .surfaces
                    .is_empty()
                {
                    remove_pane(&mut self.workspaces[workspace_index], source_index)?;
                }

                let workspace = &mut self.workspaces[workspace_index];
                let target_index = pane_index(workspace, &target_pane_id)?;
                let target = &mut workspace.panes[target_index];
                let requested = match before_surface_id.as_deref() {
                    Some(target_id) => surface_index(target, target_id)?,
                    None => target.surfaces.len(),
                };
                let insert_at = clamped_insert_index(target, &moved, requested);
                target.surfaces.insert(insert_at, moved);
                target.selected_surface_id = surface_id;
                workspace.selected_pane_id = target_pane_id;
                self.selected_workspace_id = Some(workspace_id);
                Ok(true)
            }
            Command::SplitPane {
                workspace_id,
                pane_id,
                split_id,
                new_pane_id,
                new_surface_id,
                session_id,
                direction,
                ratio,
                insert_first,
            } => {
                validate_ratio(ratio)?;
                validate_new_ids(self, [&split_id, &new_pane_id, &new_surface_id])?;
                validate_id("session_id", &session_id)?;
                let workspace = workspace_mut(self, &workspace_id)?;
                pane_index(workspace, &pane_id)?;
                let old_layout = workspace.layout.clone();
                workspace.layout = replace_pane_with_split(
                    old_layout,
                    &pane_id,
                    &split_id,
                    &new_pane_id,
                    direction,
                    ratio,
                )?;
                if insert_first {
                    put_new_pane_first(&mut workspace.layout, &split_id);
                }
                workspace.panes.push(Pane {
                    id: new_pane_id.clone(),
                    selected_surface_id: new_surface_id.clone(),
                    surfaces: vec![Surface {
                        id: new_surface_id,
                        session_id,
                        is_pinned: false,
                        title: None,
                    }],
                });
                workspace.selected_pane_id = new_pane_id;
                self.selected_workspace_id = Some(workspace_id);
                Ok(true)
            }
            Command::ResizeSplit {
                workspace_id,
                split_id,
                ratio,
            } => {
                validate_ratio(ratio)?;
                let workspace = workspace_mut(self, &workspace_id)?;
                let current_ratio = find_split_ratio_mut(&mut workspace.layout, &split_id)
                    .ok_or_else(|| not_found("split", &split_id))?;
                if *current_ratio == ratio {
                    return Ok(false);
                }
                *current_ratio = ratio;
                Ok(true)
            }
        }
    }

    /// Keeps every child right after its parent, in their current order, and drops a parent link
    /// that no longer leads to a top-level workspace here (closed, or left in another window).
    fn canonicalize_hierarchy(&mut self) {
        let top_level: HashSet<String> = self
            .workspaces
            .iter()
            .filter(|w| w.parent_id.is_none())
            .map(|w| w.id.clone())
            .collect();
        for workspace in &mut self.workspaces {
            if workspace
                .parent_id
                .as_ref()
                .is_some_and(|parent| !top_level.contains(parent) || *parent == workspace.id)
            {
                workspace.parent_id = None;
            }
        }
        if self.workspaces.iter().all(|w| w.parent_id.is_none()) {
            return;
        }
        let mut ordered = Vec::with_capacity(self.workspaces.len());
        for parent in self.workspaces.iter().filter(|w| w.parent_id.is_none()) {
            ordered.push(parent.clone());
            ordered.extend(
                self.workspaces
                    .iter()
                    .filter(|w| w.parent_id.as_deref() == Some(parent.id.as_str()))
                    .cloned(),
            );
        }
        self.workspaces = ordered;
    }

    pub fn validate(&self) -> Result<(), DomainError> {
        if self.abi_version != ABI_VERSION {
            return Err(DomainError::new(
                "unsupported_abi_version",
                format!(
                    "expected ABI version {ABI_VERSION}, got {}",
                    self.abi_version
                ),
            ));
        }
        if self.workspaces.is_empty() {
            if self.selected_workspace_id.is_some() {
                return Err(DomainError::new(
                    "invalid_snapshot",
                    "an empty snapshot cannot select a workspace",
                ));
            }
            return Ok(());
        }

        let mut all_ids = HashSet::new();
        for workspace in &self.workspaces {
            insert_unique(&mut all_ids, "workspace", &workspace.id)?;
            if workspace.panes.is_empty() {
                return Err(DomainError::new(
                    "invalid_snapshot",
                    "workspace has no panes",
                ));
            }
            if !workspace
                .panes
                .iter()
                .any(|pane| pane.id == workspace.selected_pane_id)
            {
                return Err(DomainError::new(
                    "invalid_snapshot",
                    "selected pane does not belong to its workspace",
                ));
            }
            let mut layout_panes = Vec::new();
            validate_layout(&workspace.layout, &mut all_ids, &mut layout_panes)?;
            let pane_ids: HashSet<&str> = workspace
                .panes
                .iter()
                .map(|pane| pane.id.as_str())
                .collect();
            let layout_ids: HashSet<&str> = layout_panes.into_iter().collect();
            if pane_ids != layout_ids {
                return Err(DomainError::new(
                    "invalid_snapshot",
                    "layout pane IDs must match workspace panes exactly",
                ));
            }
            for pane in &workspace.panes {
                insert_unique(&mut all_ids, "pane", &pane.id)?;
                if pane.surfaces.is_empty() {
                    return Err(DomainError::new("invalid_snapshot", "pane has no surfaces"));
                }
                if !pane
                    .surfaces
                    .iter()
                    .any(|surface| surface.id == pane.selected_surface_id)
                {
                    return Err(DomainError::new(
                        "invalid_snapshot",
                        "selected surface does not belong to its pane",
                    ));
                }
                let mut saw_unpinned = false;
                for surface in &pane.surfaces {
                    insert_unique(&mut all_ids, "surface", &surface.id)?;
                    validate_id("session_id", &surface.session_id)?;
                    if surface.is_pinned && saw_unpinned {
                        return Err(DomainError::new(
                            "invalid_snapshot",
                            "pinned surfaces must form a contiguous prefix",
                        ));
                    }
                    saw_unpinned |= !surface.is_pinned;
                }
            }
        }
        let selected = self.selected_workspace_id.as_deref().ok_or_else(|| {
            DomainError::new(
                "invalid_snapshot",
                "a nonempty snapshot must select a workspace",
            )
        })?;
        if !self
            .workspaces
            .iter()
            .any(|workspace| workspace.id == selected)
        {
            return Err(DomainError::new(
                "invalid_snapshot",
                "selected workspace does not exist",
            ));
        }
        Ok(())
    }
}

fn validate_new_ids<const N: usize>(
    snapshot: &Snapshot,
    ids: [&str; N],
) -> Result<(), DomainError> {
    let mut all_ids = HashSet::new();
    for workspace in &snapshot.workspaces {
        all_ids.insert(workspace.id.as_str());
        collect_layout_ids(&workspace.layout, &mut all_ids);
        for pane in &workspace.panes {
            all_ids.insert(pane.id.as_str());
            for surface in &pane.surfaces {
                all_ids.insert(surface.id.as_str());
            }
        }
    }
    for id in ids {
        validate_id("id", id)?;
        if !all_ids.insert(id) {
            return Err(DomainError::new(
                "duplicate_id",
                format!("ID '{id}' is already in use"),
            ));
        }
    }
    Ok(())
}

fn collect_layout_ids<'a>(node: &'a LayoutNode, ids: &mut HashSet<&'a str>) {
    if let LayoutNode::Split {
        id, first, second, ..
    } = node
    {
        ids.insert(id);
        collect_layout_ids(first, ids);
        collect_layout_ids(second, ids);
    }
}

fn insert_unique<'a>(
    ids: &mut HashSet<&'a str>,
    kind: &str,
    id: &'a str,
) -> Result<(), DomainError> {
    validate_id(kind, id)?;
    if !ids.insert(id) {
        return Err(DomainError::new(
            "duplicate_id",
            format!("duplicate {kind} ID '{id}'"),
        ));
    }
    Ok(())
}

fn validate_id(kind: &str, id: &str) -> Result<(), DomainError> {
    if id.trim().is_empty() {
        return Err(DomainError::new(
            "invalid_id",
            format!("{kind} must not be empty"),
        ));
    }
    Ok(())
}

fn validate_layout<'a>(
    node: &'a LayoutNode,
    ids: &mut HashSet<&'a str>,
    pane_ids: &mut Vec<&'a str>,
) -> Result<(), DomainError> {
    match node {
        LayoutNode::Pane { pane_id } => {
            validate_id("pane_id", pane_id)?;
            if pane_ids.contains(&pane_id.as_str()) {
                return Err(DomainError::new(
                    "invalid_snapshot",
                    format!("pane '{pane_id}' occurs more than once in the layout"),
                ));
            }
            pane_ids.push(pane_id);
        }
        LayoutNode::Split {
            id,
            ratio,
            first,
            second,
            ..
        } => {
            insert_unique(ids, "split", id)?;
            validate_ratio(*ratio)?;
            validate_layout(first, ids, pane_ids)?;
            validate_layout(second, ids, pane_ids)?;
        }
    }
    Ok(())
}

fn validate_ratio(ratio: f64) -> Result<(), DomainError> {
    if ratio.is_finite() && ratio > 0.0 && ratio < 1.0 {
        Ok(())
    } else {
        Err(DomainError::new(
            "invalid_ratio",
            "split ratio must be finite and strictly between 0 and 1",
        ))
    }
}

fn workspace_index(snapshot: &Snapshot, id: &str) -> Result<usize, DomainError> {
    snapshot
        .workspaces
        .iter()
        .position(|workspace| workspace.id == id)
        .ok_or_else(|| not_found("workspace", id))
}

fn workspace_mut<'a>(
    snapshot: &'a mut Snapshot,
    id: &str,
) -> Result<&'a mut Workspace, DomainError> {
    let index = workspace_index(snapshot, id)?;
    Ok(&mut snapshot.workspaces[index])
}

fn pane_index(workspace: &Workspace, id: &str) -> Result<usize, DomainError> {
    workspace
        .panes
        .iter()
        .position(|pane| pane.id == id)
        .ok_or_else(|| not_found("pane", id))
}

fn pane_mut<'a>(workspace: &'a mut Workspace, id: &str) -> Result<&'a mut Pane, DomainError> {
    let index = pane_index(workspace, id)?;
    Ok(&mut workspace.panes[index])
}

fn surface_index(pane: &Pane, id: &str) -> Result<usize, DomainError> {
    pane.surfaces
        .iter()
        .position(|surface| surface.id == id)
        .ok_or_else(|| not_found("surface", id))
}

fn remove_workspace(snapshot: &mut Snapshot, index: usize) {
    let removed_id = snapshot.workspaces[index].id.clone();
    snapshot.workspaces.remove(index);
    if snapshot.selected_workspace_id.as_deref() == Some(&removed_id) {
        snapshot.selected_workspace_id = snapshot
            .workspaces
            .get(index.min(snapshot.workspaces.len().saturating_sub(1)))
            .map(|workspace| workspace.id.clone());
    }
}

fn remove_pane(workspace: &mut Workspace, pane_index: usize) -> Result<(), DomainError> {
    let pane_id = workspace.panes[pane_index].id.clone();
    let (layout, neighbor_pane_id, removed) =
        remove_pane_from_layout(workspace.layout.clone(), &pane_id)?;
    if !removed {
        return Err(not_found("pane", &pane_id));
    }
    workspace.layout = layout.ok_or_else(|| {
        DomainError::new(
            "invalid_snapshot",
            "cannot remove the only pane without removing its workspace",
        )
    })?;
    workspace.panes.remove(pane_index);
    if workspace.selected_pane_id == pane_id {
        workspace.selected_pane_id = neighbor_pane_id.ok_or_else(|| {
            DomainError::new(
                "invalid_snapshot",
                "collapsed layout has no neighboring pane",
            )
        })?;
    }
    Ok(())
}

type LayoutRemoval = (Option<LayoutNode>, Option<String>, bool);

fn unmatched_branch_missing() -> DomainError {
    DomainError::new(
        "invalid_snapshot",
        "an unmatched layout branch is missing after pane removal",
    )
}

fn remove_pane_from_layout(node: LayoutNode, pane_id: &str) -> Result<LayoutRemoval, DomainError> {
    match node {
        LayoutNode::Pane { pane_id: found } if found == pane_id => Ok((None, None, true)),
        LayoutNode::Pane { pane_id: found } => {
            Ok((Some(LayoutNode::Pane { pane_id: found }), None, false))
        }
        LayoutNode::Split {
            id,
            direction,
            ratio,
            first,
            second,
        } => {
            let (new_first, neighbor, removed) = remove_pane_from_layout(*first, pane_id)?;
            if removed {
                return Ok(match new_first {
                    Some(first) => (
                        Some(LayoutNode::Split {
                            id,
                            direction,
                            ratio,
                            first: Box::new(first),
                            second,
                        }),
                        neighbor,
                        true,
                    ),
                    None => {
                        let neighbor = first_pane_id(&second).to_owned();
                        (Some(*second), Some(neighbor), true)
                    }
                });
            }

            let first = new_first.ok_or_else(unmatched_branch_missing)?;
            let (new_second, neighbor, removed) = remove_pane_from_layout(*second, pane_id)?;
            if removed {
                return Ok(match new_second {
                    Some(second) => (
                        Some(LayoutNode::Split {
                            id,
                            direction,
                            ratio,
                            first: Box::new(first),
                            second: Box::new(second),
                        }),
                        neighbor,
                        true,
                    ),
                    None => {
                        let neighbor = last_pane_id(&first).to_owned();
                        (Some(first), Some(neighbor), true)
                    }
                });
            }

            Ok((
                Some(LayoutNode::Split {
                    id,
                    direction,
                    ratio,
                    first: Box::new(first),
                    second: Box::new(new_second.ok_or_else(unmatched_branch_missing)?),
                }),
                None,
                false,
            ))
        }
    }
}

fn first_pane_id(node: &LayoutNode) -> &str {
    match node {
        LayoutNode::Pane { pane_id } => pane_id,
        LayoutNode::Split { first, .. } => first_pane_id(first),
    }
}

fn last_pane_id(node: &LayoutNode) -> &str {
    match node {
        LayoutNode::Pane { pane_id } => pane_id,
        LayoutNode::Split { second, .. } => last_pane_id(second),
    }
}

fn reorder_surface(
    pane: &mut Pane,
    surface_id: &str,
    before_surface_id: Option<&str>,
) -> Result<bool, DomainError> {
    let from = surface_index(pane, surface_id)?;
    let target = match before_surface_id {
        Some(target_id) => surface_index(pane, target_id)?,
        None => pane.surfaces.len(),
    };
    let requested = if from < target { target - 1 } else { target };
    let moved = pane.surfaces.remove(from);
    let insert_at = clamped_insert_index(pane, &moved, requested);
    if from == insert_at {
        pane.surfaces.insert(from, moved);
        return Ok(false);
    }
    pane.surfaces.insert(insert_at, moved);
    Ok(true)
}

fn clamped_insert_index(pane: &Pane, moved: &Surface, requested: usize) -> usize {
    let pinned_count = pane
        .surfaces
        .iter()
        .filter(|surface| surface.is_pinned)
        .count();
    if moved.is_pinned {
        requested.min(pinned_count)
    } else {
        requested.max(pinned_count)
    }
}

fn not_found(kind: &str, id: &str) -> DomainError {
    DomainError::new("not_found", format!("{kind} '{id}' was not found"))
}

/// The new workspace's index, as macOS's `WorkspacePlacementSettings.insertionIndex`: top goes after
/// the pinned workspaces, after-current after the selected one (after the pinned ones when it is
/// pinned), and past the worktree children kept right after their parent.
fn new_workspace_index(snapshot: &Snapshot, placement: WorkspacePlacement) -> usize {
    let workspaces = &snapshot.workspaces;
    let pinned = workspaces.iter().take_while(|w| w.pinned).count();
    let selected = snapshot
        .selected_workspace_id
        .as_deref()
        .and_then(|id| workspaces.iter().position(|w| w.id == id));
    match (placement, selected) {
        (WorkspacePlacement::Top, _) => pinned,
        (WorkspacePlacement::AfterCurrent, Some(index)) if workspaces[index].pinned => pinned,
        (WorkspacePlacement::AfterCurrent, Some(index)) => {
            let root = workspaces[index]
                .parent_id
                .as_deref()
                .unwrap_or(&workspaces[index].id);
            let start = workspaces
                .iter()
                .position(|w| w.id == root)
                .unwrap_or(index);
            let children = workspaces[start + 1..]
                .iter()
                .take_while(|w| w.parent_id.as_deref() == Some(root))
                .count();
            start + 1 + children
        }
        _ => workspaces.len(),
    }
}

/// Swaps the new split's children, so the new pane comes first and keeps the same share.
fn put_new_pane_first(node: &mut LayoutNode, split_id: &str) {
    if let LayoutNode::Split {
        id,
        ratio,
        first,
        second,
        ..
    } = node
    {
        if id == split_id {
            std::mem::swap(first, second);
            *ratio = 1.0 - *ratio;
        } else {
            put_new_pane_first(first, split_id);
            put_new_pane_first(second, split_id);
        }
    }
}

fn replace_pane_with_split(
    node: LayoutNode,
    pane_id: &str,
    split_id: &str,
    new_pane_id: &str,
    direction: SplitDirection,
    ratio: f64,
) -> Result<LayoutNode, DomainError> {
    match node {
        LayoutNode::Pane { pane_id: found } if found == pane_id => Ok(LayoutNode::Split {
            id: split_id.to_owned(),
            direction,
            ratio,
            first: Box::new(LayoutNode::Pane { pane_id: found }),
            second: Box::new(LayoutNode::Pane {
                pane_id: new_pane_id.to_owned(),
            }),
        }),
        LayoutNode::Pane { pane_id: found } => Ok(LayoutNode::Pane { pane_id: found }),
        LayoutNode::Split {
            id,
            direction: existing_direction,
            ratio: existing_ratio,
            first,
            second,
        } => {
            let first_contains = layout_contains_pane(&first, pane_id);
            let second_contains = layout_contains_pane(&second, pane_id);
            if first_contains == second_contains {
                return Err(not_found("pane", pane_id));
            }
            Ok(LayoutNode::Split {
                id,
                direction: existing_direction,
                ratio: existing_ratio,
                first: if first_contains {
                    Box::new(replace_pane_with_split(
                        *first,
                        pane_id,
                        split_id,
                        new_pane_id,
                        direction,
                        ratio,
                    )?)
                } else {
                    first
                },
                second: if second_contains {
                    Box::new(replace_pane_with_split(
                        *second,
                        pane_id,
                        split_id,
                        new_pane_id,
                        direction,
                        ratio,
                    )?)
                } else {
                    second
                },
            })
        }
    }
}

fn layout_contains_pane(node: &LayoutNode, pane_id: &str) -> bool {
    match node {
        LayoutNode::Pane { pane_id: found } => found == pane_id,
        LayoutNode::Split { first, second, .. } => {
            layout_contains_pane(first, pane_id) || layout_contains_pane(second, pane_id)
        }
    }
}

fn find_split_ratio_mut<'a>(node: &'a mut LayoutNode, split_id: &str) -> Option<&'a mut f64> {
    match node {
        LayoutNode::Pane { .. } => None,
        LayoutNode::Split {
            id,
            ratio,
            first,
            second,
            ..
        } => {
            if id == split_id {
                Some(ratio)
            } else {
                find_split_ratio_mut(first, split_id)
                    .or_else(|| find_split_ratio_mut(second, split_id))
            }
        }
    }
}
