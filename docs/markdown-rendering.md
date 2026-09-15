# Markdown and rich-text rendering

Pythia uses a local block parser in MarkdownBody.swift and native SwiftUI
views. Foundation AttributedString handles inline Markdown. There is no WebView
or JavaScript execution in this path. Tables use a horizontally bounded Grid;
code highlighting uses an independent TreeSitterEngine, never the editor's
shared language state. Streaming stays plain to avoid parsing every token.

The rich-text editor uses NSTextView with separate attributed storage inside
the existing SwiftUI scroll surface. MarkdownRichCodec is an editable subset,
not a complete CommonMark or GFM implementation. RTF uses AppKit import/export.
Tables use NSTextTable, including Markdown table import/export. Local inserted
images are attachments in RTF and file-URL references in Markdown; Markdown
images are not embedded portable assets. Remote images are not auto-fetched.
Nested lists, complex HTML, reference images and other unsupported constructs
still require source editing.

## Round-trip guarantee

Unmodified Markdown round-trips byte-exact. Every structural block carries its
pristine source as document metadata (`originalLine` / `renderedLine` for
paragraphs and list items, `originalBlock` / `renderedBlock` for fenced code),
so `source()` replays the original bytes verbatim unless the visible text was
edited. On edit, the codec falls back to reconstruction: the block's semantic
content (fonts, colours and paragraph styles stripped) is compared against the
stored snapshot; only a mismatch triggers syntax re-synthesis from the live
attributes. This is exercised by `Tests/MarkdownRenderingTests.swift`
(`testHeadingAndCodeBlockRoundTripByteExact`,
`testFullVocabularyRoundTripByteExact`).

Edited content reconstructs the supported vocabulary — headings, emphasis,
inline code, links, strikethrough, lists, quotes, tables and fences — from the
current attributes. Edited tables may normalize whitespace.

## Format-aware toolbar

The floating controls bar offers only the capabilities the open document
actually serializes.

| Capability | Markdown | RTF |
| --- | --- | --- |
| Bold / italic / strikethrough | ✓ | ✓ |
| Font family / size | — | ✓ |
| Underline / text colour | — | ✓ |
| Bullet / ordered / task list | ✓ | ✓ (native `NSTextList`) |
| Task toggle (`- [ ]` ⇄ `- [x]`) | ✓ | — |
| Block quote / code block | ✓ | ✓ (native `NSTextBlock`) |
| Heading 1–3 | ✓ (`#`) | ✓ (native `headerLevel`) |
| Table / local image | ✓ | ✓ |
| Source view | ✓ | — |

Markdown hides font, underline and colour controls because those attributes
have no Markdown syntax and would be silently dropped on save; RTF exposes the
full TextEdit palette instead of a source toggle.

Markup styling reuses the existing generated markup.heading.*, markup.link,
markup.code.* and related TextMate scope cascade, plus the sidebar accent.
There is no competing rich-text-only palette. Prose font settings affect
headings and body typography. Authored RTF colors remain document-owned.

The ruler's background and separator are fixed; only ticks carry the fade
mask. Rich-text scroll-edge styling is scoped to the ScrollView rather than
its background. Pythia's header/footer are native safeAreaBar regions.
Actual compositor blur still requires visual testing in the running app.

Historical comparison: HEAD:Pythia/chamber.html contains an earlier minimal
JavaScript renderer (headings, inline emphasis/code/links, lists, fences and
rules). It did not implement tables. The original CoffeeScript application
was not found in this checkout; complete feature parity is not asserted.
The user's existing deletion of chamber.html was left untouched.