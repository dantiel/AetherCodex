# Single-Pane Architecture — The Magnum Opus

> *The window is a glass athanor. The editor breathes alone. Sidebar and Pythia attend as floating presences — patient familiars that appear when summoned, dissolve when dismissed. Only the content remains.*

## Overview

The single-pane architecture transforms ÆtherCodex from a traditional three-pane `NSSplitViewController` into a single editor surface with floating glass overlay panels. The sidebar (file browser) and Pythia (AI assistant) exist as lightweight `FloatingOverlayPanel` instances — `NSVisualEffectView` siblings of the split view, not split-view items. This achieves the hermetic design principle: *subtraction over addition, depth over decoration*.

### Before → After

| Aspect | Before (Nigredo) | After (Rubedo) |
|--------|-----------------|----------------|
| Split panes | 3 (sidebar, editor, pythia) | 1 (editor only) |
| Sidebar | NSSplitViewItem at leading edge | FloatingOverlayPanel, slides from left |
| Pythia | NSSplitViewItem at trailing edge | FloatingOverlayPanel, slides from right |
| Top-edge blur | NSSplitViewItemAccessoryViewController .soft | Preserved (unchanged) |
| Glass boundary | Divider-based | EdgeBlurOverlay — CAGradientLayer mask |
| Resize | Split divider drag | ResizeHandleView drag strip (5pt) |

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────┐
│                    NSWindow.contentView                   │
│  ┌────────────────────────────────────────────────────┐  │
│  │              glassBg (full-window)                  │  │
│  │  ┌──────────────────────────────────────────────┐  │  │
│  │  │              glassTintView                    │  │  │
│  │  │  ┌────────────────────────────────────────┐  │  │  │
│  │  │  │            contentView                  │  │  │  │
│  │  │  │                                        │  │  │  │
│  │  │  │  ┌──────┐  ┌──────────────────┐  ┌────┐│  │  │  │
│  │  │  │  │sidebar│  │                  │  │pyth││  │  │  │
│  │  │  │  │float  │  │  NSSplitView     │  │float││  │  │  │
│  │  │  │  │panel  │  │  (editorItem)    │  │panel││  │  │  │
│  │  │  │  │       │  │                  │  │     ││  │  │  │
│  │  │  │  │[glass]│  │  EditorView      │  │[gls]││  │  │  │
│  │  │  │  │[blur ]│  │  (NSScrollView)  │  │[blur]││  │  │  │
│  │  │  │  │[drag ]│  │                  │  │[drag]││  │  │  │
│  │  │  │  │       │  │  ┌────────────┐  │  │     ││  │  │  │
│  │  │  │  │       │  │  │edge blur L │  │  │     ││  │  │  │
│  │  │  │  │       │  │  │edge blur R │  │  │     ││  │  │  │
│  │  │  │  │       │  │  └────────────┘  │  │     ││  │  │  │
│  │  │  │  └──────┘  └──────────────────┘  └────┘│  │  │  │
│  │  │  │                                        │  │  │  │
│  │  │  │  topTabBarHost (collapsed sidebar)     │  │  │  │
│  │  │  │  statusBar (24pt, .titlebar)           │  │  │  │
│  │  │  └────────────────────────────────────────┘  │  │  │
│  │  └──────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

## Component Reference

### `EdgeBlurOverlay` (`AetherCodex/App/EdgeBlurOverlay.swift`)

Reusable `NSVisualEffectView` with a `CAGradientLayer` mask producing a directional glass-to-content fade. The gradient goes from fully opaque (glass visible) to fully transparent, creating a seamless transition from overlay into content.

```swift
// Direction enum
enum EdgeBlurDirection {
    case leading   // opaque at right, transparent at left
    case trailing  // opaque at left, transparent at right
    case top       // opaque at bottom, transparent at top
    case bottom    // opaque at top, transparent at bottom
}

// Usage
let leftBlur = EdgeBlurOverlay(direction: .leading, blurWidth: 24)
```

**Key design choices:**
- Material: `.underWindowBackground` with `.behindWindow` blending — matches the liquid glass aesthetic
- Mask: two-stop `CAGradientLayer` (black→clear), `startPoint`/`endPoint` set per direction
- `isFlipped = true` for correct AppKit coordinate mapping
- `gradientLayer.frame` synced in `layout()` override

### `FloatingOverlayPanel` (`MainWindowController.swift`)

Private final class in `MainWindowController.swift`. Composes three subviews:

1. **`glassView`** — `NSVisualEffectView` with `.fullScreenUI` material and `.withinWindow` blending. Hosts the content, edge blur, and resize handle as subviews.

