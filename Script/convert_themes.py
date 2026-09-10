#!/usr/bin/env python3
"""
convert_themes.py v3 — Complete TextMate → AetherCodex YAML pipeline.

Parses EVERY field from .tmTheme files:
  - Global settings (background, foreground, caret, selection, lineHighlight, invisibles)
  - gutterSettings (background, divider, foreground, selectionBackground, selectionForeground, selectionBorder)
  - semanticClass → tags + class
  - All scope entries

Intelligently decorates with AetherCodex-specific fields:
  - Glass parameters derived from theme luminance
  - Sidebar/ruler background derived from editor background
  - Markdown/markup scopes derived from theme palette
  - Merges with existing YAML — preserves manual edits
"""

import os, re, sys, colorsys
from pathlib import Path

TM_BUNDLES_DIRS = [
    os.path.expanduser("~/Library/Application Support/TextMate/Bundles"),
    os.path.expanduser("~/Library/Application Support/TextMate/Managed/Bundles"),
]
OUT_DIR    = Path(__file__).resolve().parent.parent / "AetherCodex" / "Resources" / "Themes"

OUT_DIR.mkdir(parents=True, exist_ok=True)

def find_tm_themes():
    """Find all .tmTheme files using os.walk to avoid glob metachar issues with [brackets]."""
    files = []
    for base in TM_BUNDLES_DIRS:
        if not os.path.isdir(base):
            continue
        for root, dirs, filenames in os.walk(base):
            for fn in filenames:
                if fn.endswith('.tmTheme'):
                    files.append(Path(root) / fn)
    return files
# ── Helpers ─────────────────────────────────────────────────────────

def hex_to_rgb(hex_str):
    h = hex_str.replace("0x","").replace("#","")
    return (int(h[0:2],16), int(h[2:4],16), int(h[4:6],16))

def rgb_to_hex(r, g, b):
    return f"0x{int(r):02X}{int(g):02X}{int(b):02X}"

def hex_to_hsl(hex_str):
    r,g,b = [c/255.0 for c in hex_to_rgb(hex_str)]
    h,l,s = colorsys.rgb_to_hls(r,g,b)
    return (h, l, s)

def hsl_to_hex(h, l, s):
    r,g,b = colorsys.hls_to_rgb(h, l, s)
    return rgb_to_hex(r*255, g*255, b*255)

def luminance(hex_str):
    r,g,b = hex_to_rgb(hex_str)
    return 0.299*r + 0.587*g + 0.114*b

def dim_color(hex_str, factor):
    r,g,b = hex_to_rgb(hex_str)
    return rgb_to_hex(r*factor, g*factor, b*factor)

def lighten_color(hex_str, amount):
    """Add amount (0-255) to each channel, clamping."""
    r,g,b = hex_to_rgb(hex_str)
    return rgb_to_hex(min(r+amount,255), min(g+amount,255), min(b+amount,255))

def darken_color(hex_str, amount):
    r,g,b = hex_to_rgb(hex_str)
    return rgb_to_hex(max(r-amount,0), max(g-amount,0), max(b-amount,0))

def shift_hue(hex_str, degrees):
    h,l,s = hex_to_hsl(hex_str)
    h = (h + degrees/360.0) % 1.0
    return hsl_to_hex(h, l, s)

def lerp_alpha(base_hex, alpha):
    """Convert solid hex to RRGGBBAA with given alpha (0.0-1.0)."""
    h = base_hex.replace("0x","").replace("#","")
    if len(h) == 8:
        h = h[:6]  # strip existing alpha
    a = hex(int(alpha * 255))[2:].upper().zfill(2)
    return f"0x{h}{a}"

def parse_font_style(s):
    if not s or not s.strip():
        return {}
    if s.strip() == "":
        return {"clear": True}
    parts = s.strip().lower().split()
    return {
        "bold": "bold" in parts,
        "italic": "italic" in parts,
        "underline": "underline" in parts,
        "strikethrough": "strikethrough" in parts or "strike-through" in parts,
    }

def normalize_hex(h):
    if not h:
        return (None, False)
    h = re.sub(r'^0x', '#', h.strip(), flags=re.I)
    m = re.match(r'^#?([0-9A-Fa-f]{8})$', h)
    if m:
        return (f"0x{m.group(1).upper()}", True)
    m = re.match(r'^#?([0-9A-Fa-f]{6})$', h)
    if m:
        return (f"0x{m.group(1).upper()}", False)
    m = re.match(r'^#?([0-9A-Fa-f]{3})$', h)
    if m:
        r,g,b = m.group(1)
        return ("0x" + f"{r*2}{g*2}{b*2}".upper(), False)
    return (None, False)

