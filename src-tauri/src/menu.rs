//! Native application menu bar.
//!
//! Tauri 2's `Menu` renders as a native `NSMenu` on macOS, a `Gtk::Menu` on
//! Linux, and a `Win32` menu on Windows. We build the same logical menu on
//! every platform; the OS places it in the right spot (menubar on macOS,
//! window-attached on Linux/Windows).
//!
//! Menu items carry opaque string ids. When a user clicks one, we emit a
//! `"menu-action"` event to every window with that id as payload; the frontend
//! (App.tsx) has a single listener that routes the id to the existing
//! keyboard-shortcut handlers. Keeping the dispatch table in TypeScript means
//! the actions stay close to the React state that owns them.

use tauri::menu::{AboutMetadataBuilder, MenuBuilder, MenuItemBuilder, SubmenuBuilder};
use tauri::{AppHandle, Emitter, Runtime};

/// Identifier emitted via the `menu-action` event when a menu item is clicked.
///
/// Kept as a single const table so the Rust and TypeScript sides both agree
/// on the vocabulary (the TS side uses the same strings in its switch).
pub mod action {
    pub const NEW_CONNECTION: &str = "file:new_connection";
    pub const CLOSE_TAB: &str = "file:close_tab";
    pub const SETTINGS: &str = "file:settings";

    pub const NEXT_TAB: &str = "window:next_tab";
    pub const PREV_TAB: &str = "window:prev_tab";
    pub const SPLIT_RIGHT: &str = "window:split_right";
    pub const SPLIT_DOWN: &str = "window:split_down";

    pub const TOGGLE_LEFT_SIDEBAR: &str = "view:toggle_left_sidebar";
    pub const TOGGLE_RIGHT_SIDEBAR: &str = "view:toggle_right_sidebar";
    pub const TOGGLE_BOTTOM_PANEL: &str = "view:toggle_bottom_panel";
    pub const TOGGLE_ZEN_MODE: &str = "view:toggle_zen_mode";

    pub const HELP_DOCS: &str = "help:docs";
    pub const HELP_REPORT_ISSUE: &str = "help:report_issue";
}

/// Build and install the application menu, and wire the `on_menu_event`
/// callback to emit a `"menu-action"` event with the clicked id.
pub fn install<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<()> {
    // ------------------------------------------------------------------
    // App menu (macOS puts our product name here; other platforms ignore it)
    // ------------------------------------------------------------------
    let about_metadata = AboutMetadataBuilder::new()
        .name(Some("r-shell".to_string()))
        .version(Some(env!("CARGO_PKG_VERSION").to_string()))
        .build();

    let app_submenu = SubmenuBuilder::new(app, "r-shell")
        .about(Some(about_metadata))
        .separator()
        .services()
        .separator()
        .hide()
        .hide_others()
        .show_all()
        .separator()
        .quit()
        .build()?;

    // ------------------------------------------------------------------
    // File
    // ------------------------------------------------------------------
    let new_connection = MenuItemBuilder::with_id(action::NEW_CONNECTION, "New Connection…")
        .accelerator("CmdOrCtrl+N")
        .build(app)?;
    let close_tab = MenuItemBuilder::with_id(action::CLOSE_TAB, "Close Tab")
        .accelerator("CmdOrCtrl+W")
        .build(app)?;
    let settings = MenuItemBuilder::with_id(action::SETTINGS, "Settings…")
        .accelerator("CmdOrCtrl+,")
        .build(app)?;

    let file_submenu = SubmenuBuilder::new(app, "File")
        .item(&new_connection)
        .item(&close_tab)
        .separator()
        .item(&settings)
        .build()?;

    // ------------------------------------------------------------------
    // Edit — all predefined so they get native behavior (copy/paste into
    // text fields, undo via the system responder chain).
    // ------------------------------------------------------------------
    let edit_submenu = SubmenuBuilder::new(app, "Edit")
        .undo()
        .redo()
        .separator()
        .cut()
        .copy()
        .paste()
        .select_all()
        .build()?;

    // ------------------------------------------------------------------
    // View — layout toggles plumbed through to the frontend's layout ctx.
    // ------------------------------------------------------------------
    let toggle_left = MenuItemBuilder::with_id(action::TOGGLE_LEFT_SIDEBAR, "Toggle Left Sidebar")
        .accelerator("CmdOrCtrl+B")
        .build(app)?;
    let toggle_right = MenuItemBuilder::with_id(
        action::TOGGLE_RIGHT_SIDEBAR,
        "Toggle Right Sidebar",
    )
    .accelerator("CmdOrCtrl+Shift+B")
    .build(app)?;
    let toggle_bottom = MenuItemBuilder::with_id(
        action::TOGGLE_BOTTOM_PANEL,
        "Toggle Bottom Panel",
    )
    .accelerator("CmdOrCtrl+J")
    .build(app)?;
    let toggle_zen = MenuItemBuilder::with_id(action::TOGGLE_ZEN_MODE, "Toggle Zen Mode")
        .accelerator("CmdOrCtrl+K Z")
        .build(app)?;

    let view_submenu = SubmenuBuilder::new(app, "View")
        .item(&toggle_left)
        .item(&toggle_right)
        .item(&toggle_bottom)
        .separator()
        .item(&toggle_zen)
        .build()?;

    // ------------------------------------------------------------------
    // Window — native minimize/close, plus tab + split navigation.
    // ------------------------------------------------------------------
    let next_tab = MenuItemBuilder::with_id(action::NEXT_TAB, "Next Tab")
        .accelerator("Ctrl+Tab")
        .build(app)?;
    let prev_tab = MenuItemBuilder::with_id(action::PREV_TAB, "Previous Tab")
        .accelerator("Ctrl+Shift+Tab")
        .build(app)?;
    let split_right = MenuItemBuilder::with_id(action::SPLIT_RIGHT, "Split Right")
        .accelerator("CmdOrCtrl+D")
        .build(app)?;
    let split_down = MenuItemBuilder::with_id(action::SPLIT_DOWN, "Split Down")
        .accelerator("CmdOrCtrl+Shift+D")
        .build(app)?;

    let window_submenu = SubmenuBuilder::new(app, "Window")
        .minimize()
        .separator()
        .item(&next_tab)
        .item(&prev_tab)
        .separator()
        .item(&split_right)
        .item(&split_down)
        .separator()
        .close_window()
        .build()?;

    // ------------------------------------------------------------------
    // Help
    // ------------------------------------------------------------------
    let docs = MenuItemBuilder::with_id(action::HELP_DOCS, "Documentation").build(app)?;
    let report = MenuItemBuilder::with_id(action::HELP_REPORT_ISSUE, "Report an Issue…").build(app)?;
    let help_submenu = SubmenuBuilder::new(app, "Help")
        .item(&docs)
        .item(&report)
        .build()?;

    // ------------------------------------------------------------------
    // Assemble + install
    // ------------------------------------------------------------------
    let menu = MenuBuilder::new(app)
        .item(&app_submenu)
        .item(&file_submenu)
        .item(&edit_submenu)
        .item(&view_submenu)
        .item(&window_submenu)
        .item(&help_submenu)
        .build()?;

    app.set_menu(menu)?;

    // Wire menu clicks → "menu-action" event to the frontend.
    // The frontend (App.tsx) has a single listener that routes by id.
    app.on_menu_event(move |app_handle, event| {
        let action_id = event.id().as_ref().to_string();
        if let Err(e) = app_handle.emit("menu-action", action_id.clone()) {
            tracing::warn!("failed to emit menu-action for {}: {}", action_id, e);
        }
    });

    Ok(())
}
