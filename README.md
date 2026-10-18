# Claude Desktop Use

A native macOS MCP server that lets Claude operate your Mac: see the screen, move a little orange
**Claude** cursor, click, type, scroll, drag, use shortcuts, the clipboard, the accessibility tree,
windows, AppleScript and the shell.

Written in Swift with no dependencies: ScreenCaptureKit for capture, CGEvent for input, the
Accessibility API for UI elements and windows, and AppKit for the overlay.

## Install

```sh
./install.sh
```

The script builds a release binary, registers it with Claude Code (`claude mcp add`) and Claude
Desktop (`claude_desktop_config.json`), and opens System Settings.

To register it manually, add this to the MCP config:

```json
{ "mcpServers": { "desktop-use": { "command": "/path/to/.build/release/claude-desktop-use" } } }
```

### Permissions

macOS gives these permissions to the **app that launches the server**, not to the binary itself.
For Claude Code that is your terminal; for Claude Desktop it is Claude.app.

- **Accessibility**: mouse, keyboard, UI tree, window control
- **Screen Recording**: screenshots

Grant both under System Settings → Privacy & Security, then restart that app. Claude can check
them with the `permissions` tool.

## How it works

Claude works in a loop: **screenshot → think → act → verify**. Action tools return a fresh
screenshot by default, so most steps are a single call.

**Scope.** `set_scope` picks what Claude sees: a whole display, or a single window (by id or app
name). In window scope:

- screenshots are cropped to the window, so they are sharper and use fewer tokens
- coordinates are relative to the window and follow it when it moves
- keyboard input brings the window back to the front if something else took focus
- if the window is replaced (a dialog closes, a launch panel goes away), the scope moves to the
  same app's next window

`isolated: true` captures the window's own pixels even when other windows cover it.

**Background mode.** `set_scope` with `background: true` lets Claude work in a window **without
bringing it to the front**. You keep using your Mac while Claude works behind your other windows,
and the orange cursor acts as Claude's own separate pointer. `open` with `background: true` launches
apps without them taking focus.

macOS apps accept keystrokes while they're in the background but ignore synthetic mouse input, so
background mode works like this:

| Action | How it's done |
|---|---|
| Screenshots | The window's own pixels, even when it's covered by other windows |
| Typing, keys | Real keystrokes sent straight to the app's process; your keyboard isn't affected |
| Click | Accessibility hit-test: presses buttons and links, places the caret in text, selects rows. A double-click selects a word or opens an item; a triple-click selects a paragraph. |
| Right-click | Opens the element's context menu |
| Scroll | Moves the scroll area's scroll bar |
| Shortcuts | Presses the matching menu item. `cmd+a/c/x/v` act directly on the focused text field, because a background app's Edit menu is disabled. |
| Drag, hover | Not available; use `ui_action` (e.g. `set_value` on a slider), or switch to foreground |

Each result says how the action was done (for example `Pressed AXButton "Add"`), so Claude can
tell when something had no effect. Apps with little accessibility support, such as games and some
canvas-based apps, need foreground mode.

**Games.** Games that lock the pointer, like Minecraft, ignore pointer position and read only mouse
movement. They need the window in front, not background mode:

| Action | Tool |
|---|---|
| Turn the camera | `mouse_look` with `dx`/`dy` (Minecraft: 0.15° per unit, 2400 units per full turn, at default sensitivity) |
| Aim exactly | `look_at` with an angle, a world point, a block face, or where a block should be placed |
| Attack / use | `click` with no x/y, which clicks in place without moving the pointer |
| Hold attack (mine) | `mouse_button` `down`, then `up`, with no x/y |
| Walk, jump, sneak | `key` with `hold_ms`, e.g. `w` for 1500 |

**Exact aiming.** Flying or walking to a spot is imprecise, so building works best by standing
still and aiming. `look_at` does the maths: read `XYZ` and `Facing` from the F3 screen once and pass
them as `position` and `from_yaw`/`from_pitch`, then give targets in world coordinates. For example,
`{"targets": [{"place": [126,-60,-6]}, {"place": [127,-60,-6]}], "click": "right"}` places two blocks
on top of whatever is below them. The server converts angles to mouse units with Minecraft's
sensitivity formula (`sensitivity` sets the slider percentage; default 100%) and tracks the camera
across `look_at` and `mouse_look` calls, so it stays accurate to within a tenth of a degree without
re-reading F3. Batches go far to near so new blocks don't hide later targets, and targets beyond
`reach` are skipped. The server doesn't know what is in the world, so it can't tell when a block is
in the way. If you or the game turn the camera, pass `from_yaw`/`from_pitch` again.

