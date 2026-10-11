#!/usr/bin/env ruby
# ÆtherCodex docs site builder — markdown chapters → styled HTML.
# Mirrors the OrniFlight docs build (MD → HTML + shared template), but the
# front matter is the Iridescent Black Square — the cover of the aetheric canon.
#
# Usage: ruby docs/build_site.rb

require 'kramdown'

ROOT = File.expand_path(__dir__)
OUT  = File.join(ROOT, 'chapters')
Dir.mkdir(OUT) unless Dir.exist?(OUT)

CHAPTERS = [
  ['aetheric-engineering', 'Ætheric Engineering'],
  ['the-hermetic-manifest', 'The Hermetic Manifest'],
  ['the-power-of-the-unknown', 'The Power of the Unknown'],
  ['tabula-smaragdina-aetherica', 'Tabula Smaragdina Ætherica'],
  ['aetheric-aeternal-engineering', 'Ætheric Æternal Engineering'],
]

def template(title, body, opts = {})
  back = opts[:back] || 'index.html'
  front = opts[:front] || 'index.html'
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
                <a href="../index.html#chapters" data-i18n="nav.canon">Canon</a>
                <a href="../index.html#tools" data-i18n="nav.capabilities">Capabilities</a>
                <span class="nav-spacer"></span>
                <span class="lang-switch" role="group" aria-label="Language">
                    <button type="button" class="lang-btn active" data-lang="en" aria-pressed="true">EN</button>
                    <button type="button" class="lang-btn" data-lang="de" aria-pressed="false">DE</button>
                </span>
                <a href="https://github.com/dantiel/AetherCodex" target="_blank" rel="noopener" title="Source on GitHub" data-i18n="nav.source">Source</a>
                <a class="nav-cta" href="../index.html#buy" data-i18n="nav.buy">Buy · $69</a>
            </nav>

            <header class="oracle-header">
                <div class="logo-container">
                    <h1 class="logo" style="font-size:2.4rem;">
                        <span class="aether">Æther</span><span class="codex">Codex</span>
                    </h1>
                    <p class="subtitle">The Ætheric Canon — five essays, one argument</p>
                </div>
            </header>

            <main class="content">
                <section class="black-square-front">
                    <img src="../images/the-iridescent-black-square.png" alt="The Iridescent Black Square — by Kashmiri Malewitch">
                    <p class="byline">The Iridescent Black Square — by Kashmiri Malewitch</p>
                </section>

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

CHAPTERS.each do |slug, title|
  src = File.join(ROOT, "#{slug}.md")
  raise "missing #{src}" unless File.exist?(src)

  md = File.read(src)
  # The first H1 becomes the article title (front matter), the rest is body.
  body = md.sub(/^#\s+.*$/, '')
  body = Kramdown::Document.new(body, auto_ids: true).to_html

  out = File.join(OUT, "#{slug}.html")
  File.write(out, template(title, body))
  puts "  ✦ wrote chapters/#{slug}.html"
end

# The canon index (links to all chapters).
canon = File.join(ROOT, 'aetheric-canon.md')
if File.exist?(canon)
  body = File.read(canon).sub(/^#\s+.*$/, '')
  body = Kramdown::Document.new(body, auto_ids: true).to_html
  File.write(File.join(OUT, 'aetheric-canon.html'), template('The Ætheric Canon', body))
  puts '  ✦ wrote chapters/aetheric-canon.html'
end

puts '  ✧ done.'