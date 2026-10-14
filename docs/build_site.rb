#!/usr/bin/env ruby
# ÆtherCodex docs site builder — markdown chapters → styled HTML.
# Two shelves share one glass template:
#   · the Ætheric Canon (six essays, one argument)
#   · the Concepts (the software's unique ideas, one page each)
#
# Usage: ruby docs/build_site.rb

require 'kramdown'

ROOT = File.expand_path(__dir__)
OUT  = File.join(ROOT, 'chapters')
Dir.mkdir(OUT) unless Dir.exist?(OUT)

CANON_SUBTITLE = 'The Ætheric Canon — six essays, one argument'

CANON = [
  ['aetheric-engineering', 'Ætheric Engineering'],
  ['the-hermetic-manifest', 'The Hermetic Manifest'],
  ['the-power-of-the-unknown', 'The Power of the Unknown'],
  ['tabula-smaragdina-aetherica', 'Tabula Smaragdina Ætherica'],
  ['aetheric-aeternal-engineering', 'Ætheric Æternal Engineering'],
  ['the-technodyssey', 'The Technodyssey'],
]

CONCEPTS = [
  ['architecture',             'The Architecture',            'One oracle, many shells — the shared core and its native surfaces.'],
  ['mnemosyne',                'Mnemosyne & Aegis',           'The memory cascade — one crystal, many facets.'],
  ['companions',               'The Council',                 'Twelve voices, one aether — the specialists and the project manager.'],
  ['timeline',                 'Development History',         'A quiet lineage, traced by founding month and year.'],
  ['single-pane-architecture', 'Single-Pane Architecture',    'The window is a glass athanor — the editor breathes alone.'],
  ['markdown-rendering',       'Markdown & Rich Text',        'Native rendering — no WebView, no JavaScript execution.'],
  ['syntax-theme-renaissance', 'Syntax & Theme Renaissance',  '52 themes, 84 capture names, one unified cascade.'],
  ['tool-result-wire-protocol','Tool-Result Wire Protocol',   'One path carries meaning, the other carries presence.'],
  ['app-intents-and-snippets', 'App Intents & Snippets',      'The oracle channel — Siri, Spotlight, Shortcuts.'],
  ['vision',                   'Vision',                      'One surface, many forms — morph, never spawn.'],
]

def template(title, body, subtitle)
  <<~HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>#{title} — ÆtherCodex</title>
        <link rel="stylesheet" href="../styles.css">
    </head>
    <body>
        <div id="eyes-container"></div>
        <div class="cosmic-void">
            <nav>
                <a class="home-link" href="../index.html" title="ÆtherCodex">
                    <span class="aether">Æther</span><span class="codex">Codex</span>
                </a>
                <a href="../index.html#what" data-i18n="nav.features">Features</a>
                <a href="../index.html#companions" data-i18n="nav.council">Council</a>
                <a href="../index.html#architecture" data-i18n="nav.architecture">Architecture</a>
                <a href="../index.html#chapters" data-i18n="nav.canon">Canon</a>
                <a href="../index.html#concepts" data-i18n="nav.concepts">Concepts</a>
                <a href="../index.html#timeline" data-i18n="nav.timeline">Timeline</a>
                <span class="nav-spacer"></span>
                <span class="lang-switch" role="group" aria-label="Language">
                    <button type="button" class="lang-btn active" data-lang="en" aria-pressed="true">EN</button>
                    <button type="button" class="lang-btn" data-lang="de" aria-pressed="false">DE</button>
                    <button type="button" class="lang-btn" data-lang="es" aria-pressed="false">ES</button>
                    <button type="button" class="lang-btn" data-lang="zh" aria-pressed="false">中文</button>
                </span>
                <a href="https://github.com/dantiel/AetherCodex" target="_blank" rel="noopener" title="Source on GitHub" data-i18n="nav.source">Source</a>
                <a class="nav-cta" href="../index.html#buy" data-i18n="nav.buy">Buy · $69</a>
            </nav>

            <header class="oracle-header">
                <div class="logo-container">
                    <h1 class="logo" style="font-size:2.4rem;">
                        <span class="aether">Æther</span><span class="codex">Codex</span>
                    </h1>
                    <p class="subtitle">#{subtitle}</p>
                </div>
            </header>

            <main class="content">
                <article class="prose">
                    #{body}
                </article>
            </main>

            <footer class="oracle-footer">
                <p><em data-i18n="footer.tagline">Precision in the code plane = precision in the astral plane.</em></p>
                <div class="runes">✦ ✧ ✦</div>
            </footer>
        </div>
        <script src="../i18n.js"></script>
        <script src="../eyes.js"></script>
    </body>
    </html>
  HTML
end