Opening chat or a menu frees the pointer, so press `escape` to get back to the game. Minecraft
pauses whenever it loses focus. Press F3+P in-game to turn that off, so it keeps running while you
talk to Claude in another window.

**Coordinates.** Every x/y is a pixel in the latest screenshot. Screenshots are scaled to at most
1568 px on the long edge and about 1.15 MP, and the server maps clicks back to exact screen
points, including Retina and multiple displays.

**The orange cursor** glides to each target and ripples on click. It never takes clicks or focus,
it is left out of Claude's own screenshots, and it shows up in your screen recordings.

**Your pointer stays yours.** Claude's cursor is separate from your mouse. Hovering only moves the
orange cursor and sends a hover event to the app underneath. Foreground clicks, drags and scrolls
need the real pointer for an instant, so the server moves it to the target, acts, and puts it
straight back where you left it, keeping any movement you made in the meantime.
`move_mouse` with `move_user_pointer: true` is the only action that leaves your pointer somewhere
new; use it for hover effects that ignore synthetic events, such as Dock magnification. In
background mode your pointer is never touched.

## Tools

| Area | Tools |
|---|---|
| Seeing | `screenshot`, `zoom` (native-resolution crop for small text), `set_scope` (display, window, or background window), `list_windows`, `list_displays` |
| Mouse | `click` (left/right/middle, double/triple, modifiers), `move_mouse`, `drag` (two points or a multi-point path), `mouse_button` (down/up), `scroll`, `cursor_position`, `mouse_look` and `look_at` (games) |
| Keyboard | `type_text` (any Unicode; pastes long text and restores the clipboard), `key` (`"cmd+shift+t"`, `"cmd+a delete"`, hold/release) |
| Clipboard | `copy`, `paste`, `clipboard` (text, images and file paths) |
| Accessibility | `ui_tree` (roles, labels, values and on-screen positions in screenshot coordinates), `ui_action` (press, set_value, focus, show_menu, click…) |
| Apps & windows | `open` (apps, files, URLs, deep links), `list_apps`, `window_control` (move, resize, minimize, fullscreen, close) |
| Escape hatches | `run_applescript` (AppleScript/JXA), `run_shell`, `wait`, `permissions` |

Shortcuts follow your current keyboard layout, so `cmd+z` works on AZERTY and similar layouts.
Chromium and Electron apps are switched into full accessibility mode automatically.

## Configuration

| Env var | Default | Effect |
|---|---|---|
| `DESKTOPUSE_OVERLAY` | `1` | `0` hides the orange cursor |
| `DESKTOPUSE_MAX_EDGE` | `1568` | Longest screenshot edge in pixels |

## Safety

This server gives Claude full control of your user account, including the shell. Keep your MCP
client's tool approvals on for anything you don't want to happen automatically. Diagnostics are
written to stderr.

## Rebuilding

After rebuilding, restart **every** Claude session that uses this server. macOS stops answering
screen captures from a rebuilt binary while an older copy started from the same path is still
running; the server reports this as a "Screen capture didn't respond" error.

## Development

```sh
swift build
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | .build/debug/claude-desktop-use
```

| File | Contents |
|---|---|
| `MCPServer.swift` | JSON-RPC over stdio |
| `Tools.swift` | Tool definitions |
| `Scope.swift` | Windows, displays and coordinate mapping |
| `Capture.swift` | ScreenCaptureKit |
| `Input.swift` | Mouse, keyboard and clipboard |
| `Accessibility.swift` | AX tree and actions |
| `Overlay.swift` | The orange cursor |
| `Aim.swift` | Camera tracking and aim maths for `look_at` |
| `Background.swift` | Background mode: focus-without-raise and accessibility-driven actions |
| `System.swift` | Apps, shell and permissions |