def build_style(settings):
    fg_raw, _ = normalize_hex(settings.get("foreground"))
    bg_raw, _ = normalize_hex(settings.get("background"))
    has_font_style_key = "fontStyle" in settings
    fs_value = settings.get("fontStyle", "")
    clear_traits = has_font_style_key and (not fs_value or not fs_value.strip())
    font = parse_font_style(fs_value) if not clear_traits else {}

    fg = fg_raw
    bg = bg_raw

    has_traits = (has_font_style_key or any(
        font.get(k) for k in ["bold","italic","underline","strikethrough"]
    )) or bg is not None or clear_traits

    if not has_traits:
        return fg if fg else "0xFFFFFF"
    else:
        d = {}
        if fg: d["color"] = f'"{fg}"'
        if bg: d["background"] = f'"{bg}"'
        if clear_traits:
            d["bold"] = "false"
            d["italic"] = "false"
            d["underline"] = "false"
        else:
            if font.get("bold"): d["bold"] = "true"
            if font.get("italic"): d["italic"] = "true"
            if font.get("underline"): d["underline"] = "true"
            if font.get("strikethrough"): d["strikethrough"] = "true"
        return d

# ── XML Plist Parser ────────────────────────────────────────────────

def parse_plist(filepath):
    import xml.etree.ElementTree as ET
    with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()
    # Installed themes sometimes contain vertical tabs in labels, forbidden by
    # XML 1.0. Sanitize only illegal controls, without modifying source bundles.
    content = re.sub(r'[\x00-\x08\x0B\x0C\x0E-\x1F]', '', content)
    root = ET.fromstring(content)
    plist_dict = root.find('dict')
    if plist_dict is None:
        return None
    result = {}
    key = None
    for child in plist_dict:
        if child.tag == 'key':
            key = child.text.strip() if child.text else None
        elif key == 'name' and child.tag == 'string':
            result['name'] = child.text.strip() if child.text else None
            key = None
        elif key == 'author' and child.tag == 'string':
            result['author'] = child.text.strip() if child.text else None
            key = None
        elif key == 'comment' and child.tag == 'string':
            result['comment'] = child.text.strip() if child.text else None
            key = None
        elif key == 'uuid' and child.tag == 'string':
            result['uuid'] = child.text.strip() if child.text else None
            key = None
        elif key == 'semanticClass' and child.tag == 'string':
            result['semanticClass'] = child.text.strip() if child.text else None
            key = None
        elif key == 'gutterSettings' and child.tag == 'dict':
            result['gutterSettings'] = child
            key = None
        elif key == 'settings' and child.tag == 'array':
            result['settings'] = child
            key = None
    return result

def parse_gutter_settings(gutter_elem):
    """Parse gutterSettings dict → {background, divider, foreground,
    selectionBackground, selectionForeground, selectionBorder}."""
    import xml.etree.ElementTree as ET
    result = {}
    key = None
    for child in gutter_elem:
        if child.tag == 'key':
            key = child.text.strip() if child.text else None
        elif child.tag == 'string' and key:
            result[key] = child.text.strip() if child.text else ""
            key = None
    return result

def parse_settings_array(settings_elem):
    import xml.etree.ElementTree as ET
    global_settings = {}
    scopes = {}

    entries = settings_elem.findall('dict')
    for entry in entries:
        entry_scope = None
        entry_settings_dict = None
        key = None

        for child in entry:
            if child.tag == 'key':
                key = child.text.strip() if child.text else None
            elif child.tag == 'string' and key == 'scope':
                entry_scope = child.text.strip() if child.text else None
                key = None
            elif child.tag == 'dict' and key == 'settings':
                entry_settings_dict = child
                key = None

        if entry_settings_dict is None:
            continue

        settings = {}
        sk = None
        for child in entry_settings_dict:
            if child.tag == 'key':
                sk = child.text.strip() if child.text else None
            elif child.tag == 'string' and sk:
                settings[sk] = child.text.strip() if child.text else ""
                sk = None

        if entry_scope is None:
            for k, v in settings.items():
                if k not in global_settings or not global_settings[k]:
                    global_settings[k] = v
        else:
            for scope in entry_scope.split(','):
                scope = scope.strip()
                if not scope:
                    continue
                style = build_style(settings)
                if scope not in scopes:
                    scopes[scope] = style

    return global_settings, scopes