LANG_LABELS = { 'en' => 'English', 'de' => 'Deutsch', 'es' => 'Español', 'zh' => '中文' }.freeze

# Every canon page (essay or index) carries a language bar linking the same
# text in the other three languages. Single source of truth, injected by the
# builder — no hand-written cross-links to drift out of sync.
def canon_lang_bar(slug, current_lang)
  base = slug.sub(/-(de|es|zh)\z/, '')
  parts = %w[en de es zh].map do |lang|
    target = lang == 'en' ? base : "#{base}-#{lang}"
    label  = LANG_LABELS[lang]
    if target == slug
      %(<span class="lang-jump current" aria-current="true">#{label}</span>)
    else
      %(<a class="lang-jump" href="./#{target}.html" hreflang="#{lang}">#{label}</a>)
    end
  end
  %(<nav class="canon-lang-bar" aria-label="Read this text in another language">#{parts.join('<span class="lang-dot">·</span>')}</nav>)
end

def build(slug, title, subtitle, lang = nil)
  src = File.join(ROOT, "#{slug}.md")
  raise "missing #{src}" unless File.exist?(src)

  md = File.read(src)
  body = md.sub(/^#\s+.*$/, '')
  # kramdown's default parser reads ~~~ fences, not ```; normalise the GFM fences
  # so code blocks render as <pre><code> instead of flattened paragraphs.
  body = body.gsub(/^```([A-Za-z0-9_+\-.]*)\s*$/, '~~~\1')
  body = Kramdown::Document.new(body, auto_ids: true).to_html
  body += "\n" + canon_lang_bar(slug, lang) if lang

  out = File.join(OUT, "#{slug}.html")
  File.write(out, template(title, body, subtitle))
  puts "  ✦ wrote chapters/#{slug}.html"
end

CANON.each { |slug, title| build(slug, title, CANON_SUBTITLE, 'en') }
CONCEPTS.each { |slug, title, subtitle| build(slug, title, subtitle) }

# The canon index (links to all chapters).
canon = File.join(ROOT, 'aetheric-canon.md')
if File.exist?(canon)
  build('aetheric-canon', 'The Ætheric Canon', CANON_SUBTITLE, 'en')
end

# ── Translations of the Ætheric Canon ────────────────────────────────────
# Every language carries the full six essays plus a canon index, each
# cross-linked among its own language and back to the English original.

CANON_I18N = {
  'de' => {
    'subtitle'       => 'Der Ätherische Kanon — sechs Essays, ein Argument',
    'aetheric-engineering'          => 'Ätherische Technik',
    'the-hermetic-manifest'         => 'Das Hermetische Manifest',
    'the-power-of-the-unknown'      => 'Die Macht des Unbekannten',
    'tabula-smaragdina-aetherica'   => 'Tabula Smaragdina Ætherica',
    'aetheric-aeternal-engineering' => 'Ätherische Äternale Technik',
    'the-technodyssey'              => 'Die Technodyssee',
    'aetheric-canon'                => 'Der Ätherische Kanon',
  },
  'es' => {
    'subtitle'       => 'El Canon Etérico — seis ensayos, un argumento',
    'aetheric-engineering'          => 'Ingeniería Etérica',
    'the-hermetic-manifest'         => 'El Manifiesto Hermético',
    'the-power-of-the-unknown'      => 'El Poder de lo Desconocido',
    'tabula-smaragdina-aetherica'   => 'Tabula Smaragdina Ætherica',
    'aetheric-aeternal-engineering' => 'Ingeniería Etérica Eterna',
    'the-technodyssey'              => 'La Tecnodisea',
    'aetheric-canon'                => 'El Canon Etérico',
  },
  'zh' => {
    'subtitle'       => '《以太经典》— 六篇文论，同一论旨',
    'aetheric-engineering'          => '以太工程学',
    'the-hermetic-manifest'         => '赫尔墨斯宣言',
    'the-power-of-the-unknown'      => '未知之力',
    'tabula-smaragdina-aetherica'   => '以太翠玉录',
    'aetheric-aeternal-engineering' => '以太·永恒工程学',
    'the-technodyssey'              => '科技奥德赛',
    'aetheric-canon'                => '以太经典',
  },
}

CANON_I18N.each do |lang, t|
  CANON.each do |slug, _title|
    src = "#{slug}-#{lang}.md"
    build("#{slug}-#{lang}", t[slug], t['subtitle'], lang) if File.exist?(File.join(ROOT, src))
  end
  idx = "aetheric-canon-#{lang}.md"
  build("aetheric-canon-#{lang}", t['aetheric-canon'], t['subtitle'], lang) if File.exist?(File.join(ROOT, idx))
end

puts '  ✧ done.'