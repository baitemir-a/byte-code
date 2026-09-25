//! Mouse input for the whole window.
const rl = @import("raylib");
const Sidebar = @import("../../ui/sidebar/Sidebar.zig");
const Keymap = @import("../../input/Keymap.zig");
const App = @import("../App.zig");
const i18n = @import("../../i18n/i18n.zig");

/// Clicks go to whatever is on top: the suggestion popup, the find bar, the
/// tab bar, the sidebar, then the welcome page or the text (which also takes
/// keyboard focus back from the find bar).
pub fn handleMouse(self: *App) !bool {
    const point = rl.getMousePosition();
    const pressed = rl.isMouseButtonPressed(.left);
    const right_pressed = rl.isMouseButtonPressed(.right);
    const editing = self.isEditing();

    // "Go to file" is on top: a click picks a file, a click elsewhere closes it.
    if (self.quick_open.is_open) {
        if (!pressed) return false;
        if (self.quick_open.itemAt(point)) |i| {
            self.quick_open.selected = i;
            try self.openQuickOpenSelection();
        } else if (!self.quick_open.contains(point)) self.quick_open.close();
        return true;
    }

    // The same for the lists of branches and stashes.
    if (self.picker.is_open) return self.pickerMouse(point, pressed);

    // The sidebar's right edge: drag to resize.
    if (self.sidebar.resizing) {
        self.wanted_cursor = .resize_ew;
        if (rl.isMouseButtonDown(.left)) {
            self.sidebar.preferred_width = @max(Sidebar.min_width, point.x);
        } else {
            // Released: remember the width that was actually used.
            self.sidebar.resizing = false;
            const old = self.settings;
            self.settings.sidebar_width = @intFromFloat(self.sidebar.width());
            self.sidebar.preferred_width = self.sidebar.width();
            try self.settingsChanged(old);
        }
        return true;
    }
    if (!self.menu.is_open and self.sidebar.onEdge(point)) {
        self.wanted_cursor = .resize_ew;
        if (pressed) {
            self.sidebar.resizing = true;
            return true;
        }
    }

    // The line between the two editor panes: drag it to share the room
    // between them differently.
    const split_cursor: rl.MouseCursor = if ((self.split orelse .right) == .right) .resize_ew else .resize_ns;
    if (self.split_resizing) {
        self.wanted_cursor = split_cursor;
        if (rl.isMouseButtonDown(.left)) self.resizeSplit(point) else self.split_resizing = false;
        return true;
    }
    if (self.split != null and !self.menu.is_open and rl.checkCollisionPointRec(point, self.dividerRect())) {
        self.wanted_cursor = split_cursor;
        if (pressed) {
            self.split_resizing = true;
            return true;
        }
    }

    // The terminal panel (unless a menu is open on top of it). A drag
    // that started in the text keeps the mouse even over the panel, so
    // the selection scrolls on instead of stopping at it.
    const text_drag = editing and self.mouse.dragging;
    if (!self.menu.is_open and !text_drag and self.handleTerminalMouse(point, pressed)) return true;

    // The bar along the bottom takes the mouse itself: clicking it must
    // not move the cursor in the text. A selection being dragged keeps it.
    // The branch there picks another one; the counters beside it sync.
    if (!self.mouse.dragging and self.status.contains(point)) {
        if (!self.menu.is_open) if (self.status.hit(point)) |h| {
            self.wanted_cursor = .pointing_hand;
            if (pressed) switch (h) {
                .branch => try self.openBranchPicker(.checkout),
                .sync => if (!self.gitBusy()) self.startGitJob(.sync),
            };
        };
        return pressed;
    }

    // The context menu is on top of everything; any click closes it.
    if (self.menu.is_open and (pressed or right_pressed)) {
        const chosen = if (pressed) self.menu.itemAt(point) else null;
        self.menu.close();
        if (chosen) |i| try self.runMenuAction(self.menu_actions[i]);
        return true;
    }

    const on_popup = editing and pressed and self.popup.contains(point);
    if (on_popup) if (self.popup.itemAt(&self.completion, point)) |i| {
        self.completion.selected = i;
        try self.acceptCompletion();
    };

    const on_find = editing and pressed and !on_popup and self.find.contains(point);
    if (on_find) {
        try self.find.click(point, &self.view, self.buf());
        self.reveal_cursor = true;
    }

    // A press in the other pane gives it the keyboard first, so that
    // everything below acts on the pane being pointed at.
    if ((pressed or right_pressed) and !on_popup and !on_find and !self.menu.is_open) {
        if (self.paneAt(point)) |p| self.focusPane(p);
    }

    // Tabs: click to switch, × or middle click to close, right-click for
    // the split menu, drag to move the tab to the other pane.
    const over_tabs = self.tab_bar.contains(point) or (self.split != null and self.other_bar.contains(point));
    const middle = rl.isMouseButtonPressed(.middle);
    const on_tabs = over_tabs and (pressed or middle or right_pressed);
    if (on_tabs) if (self.tab_bar.hit(point)) |h| {
        const index = self.paneStart(self.pane) + h.index;
        if (right_pressed) {
            self.openTabMenu(index, point);
        } else if (h.close or middle) {
            _ = try self.closeTab(index);
        } else {
            try self.activate(index);
            self.startTabPress(index, point);
        }
    };

    // The Git tab's tooltip floats over the sidebar: it takes the mouse
    // before the rows under it do.
    if (!self.menu.is_open and self.badgeTooltipClick(point, pressed)) return pressed;

    // The sidebar: the wheel scrolls it; clicks toggle folders, open files
    // or press the header buttons; right-click offers New File / Folder.
    // The sidebar's scrollbar comes before its rows.
    if (!self.menu.is_open and self.sidebar.handleScrollbar(point, pressed)) return true;
    const over_sidebar = self.sidebar.contains(point);
    const on_sidebar = (pressed or right_pressed) and over_sidebar;
    if (over_sidebar) switch (self.sidebar.view) {
        .explorer => self.sidebar.scrollBy(rl.getMouseWheelMove()),
        .search => self.search_panel.scrollBy(rl.getMouseWheelMove()),
        .git => self.git_panel.scrollBy(rl.getMouseWheelMove()),
    };
    // The wheel scrolls whichever pane it is over, keyboard or not.
    const on_other_pane = !over_sidebar and !over_tabs and self.split != null and
        (if (self.paneAt(point)) |p| p != self.pane else false);
    if (on_other_pane) self.other_view.scrollBy(rl.getMouseWheelMoveV());
    // The Help tab's list is longer than the window, and Settings can be
    // too: the wheel scrolls them.
    if (!over_sidebar and !over_tabs) switch (self.activeTab().kind) {
        .help => self.help_page.scrollBy(rl.getMouseWheelMove()),
        .settings => self.settings_page.scrollBy(rl.getMouseWheelMove()),
        .welcome => self.welcome.scrollBy(rl.getMouseWheelMove()),
        else => {},
    };
    // Clicking outside the sidebar takes the keyboard from its text boxes.
    if (pressed and !over_sidebar) self.side_focus = .none;
    var keep_name_box = false;
    if (on_sidebar) if (self.project) |*p| {
        const hit = self.sidebar.hitTest(p, point);
        if (right_pressed) {
            if (self.sidebar.view == .explorer) self.openContextMenu(hit, point);
        } else if (hit) |h| switch (h) {
            .view_tab => |v| self.showView(v),
            .strip_button => |b| switch (b) {
                .terminal => try self.toggleTerminalPanel(),
                .open_folder => self.openFolderWithDialog() catch |err| self.reportError(i18n.tr().errors.open_folder, "", err),
                .help => try self.openHelp(),
                .settings => try self.openSettings(),
            },
            .panel => try self.panelClick(point),
            // Acted on at release: the press may turn into a drag.
            .node => |index| try self.startTreePress(index, point),
            .input => {
                self.sidebar.clickInput(p, point, self.view.font);
                keep_name_box = true;
            },
            .collapse_button => try p.collapseAll(),
            .new_button => |kind| {
                try self.startCreate(kind, self.defaultFolder());
                keep_name_box = true;
            },
            .empty => {},
        };
    };
    // Clicking anywhere but the name box gives up on the new entry.
    if ((pressed or right_pressed) and !keep_name_box) self.sidebar.cancelInput();
    try self.updateTreePress(point);
    try self.updateTabPress(point);
    const dragging = (self.tree_press != null and self.tree_press.?.dragging) or
        (self.tab_press != null and self.tab_press.?.dragging);

    // A drag in the sidebar owns the mouse (and re-lays-out every frame).
    const captured = on_popup or on_find or on_tabs or on_sidebar or dragging;
    if (!self.isEditing()) {
        if (pressed and !captured) switch (self.activeTab().kind) {
            // The welcome page's links, folders and favorites; the
            // settings' controls.
            .welcome => try self.welcomeClick(point),
            .settings => if (self.settings_page.actionAt(point, &self.settings)) |a| try self.runSettingsAction(a),
            .help => if (self.help_page.actionAt(point, self.view.font, &self.keys)) |a| try self.runHelpAction(a),
            .file, .diff => {},
        };
        return captured or pressed;
    }

    // The buttons beside a change in the Git view, in the gutter.
    if (pressed and !captured and try self.hunkClick(point)) return true;
    if (!captured and try self.conflictMouse(point, pressed)) return true;

    // Ctrl+click (Cmd+click on macOS) on a name: go to where it is
    // declared, or list where it is used. Option is left to the extra
    // cursors it already adds.
    const mods = Keymap.Mods.current();
    if (pressed and !captured and mods.primary() and !mods.alt) {
        if (try self.symbolClick(point)) return true;
    }

    // The minimap: click or drag to scroll.
    if (self.settings.minimap and !captured and self.minimap.handleMouse(&self.view, self.buf(), point, pressed)) return true;

    const moved = self.mouse.update(&self.view, self.buf(), captured, !over_sidebar and !over_tabs and !on_other_pane);
    if (moved) {
        self.completion.close();
        self.find.focus = .editor;
    }
    return moved or captured;
}