2. **`edgeBlur`** — `EdgeBlurOverlay` at the inner boundary (`blurWidth: 24`). For the sidebar panel, blur is at the right edge; for Pythia, it's at the left edge.

3. **`resizeHandle`** — `ResizeHandleView` (5pt strip) atop the edge blur. Shows `resizeLeftRight` cursor, tracks mouse drag delta.

**Layout by edge:**

- **`.leading` (sidebar)**: Panel anchored to host leading edge. Content → edgeBlur → resizeHandle (left-to-right).
- **`.trailing` (pythia)**: Panel anchored to host trailing edge. ResizeHandle → edgeBlur → content (left-to-right).

**Lifecycle:**
1. `prepare(in:atEdge:)` — adds to host view hierarchy, sets up constraints, starts hidden (`alpha=0, isHidden=true`)
2. `show(width:)` — fades in (0.2s, easeInEaseOut), fires `onWidthChanged`
3. `dismiss()` — fires `onWidthChanged(0)`, fades out (0.18s), sets `isHidden=true`
4. `applyResizeDelta(_:)` — clamps to `[160, 500]`, updates width constraint, fires `onWidthChanged`

**Animation guard pattern:**
```swift
guard !isAnimatingSidebar else { return }  // prevent rapid-toggle race
isAnimatingSidebar = true
// ... animation ...
DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
    self?.isAnimatingSidebar = false
}
```

### `ResizeHandleView` (`MainWindowController.swift`)

Private final class. 5pt-wide vertical strip with three-event drag tracking:

- `mouseDown` — records initial `locationInWindow.x`
- `mouseDragged` — computes delta from last position, fires `onDrag(delta)`
- `resetCursorRects` — sets `.resizeLeftRight` cursor

No mouse-up handler needed — `onDrag` delivers incremental deltas; the owning panel accumulates them.

### `EditorViewController` Overlay Support (`AetherCodex/App/EditorViewController.swift`)

**Properties:**
```swift
var sidebarOverlayWidth: CGFloat = 0   // didSet → updateOverlayInsets()
var pythiaOverlayWidth: CGFloat = 0    // didSet → updateOverlayInsets()
private var leftEdgeBlur: EdgeBlurOverlay?   // lazy, created on first show
private var rightEdgeBlur: EdgeBlurOverlay?  // lazy, created on first show
```

**`updateOverlayInsets()`** — uses `NSScrollView.contentInsets` (asymmetric) rather than `NSTextContainer.textContainerInset.width` (symmetric):

```swift
var insets = scrollView.contentInsets
insets.left  = gutterWidth + sidebarOverlayWidth
insets.right = pythiaOverlayWidth
scrollView.contentInsets = insets
```