# ── Intelligent Decorators ──────────────────────────────────────────

def derive_glass_params(global_bg, kind):
    """Derive glass parameters from editor background luminance."""
    if not global_bg:
        global_bg = "0x0D0D0D" if kind == "dark" else "0xF5F5F5"

    lum = luminance(global_bg)
    is_dark = kind == "dark"

    if is_dark:
        # Dark themes: cooler glass tint, stronger effects for deeper backgrounds
        # glassTint: subtle blue/violet derived from background
        tint_h, tint_l, tint_s = hex_to_hsl(global_bg)
        tint_h = 0.67  # blue-violet hue
        tint_s = 0.15
        tint_l = max(0.12, lum / 255 * 0.8)
        glass_tint = hsl_to_hex(tint_h, tint_l, tint_s)

        darkness = lum / 255.0  # 0=black, 1=white
        glass_tint_strength = 0.55 + (1 - darkness) * 0.20  # 0.55-0.75
        blur_strength = 0.40 + (1 - darkness) * 0.25       # 0.40-0.65
        editor_opacity = 0.55 + (1 - darkness) * 0.25      # 0.55-0.80
        sidebar_opacity = 0.70 + (1 - darkness) * 0.20     # 0.70-0.90
        shadow_strength = (1 - darkness) * 0.7             # 0.0-0.7
        line_spacing = 2.5 + (1 - darkness) * 2.0          # 2.5-4.5

        return {
            "glassTintColor": f'"{glass_tint}"',
            "glassTint": round(glass_tint_strength, 2),
            "glassBlurStrength": round(blur_strength, 2),
            "glassStyle": "regular",
            "textShadowStrength": round(shadow_strength, 1),
            "lineSpacing": round(line_spacing, 1),
            "editorBackgroundOpacity": round(editor_opacity, 2),
            "sidebarBackgroundOpacity": round(sidebar_opacity, 2),
            "rootBlurMaterial": "fullScreenUI",
            "rootBlendingMode": "behindWindow",
            "pythiaGlassMaterial": "menu",
        }
    else:
        # Light themes: warm golden tint, lighter effects
        tint_h, tint_l, tint_s = 0.12, 0.88, 0.25  # warm golden
        glass_tint = hsl_to_hex(tint_h, tint_l, tint_s)

        brightness = lum / 255.0  # 1=white, 0=black
        return {
            "glassTintColor": f'"{glass_tint}"',
            "glassTint": 0.55,
            "glassBlurStrength": 0.40,
            "glassStyle": "regular",
            "textShadowStrength": 0.2,
            "lineSpacing": 4.0,
            "editorBackgroundOpacity": 0.40,
            "sidebarBackgroundOpacity": 0.70,
            "rootBlurMaterial": "fullScreenUI",
            "rootBlendingMode": "behindWindow",
            "pythiaGlassMaterial": "menu",
        }

def derive_gutter_params(global_bg, global_fg, gutter_settings, kind):
    """Derive ruler/gutter colors from theme."""
    is_dark = kind == "dark"
    bg_hex = global_bg or ("0x0D0D0D" if is_dark else "0xF5F5F5")
    fg_hex = global_fg or ("0xEEEEEE" if is_dark else "0x333333")

    ruler_bg = None
    ruler_sep = None
    gutter_sel_bg = None
    gutter_sel_fg = None
    gutter_sel_border = None

    # From gutterSettings (TextMate native)
    if gutter_settings:
        gb, _ = normalize_hex(gutter_settings.get("background"))
        gd, _ = normalize_hex(gutter_settings.get("divider"))
        gsb, _ = normalize_hex(gutter_settings.get("selectionBackground"))
        gsf, _ = normalize_hex(gutter_settings.get("selectionForeground"))
        gsbr, _ = normalize_hex(gutter_settings.get("selectionBorder"))
        if gb: ruler_bg = gb
        if gd: ruler_sep = gd
        if gsb: gutter_sel_bg = gsb
        if gsf: gutter_sel_fg = gsf
        if gsbr: gutter_sel_border = gsbr

    # Fallbacks: derive from editor bg
    if not ruler_bg:
        if is_dark:
            ruler_bg = lighten_color(bg_hex, 15)
        else:
            ruler_bg = darken_color(bg_hex, 15)

    if not ruler_sep:
        if is_dark:
            ruler_sep = lerp_alpha(lighten_color(bg_hex, 40), 0.50)
        else:
            ruler_sep = lerp_alpha(darken_color(bg_hex, 40), 0.40)

    if not gutter_sel_bg:
        gutter_sel_bg = "0x002E54" if is_dark else "0xD0D0D0"
    if not gutter_sel_fg:
        gutter_sel_fg = "0xD9D9D9" if is_dark else "0x333333"
    if not gutter_sel_border:
        gutter_sel_border = "0x0070B8" if is_dark else "0xAAAAAA"

    return {
        "rulerBackground": f'"{ruler_bg}"',
        "rulerSeparator": f'"{ruler_sep}"',
        "gutterSelectionBackground": f'"{gutter_sel_bg}"',
        "gutterSelectionForeground": f'"{gutter_sel_fg}"',
        "gutterSelectionBorder": f'"{gutter_sel_border}"',
    }

