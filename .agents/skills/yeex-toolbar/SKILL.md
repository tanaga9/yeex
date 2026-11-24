---
name: yeex-toolbar
description: Implement, review, and verify YeeX AppKit toolbar changes, including customization, saved layouts, display modes, Watch and Poll status, sorting controls, and consistency with the View menu.
---

# YeeX toolbar

## Find the relevant implementation

- Start with the `NSToolbarDelegate` extension in `Sources/YeeX/Viewer.swift` for item identifiers, default order, migration, and presentation. Find the same actions in `Sources/YeeX/Application.swift` for View menu entries.
- For Watch or Poll behavior, read `Viewer.swift` together with `Sources/YeeXCore/FolderObservation.swift`. Read `Sources/YeeXCore/Catalog.swift` if the task concerns what changes a scan or poll can detect.

## Keep state and presentation in sync

- Keep the viewer's state authoritative. Use the same action for a toolbar button and its View menu command. Render the live item from current state on insertion and after changes. Keep customization previews independent of live window state.
- Preserve independent vertical and horizontal sort orders and their shared cycling logic. Use `possibleLabels` for varying native labels or size a custom indicator for its widest state so nearby controls stay in place.
- Keep Poll's enabled setting separate from its actual task. The Poll button and View menu show the setting. The Watch indicator shows whether the watcher and poll task are running. Currently `W● P○` means only Watch is running, and `!` means Reload is required. Keep both activity states directly readable and put detailed explanations in the tooltip and accessibility label.
- Keep item IDs and the toolbar's autosave identifier stable unless the change explicitly requires a migration. Preserve a user's saved order and removed items. Add new defaults through the default item list. When migrating an existing layout, make the change once and preserve the surrounding order.

## Verify the behavior affected by the change

- Check the live toolbar in Icon and Text, Icon Only, and Text Only at normal and minimum window widths. Compare neighboring item positions before and after state changes. Check the text shown in overflow, which AppKit can derive from `menuFormRepresentation`.
- Check Customize Toolbar separately. Verify the palette entry, moving and removing the item, re-adding it, and opening a new window with the saved layout. Verify that View menu commands still work when their toolbar items are removed.
- For monitoring changes, use a temporary folder to exercise the normal, stopped, and Reload required states. Check real scan or poll behavior separately from the label and report what was tested. Treat NAS behavior as unverified unless tested on the relevant NAS.
- Run `Scripts/test.sh` for affected logic and `Scripts/build-app.sh` when an updated app is requested. Use an AppKit probe or the running app for visual and layout behavior that the core tests cannot cover.