Edge blur overlays are positioned as fixed subviews of the scroll view (not subviews of the text view, so they don't scroll):

- **Left blur**: `x = sidebarOverlayWidth - 24`, fills full height
- **Right blur**: `x = bounds.width - pythiaOverlayWidth`, fills full height

Blur overlays are hidden (`isHidden=true`) when their corresponding panel width is 0, and lazily created on first need.

**`viewDidLayout()`** merges gutter width + overlay widths into `contentInsets`, preserving scroll offset when only the gutter width changes.

### Session Persistence (`AetherCodex/App/SessionState.swift`)

No changes were needed to the `SessionState` data model. The existing `sidebarWidth` and `pythiaWidth` keys in `UserDefaults` now represent floating panel widths rather than split divider positions:

```
session.sidebarWidth  →  FloatingOverlayPanel width (sidebar)
session.pythiaWidth   →  FloatingOverlayPanel width (pythia)
session.fileBrowserOverlay → boolean toggle state
session.windows       →  JSON-encoded [WindowState] for multi-window
```

**Width flow:**
1. `saveSessionState()` reads `sidebarFloatingPanel.width` / `pythiaFloatingPanel.width`
2. `restoreSidebarWidth()` / `restorePythiaWidth()` apply to panels on launch
3. `onWidthChanged` callbacks (set up in `setupFloatingOverlayPanels`) auto-persist on every resize drag

### `PythiaViewController` (`AetherCodex/App/PythiaViewController.swift`)

Unchanged from the pre-overlay architecture. Loads a `WKWebView` with transparent background (`drawsBackground = false`) displaying static placeholder HTML. The view is used as the `contentView` of the Pythia `FloatingOverlayPanel`.

## Layout Coordination

The overlay system coordinates layout across three layers:

```
Layer 3 (topmost):    FloatingOverlayPanel.glassView   [.withinWindow blending]
Layer 2 (editor):     NSSplitView (editorItem only)     [NSScrollView + edge blurs]
Layer 1 (background): glassBg + glassTintView           [.regular glass]
```

**Key constraint:** Overlay panels are siblings of `splitVC.splitView` inside `contentView`, not descendants. This ensures:
- `.withinWindow` blending sees the editor content + background glass beneath
- Panels can span full window height without coordinating with split-view insets
- No interference with the `NSSplitViewItemAccessoryViewController` top-edge blur compositor discovery

**Top-edge blur preservation:** The `editorItem` retains its `NSSplitViewItemAccessoryViewController` with `.preferredScrollEdgeEffectStyle = .soft` (macOS 26.1+). This is the only way to get system compositor-managed scroll-edge blur — overlays sit above this effect, not within it.

## Shortcuts

| Key | Action |
|-----|--------|
| ⌘1 | Toggle sidebar overlay |
| ⌘2 | Toggle Pythia overlay |

## Security & Performance (Validatio)

### Security — Zero Attack Surface
- **No command injection**: Zero `NSTask`/`Process`, zero `system()`, zero `eval()` anywhere in the codebase
- **No JavaScript injection**: `PythiaViewController` loads static HTML only — no user-supplied content
- **No path traversal**: `GoToFilePanel` skips symlinks with `skipDescendants` to prevent traversal outside project root
- **No data exposure**: No network calls, no telemetry, no file exfiltration paths
- **Binary-safe**: Binary file detection prevents crash on non-text content

### Performance — Production-Ready
- **Memory**: 7 `NSVisualEffectViews` at peak compositing load (glassBg, glassTintView, 4 edge blurs, statusBar + 2 floating panels). Acceptable for 2018+ Macs.
- **Animation**: 0.15–0.2s with standard AppKit timing curves; `isAnimating` guards prevent animation stacking
- **Inactive panels**: Hidden via `isHidden=true` + `alphaValue=0` when not visible — no compositing cost
- **Debounce**: Scroll-based re-highlighting debounced at 150ms; gutter width change debounced at 500ms
- **Minor note**: `saveSessionState()` fires per-frame during window resize without debounce (low severity — `UserDefaults` is memory-mapped)

## Troubleshooting

### Overlay panel doesn't appear
1. Check `panel.parentView != nil` — panels must be `prepare(in:atEdge:)` called before `show()`
2. Check `isAnimatingSidebar`/`isAnimatingPythia` guards — rapid toggles within 250ms are blocked
3. Verify `contentView` exists in the window hierarchy

### Editor text obscured behind overlay
1. Verify `editorViewController.sidebarOverlayWidth` / `pythiaOverlayWidth` are being set by `onWidthChanged` callbacks
2. Check `NSScrollView.contentInsets` is applied in `updateOverlayInsets()`
3. Ensure `viewDidLayout()` is being called — it merges gutter + overlay widths

### Edge blur not visible
1. Blur overlays are only created when `sidebarOverlayWidth > 0` or `pythiaOverlayWidth > 0`
2. Blur overlays sit inside the scroll view — verify scroll view bounds are correct
3. Check `EdgeBlurOverlay.direction` matches the panel edge

### Window resize causes visual glitches
1. `viewDidLayout()` on EditorViewController refreshes overlay insets and blur positions
2. The `FloatingOverlayPanel` height is pinned to host bounds — height always matches
3. Very narrow windows (<340px) may show overlapping panels — this is intentional graceful degradation

## Related Files

| File | Role |
|------|------|
| `AetherCodex/App/MainWindowController.swift` | `FloatingOverlayPanel`, `ResizeHandleView`, `setupFloatingOverlayPanels`, toggle methods |
| `AetherCodex/App/EditorViewController.swift` | `sidebarOverlayWidth`, `pythiaOverlayWidth`, `updateOverlayInsets()`, `viewDidLayout()` |
| `AetherCodex/App/SessionState.swift` | `sidebarWidth`, `pythiaWidth` persistence via UserDefaults |

## Hermetic Principles

- **Subtraction over addition**: Three panes became one; chrome dissolved into content
- **Depth over decoration**: Glass, shadow, and gradient masks create spatial depth without visual weight
- **Typography as structure**: Editor text is the only hierarchy — panels appear only when summoned
- **System harmony**: `NSSplitViewItemAccessoryViewController` + `.withinWindow` blending = native-feeling glass
- **Invisible chrome**: The sidebar and Pythia exist only in the æther until called — ⌘1, ⌘2