def blend_color(base, overlay, amount):
    return rgb_to_hex(*(round(a * (1 - amount) + b * amount)
                        for a, b in zip(hex_to_rgb(base), hex_to_rgb(overlay))))

def opaque_color(color):
    return "0x" + color.removeprefix("0x")[:6]

def composite_color(color, backdrop):
    digits = color.removeprefix("0x")
    return blend_color(backdrop, color, int(digits[6:8], 16) / 255) if len(digits) == 8 else color

def relative_luminance(color):
    channels = [c / 255 for c in hex_to_rgb(color)]
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return sum(c * w for c, w in zip(linear, (0.2126, 0.7152, 0.0722)))

def contrast(a, b):
    values = sorted((relative_luminance(a), relative_luminance(b)))
    return (values[1] + 0.05) / (values[0] + 0.05)

def readable_foreground(background, preferred=None):
    if preferred and contrast(opaque_color(preferred), background) >= 4.5:
        return opaque_color(preferred)
    return max(("0x111111", "0xFFFFFF"), key=lambda c: contrast(c, background))

def derive_chrome_palette(background, foreground, selection, gutter_settings, scopes, kind):
    """Preserve native gutter RGB; decorate from the actual theme palette.

    TextMate's alpha describes its own backdrop. Store that source separately;
    use an explicit, stable material tint for our different window composition.
    """
    native, _ = normalize_hex(gutter_settings.get("background"))
    ruler = opaque_color(native) if native else darken_color(background, 14 if kind == "light" else 6)
    candidates = [normalize_hex(gutter_settings.get("selectionBackground"))[0], selection]
    candidates += [_find_scope_color(scopes, scope) for scope in
                   ("storage", "entity.name.function", "keyword", "support.function", "string")]
    accent = next((opaque_color(c) for c in candidates if c and hex_to_hsl(c)[2] >= 0.20), foreground)
    sheet_base = blend_color(ruler, "0xFFFFFF", 0.26 if kind == "light" else 0.12)
    sheet = blend_color(sheet_base, accent, 0.12)
    # Accent icons need contrast on the sheet, without replacing their hue.
    target = "0x111111" if relative_luminance(sheet) > 0.3 else "0xFFFFFF"
    for _ in range(12):
        if contrast(accent, sheet) >= 3:
            break
        accent = blend_color(accent, target, 0.12)
    native_fg, _ = normalize_hex(gutter_settings.get("foreground"))
    return {
        "rulerBackground": f'"{ruler}"',
        "rulerForeground": f'"{readable_foreground(ruler, native_fg or foreground)}"',
        "sidebarBackground": f'"{sheet}"',
        "sidebarForeground": f'"{readable_foreground(sheet, foreground)}"',
        "sidebarAccent": f'"{accent}"',
        "sourceRulerBackground": f'"{native or ruler}"',
    }

