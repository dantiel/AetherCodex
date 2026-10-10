#!/usr/bin/env python3
"""
backfill_pythia.py — Inject a derived `pythia:` oracle-chamber block into every
theme that lacks one, without touching any other field.

This is the safe sibling of convert_themes.py's in-flow generation: instead of
regenerating scopes/chrome from the .tmTheme source (which would clobber manual
curation), it reads each theme's *existing* YAML, derives the chamber palette
from what is already there, and inserts the block just before `scopes:`.

Curated `pythia:` blocks are authoritative and never overwritten.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import convert_themes as ct

THEMES_DIR = Path(__file__).resolve().parent.parent / "AetherCodex" / "Resources" / "Themes"


def parse_theme(path):
    """Extract top-level + editor-block fields (indentation-aware)."""
    text = path.read_text()
    top = {}
    editor = {}
    scopes = {}
    section = None  # "editor", "scopes", or None

    for raw in text.split("\n"):
        if not raw.strip() or raw.strip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        line = raw.strip()

        # A mapping key at indent 0 starts a new top-level section.
        if indent == 0 and line.endswith(":"):
            section = line[:-1]
            continue

        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        key = key.strip()
        val = val.strip().strip('"')

        if section == "editor" and indent == 2:
            editor[key] = val
        elif section == "scopes":
            if indent == 2 and line.endswith(":"):
                scopes[key] = None
            elif indent == 4 and key == "color":
                # attach to the last seen scope key
                for s in reversed(list(scopes)):
                    if scopes[s] is None:
                        scopes[s] = val
                        break
            elif indent == 2 and not line.endswith(":"):
                scopes[key] = val
        else:
            if indent == 0:
                top[key] = val

    return top, editor, scopes


def main():
    modified = 0
    skipped = 0
    for path in sorted(THEMES_DIR.glob("*.yml")):
        text = path.read_text()
        if "\npythia:" in text or text.startswith("pythia:"):
            skipped += 1
            continue

        top, editor, scopes = parse_theme(path)
        kind = top.get("kind", "dark")
        bg = ct.normalize_hex(editor.get("background"))[0]
        fg = ct.normalize_hex(editor.get("foreground"))[0]
        selection = ct.normalize_hex(editor.get("selection"))[0]

        glass_tint = top.get("glassTint", 0.70 if kind == "dark" else 0.30)
        glass_material = top.get("pythiaGlassMaterial", "menu")
        glass = {"glassTint": glass_tint, "pythiaGlassMaterial": glass_material}

        palette = ct.derive_pythia_palette(bg, fg, scopes, selection, kind, glass)

        block = ["# ── Pythia Oracle Chamber (derived; refine per theme) ──", "pythia:"]
        for key in ["background", "foreground", "baseText", "accent",
                    "complementary", "codeBackground", "codeForeground", "shine"]:
            block.append(f"  {key}: {palette[key]}")
        block.append(f"  glassTint: {palette['glassTint']}")
        block.append(f"  glassMaterial: {palette['glassMaterial']}")

        lines = text.split("\n")
        insert_at = None
        for i, line in enumerate(lines):
            if line.strip() == "scopes:":
                insert_at = i
                break
        if insert_at is None:
            print(f"  ! {path.name}: no scopes: anchor — skipping")
            continue

        out = lines[:insert_at]
        while out and out[-1].strip() == "":
            out.pop()
        out.extend(block)
        out.append("")
        out.extend(lines[insert_at:])
        path.write_text("\n".join(out) + "\n")
        print(f"  ✓ {path.name} ({kind})")
        modified += 1

    print(f"\nBackfilled {modified}, skipped (curated) {skipped}, dir: {THEMES_DIR}")


if __name__ == "__main__":
    main()
