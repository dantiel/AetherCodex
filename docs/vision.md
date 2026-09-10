# ÆtherCodex — Vision

## Core Idea

A next-gen hyper-responsive yet super-minimalist native Mac editor. Every window can look and function as a widget. Instead of opening different window types, each window transforms or expands in numerous ways while rigorously hiding all clutter.

**Subtraction over addition** — not as style, but as discipline.

## Window States (Morphing, not spawning)

### 1. Compact Widget Mode

Collapses to a floating 2–3 line bar showing only the current line / cursor context. Purely glass. Sits unobtrusively on the desktop. Click or gesture expands back to full editor.

### 2. Full Editor

Default state. Text on glass. Titlebar dissolves when not in use. Sidebar toggles behind traffic lights. Everything that isn't code retreats.

### 3. Distraction-Free / Quick Peek

Collapse sidebar + titlebar + all chrome. Pure text on glass. Toggle with a gesture or hotkey. The editor becomes a luminous surface — nothing between thought and screen.

### 4. Inline Terminal / REPL

The bottom of the editor unfolds into a transparent glass shell. No new window. Terminal is part of the same surface — type code above, see output below. Expand/collapse with a drag.

### 5. Pythia Slide-Over ✅

AI chat panel slides in from the right edge as an overlay rather than a permanent split pane. Invoke with ⌘2, dismiss the same way. Glass overlay breathes the desktop through. **Implemented** — single-pane architecture with FloatingOverlayPanel + EdgeBlurOverlay.

### 6. Single-Pane Editor ✅

Sidebar and Pythia removed from NSSplitView. Editor occupies the full canvas. Both panels float as glass overlays with CAGradientLayer-masked EdgeBlurOverlay transitions. **Implemented** — see `docs/single-pane-architecture.md`.

## Principles

- **One surface, many forms**: Morph, never spawn
- **Invisible chrome**: Toolbars, titlebars, and borders dissolve; only content persists
- **Glass as depth**: The desktop breathes through the window
- **Gesture-driven**: Transformations feel physical — drag, pinch, flick
- **Typography as architecture**: Weight, size, and spacing are the only hierarchy