def derive_sidebar_bg(editor_bg, kind, name_hint=""):
    """Derive sidebar background with interesting contrast from editor background.
    
    Creates a hue-shifted panel color that complements the editor area.
    Dark themes → cooler blue-violet panel. Light themes → warmer amber panel.
    Some themes get dramatic contrasts based on their name/character.
    """
    if not editor_bg:
        editor_bg = "0x0D0D0D" if kind == "dark" else "0xF5F5F5"
    
    h, l, s = hex_to_hsl(editor_bg)
    name_lower = name_hint.lower()
    
    # Themes that benefit from dramatic contrast panels
    dramatic = any(w in name_lower for w in [
        "oceanic", "solarized", "twilight", "cobalt", "monokai",
        "blackboard", "sunburst", "zenburn", "railscasts", "vibrant",
        "spacecadet", "clouds midnight", "pastels on dark", "slush"
    ])
    
    if kind == "dark":
        if dramatic:
            # Strong hue shift: deep blue-violet panel
            h_new = 0.62  # blue-violet
            s_new = max(0.08, s * 0.5)
            l_new = min(0.35, l + 0.08)
        else:
            # Subtle cool shift
            h_new = (h + 0.08) % 1.0  # slight cool shift
            s_new = max(0.04, s * 0.6)
            l_new = min(0.30, l + 0.06)
    else:
        if dramatic:
            # Strong warm panel for light themes
            h_new = 0.10  # golden
            s_new = max(0.06, s * 0.4)
            l_new = max(0.55, l - 0.08)
        else:
            # Subtle warm shift
            h_new = (h - 0.05) % 1.0
            s_new = max(0.03, s * 0.5)
            l_new = max(0.50, l - 0.05)
    
    return f'"{hsl_to_hex(h_new, l_new, s_new)}"'

def derive_tags(semantic_class, name, kind):
    """Derive tags from semanticClass or theme name."""
    tags = [kind]
    if semantic_class:
        parts = semantic_class.split(".")
        for p in parts:
            if p not in ("theme", kind, "") and not p.startswith("theme"):
                tags.append(p)
    if len(tags) <= 1:
        slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
        for part in slug.split("-"):
            if part and part not in tags and part != kind:
                tags.append(part)
                break
    return tags[:4]  # max 4 tags

def derive_markdown_scopes(global_bg, global_fg, scopes, kind):
    """Derive markdown/markup scopes from existing theme palette.
    Returns a list of YAML lines for the scopes section."""
    is_dark = kind == "dark"
    bg = global_bg or ("0x0D0D0D" if is_dark else "0xF5F5F5")
    fg = global_fg or ("0xEEEEEE" if is_dark else "0x333333")

    # Find key colors from existing scopes for intelligent derivation
    keyword_color = _find_scope_color(scopes, "keyword")
    string_color = _find_scope_color(scopes, "string")
    comment_color = _find_scope_color(scopes, "comment")
    function_color = _find_scope_color(scopes, "entity.name.function")
    type_color = _find_scope_color(scopes, "entity.name.class")

    # Fallbacks
    if not keyword_color: keyword_color = fg
    if not string_color: string_color = fg
    if not comment_color: comment_color = fg
    if not function_color: function_color = fg
    if not type_color: type_color = fg

    # Code block background: darker/lighter than editor bg
    if is_dark:
        code_bg = darken_color(bg, 8)
    else:
        code_bg = darken_color(bg, 20)

    lines = []
    # Markup base
    lines.append(f'  markup: "{fg}"')

    # Headings — use a vibrant color (keyword or function), bold, sized
    heading_color = keyword_color
    lines.append(f"  markup.heading:")
    lines.append(f'    color: "{heading_color}"')
    lines.append(f"    bold: true")
    for i in range(1, 7):
        size = {1: 2.0, 2: 1.75, 3: 1.55, 4: 1.35, 5: 1.15, 6: 1.0}[i]
        lines.append(f"  markup.heading.{i}:")
        lines.append(f'    color: "{heading_color}"')
        lines.append(f"    bold: true")
        lines.append(f"    fontSize: {size}")

    # Bold / Italic
    lines.append(f"  markup.bold:")
    lines.append(f'    color: "{fg}"')
    lines.append(f"    bold: true")
    lines.append(f"  markup.italic:")
    lines.append(f'    color: "{fg}"')
    lines.append(f"    italic: true")

    # Links — string color, underline
    lines.append(f"  markup.link:")
    lines.append(f'    color: "{string_color}"')
    lines.append(f"    underline: true")
    lines.append(f"  markup.link.url:")
    lines.append(f'    color: "{string_color}"')
    lines.append(f"    underline: true")

    # Code
    lines.append(f"  markup.code.block:")
    lines.append(f'    color: "{comment_color}"')
    lines.append(f'    background: "{code_bg}"')
    lines.append(f"  markup.code.inline:")
    lines.append(f'    color: "{comment_color}"')
    lines.append(f'    background: "{code_bg}"')

    # Quote
    if is_dark:
        quote_bg = lighten_color(bg, 5)
    else:
        quote_bg = darken_color(bg, 8)
    lines.append(f"  markup.quote:")
    lines.append(f'    color: "{comment_color}"')
    lines.append(f"    italic: true")
    lines.append(f'    background: "{quote_bg}"')

    # Rule
    lines.append(f"  markup.rule:")
    lines.append(f'    color: "{comment_color}"')
    lines.append(f"    bold: true")

    # Strikethrough
    lines.append(f"  markup.strikethrough:")
    lines.append(f'    color: "{comment_color}"')
    lines.append(f"    strikethrough: true")

    # List checked
    lines.append(f"  markup.list.checked:")
    lines.append(f'    color: "{function_color}"')
    lines.append(f"    bold: true")

    return lines

def _find_scope_color(scopes, target):
    """Find a color from scope dict — tries exact match, then prefix match."""
    if target in scopes:
        s = scopes[target]
        if isinstance(s, str):
            return s.strip('"')
        if isinstance(s, dict) and "color" in s:
            return s["color"].strip('"')
    # Prefix match
    for scope, style in sorted(scopes.items(), key=lambda x: -len(x[0])):
        if scope.startswith(target) or target.startswith(scope):
            if isinstance(style, str):
                return style.strip('"')
            if isinstance(style, dict) and "color" in style:
                return style["color"].strip('"')
    return None

def slugify(name):
    slug = re.sub(r"[‘’']", '', name.lower())
    slug = re.sub(r'[^a-z0-9]+', '-', slug)
    slug = re.sub(r'-+', '-', slug)
    return slug.strip('-')

# ── YAML Merge ──────────────────────────────────────────────────────

def parse_existing_yaml(path):
    """Parse existing YAML into a dict of top-level fields.
    Used for merge — don't overwrite manual edits."""
    if not path.exists():
        return {}
    result = {}
    try:
        text = path.read_text()
        in_scopes = False
        for line in text.split("\n"):
            stripped = line.strip()
            if stripped.startswith("scopes:"):
                in_scopes = True
                continue
            if in_scopes:
                continue
            if ":" in stripped and not stripped.startswith("#"):
                key, _, val = stripped.partition(":")
                key = key.strip()
                val = val.strip().strip('"')
                if key and not key.startswith(" "):
                    result[key] = val
    except Exception:
        pass
    return result

def is_manually_edited(existing, key, auto_value):
    """Check if a field was manually edited. Always regenerate auto-decorated fields."""
    # Always regenerate sidebar/gutter/ruler — user wants decorator improvements applied
    always_regenerate = {
        "sidebarBackground", "rulerBackground", "rulerSeparator",
        "rulerForeground", "sourceRulerBackground", "sidebarAccent", "sidebarForeground",
        "gutterSelectionBackground", "gutterSelectionForeground", "gutterSelectionBorder",
    }
    if key in always_regenerate:
        return False
    if key not in existing:
        return False
    old = existing[key]
    auto = str(auto_value).strip('"')

    # Old hardcoded defaults for dark themes
    old_dark_defaults = {
        "glassTintColor": "0x665599", "glassTint": "0.7", "glassBlurStrength": "0.5",
        "editorBackgroundOpacity": "0.73", "sidebarBackgroundOpacity": "0.85",
        "textShadowStrength": "0.6", "lineSpacing": "4.0",
    }
    old_light_defaults = {
        "glassTintColor": "0xDDBB88", "glassTint": "0.55", "glassBlurStrength": "0.4",
        "editorBackgroundOpacity": "0.4", "sidebarBackgroundOpacity": "0.7",
        "textShadowStrength": "0.2", "lineSpacing": "4.0",
    }

    if key in old_dark_defaults and old == old_dark_defaults[key]:
        return False
    if key in old_light_defaults and old == old_light_defaults[key]:
        return False

    return old != auto

# ── Main ─────────────────────────────────────────────────────────────

def main():
    import xml.etree.ElementTree as ET

    tm_files = find_tm_themes()
    print(f"Found {len(tm_files)} .tmTheme files\n")

    force = "--force" in sys.argv
    theme_filter = None
    for arg in sys.argv[1:]:
        if arg.startswith("--theme="):
            theme_filter = arg.split("=", 1)[1].lower()

    # Deduplicate: prefer theme with MOST scopes when same slug
    slug_map = {}  # slug -> (scope_count, path)
    converted = 0
    skipped = 0

    for tm_path in sorted(tm_files):
        try:
            tm_path_str = str(tm_path)
            plist = parse_plist(tm_path_str)
            if not plist or 'name' not in plist or 'settings' not in plist:
                continue

            name = plist['name']
            semantic_class = plist.get('semanticClass', '')
            gutter_elem = plist.get('gutterSettings')
            gutter_settings = parse_gutter_settings(gutter_elem) if gutter_elem is not None else {}

            global_settings, scopes = parse_settings_array(plist['settings'])

            global_bg, _    = normalize_hex(global_settings.get('background'))
            global_fg, _    = normalize_hex(global_settings.get('foreground'))
            global_caret, _ = normalize_hex(global_settings.get('caret'))
            global_sel, _   = normalize_hex(global_settings.get('selection'))
            global_line, _  = normalize_hex(global_settings.get('lineHighlight'))
            global_invis, _ = normalize_hex(global_settings.get('invisibles'))

            # Determine kind
            kind = "dark"
            if global_bg:
                r,g,b = hex_to_rgb(global_bg)
                lum = 0.299*r + 0.587*g + 0.114*b
                kind = "light" if lum > 128 else "dark"
            # Alpha backgrounds cannot be classified from RGB alone. Honor the
            # explicit TextMate appearance, otherwise infer from foreground.
            if 'light' in semantic_class.lower():
                kind = 'light'
            elif 'dark' in semantic_class.lower():
                kind = 'dark'
            elif global_bg and len(global_bg) == 10 and global_fg:
                kind = 'light' if luminance(global_fg) < 128 else 'dark'
            source_bg = global_bg
            if global_bg:
                global_bg = composite_color(global_bg, '0xFFFFFF' if kind == 'light' else '0x181818')

            slug = slugify(name)
            scope_count = len(scopes)
            # A personal bundle overrides the managed upstream copy even when
            # upstream contains more scopes.
            priority = (int(str(tm_path).startswith(TM_BUNDLES_DIRS[0] + os.sep)), scope_count)

            # Dedup: if we've seen this slug, only keep the one with more scopes
            if slug in slug_map:
                prev_count, prev_path = slug_map[slug]
                if priority <= prev_count:
                    continue  # skip this one — previous is better
            slug_map[slug] = (priority, str(tm_path))

            if theme_filter and theme_filter not in slug:
                continue
            
            out_path = OUT_DIR / f"{slug}.yml"
            
            # Skip existing themes unless --force
            if out_path.exists() and not force:
                continue
            
            # ── Derive AetherCodex fields ──
            glass = derive_glass_params(global_bg, kind)
            gutter = derive_gutter_params(global_bg, global_fg, gutter_settings, kind)
            palette = derive_chrome_palette(global_bg or '0x181818', global_fg or '0xEEEEEE',
                                           global_sel, gutter_settings, scopes, kind)
            gutter.update(palette)
            sidebar_bg = palette['sidebarBackground']
            tags = derive_tags(semantic_class, name, kind)

            # ── Merge with existing ──
            existing = parse_existing_yaml(out_path)

            # Build YAML lines
            lines = []
            lines.append(f"# Converted from TextMate theme: {name}")
            lines.append(f"# Source: {tm_path_str}")
            lines.append(f"name: {slug}")
            lines.append(f"kind: {kind}")
            if source_bg:
                lines.append(f'sourceEditorBackground: "{source_bg}"')

            if semantic_class:
                lines.append(f"class: {semantic_class}")
            if tags:
                tag_str = ", ".join(tags)
                lines.append(f"tags: [{tag_str}]")

            lines.append("")
            lines.append("# Global editor colors")
            lines.append("editor:")
            lines.append(f'  background: "{global_bg or "0x0D0D0D"}"')
            lines.append(f'  foreground: "{global_fg or "0xEEEEEE"}"')
            lines.append(f'  caret: "{global_caret or "0xFFFFFF"}"')
            lines.append(f'  selection: "{global_sel or "0x333366"}"')
            lines.append(f'  lineHighlight: "{global_line or "0x232323"}"')
            if global_invis:
                lines.append(f'  invisibles: "{global_invis}"')

            # Preserve global font style
            global_font_style = global_settings.get('fontStyle', '').strip().lower()
            if global_font_style:
                for trait in global_font_style.split():
                    if trait in ('bold', 'italic', 'underline'):
                        lines.append(f"  {trait}: true")

            lines.append("")
            lines.append("# ── AetherCodex Chrome (auto-decorated) ──")
            for key in ["glassTintColor", "glassTint", "glassBlurStrength", "glassStyle",
                         "textShadowStrength", "lineSpacing", "editorBackgroundOpacity",
                         "sidebarBackgroundOpacity", "rootBlurMaterial", "rootBlendingMode",
                         "pythiaGlassMaterial"]:
                val = glass.get(key)
                if val is not None:
                    if is_manually_edited(existing, key, val):
                        saved = existing[key]
                        lines.append(f'{key}: "{saved}"' if saved.lower().startswith('0x') else f'{key}: {saved}')
                    else:
                        lines.append(f"{key}: {val}")

            lines.append("")
            lines.append("# ── Gutter & Sidebar (auto-decorated) ──")
            for key in ["rulerBackground", "rulerForeground", "sourceRulerBackground", "rulerSeparator",
                         "sidebarAccent", "sidebarForeground",
                         "gutterSelectionBackground", "gutterSelectionForeground",
                         "gutterSelectionBorder"]:
                val = gutter.get(key)
                if val is not None:
                    if is_manually_edited(existing, key, val):
                        lines.append(f"{key}: {existing[key]}")
                    else:
                        lines.append(f"{key}: {val}")

            sb_key = "sidebarBackground"
            if is_manually_edited(existing, sb_key, sidebar_bg):
                lines.append(f"{sb_key}: {existing[sb_key]}")
            else:
                lines.append(f"{sb_key}: {sidebar_bg}")

            lines.append("")
            lines.append("scopes:")

            # ── Plain base ──
            # The editor surface owns the global background; applying it to
            # every glyph produces opaque rectangles on top of the material.
            plain_style = build_style({k: v for k, v in global_settings.items() if k != 'background'})
            if isinstance(plain_style, str):
                lines.append(f'  plain: "{plain_style}"')
            elif isinstance(plain_style, dict):
                lines.append("  plain:")
                for k in ['color', 'background', 'bold', 'italic', 'underline', 'strikethrough']:
                    if k in plain_style:
                        lines.append(f"    {k}: {plain_style[k]}")

            # ── Anchors ──
            gf = global_fg or "0xEEEEEE"
            anchors = {
                "entity": gf, "markup": gf, "punctuation": gf,
                "preprocessor": gf, "tag": gf, "attribute": gf,
                "storage": gf, "support": gf,
            }
            for an, ac in anchors.items():
                if an not in scopes:
                    scopes[an] = ac

            # ── Sort ──
            sorted_scopes = sorted(scopes.items(),
                key=lambda x: (x[0].count('.'), len(x[0]), x[0]))

            # ── Write scopes ──
            for scope, style in sorted_scopes:
                # Native markup styles are authoritative too.
                if isinstance(style, str):
                    lines.append(f'  {scope}: "{style}"')
                elif isinstance(style, dict):
                    lines.append(f"  {scope}:")
                    for k in ['color', 'background', 'bold', 'italic', 'underline', 'strikethrough']:
                        if k in style:
                            lines.append(f"    {k}: {style[k]}")

            # ── Append markdown scopes (auto-decorated) ──
            lines.append("")
            lines.append("  # ── Markdown (auto-decorated) ──")
            md_lines = derive_markdown_scopes(global_bg, global_fg, scopes, kind)
            keep = True
            for line in md_lines:
                if line.startswith('  ') and not line.startswith('    ') and line.strip().endswith(':'):
                    keep = line.strip()[:-1] not in scopes
                if keep:
                    lines.append(line)

            # ── Write ──
            out_path.write_text('\n'.join(lines) + '\n')
            print(f"  ✓ {slug} ({len(scopes)} scopes, {len(md_lines)} md)")
            converted += 1

        except Exception as e:
            print(f"  ✗ {tm_path.name}: {e}")
            import traceback
            traceback.print_exc()
            skipped += 1

    print(f"\nConverted {converted}, skipped {skipped}, output: {OUT_DIR}")

if __name__ == "__main__":
    main()
