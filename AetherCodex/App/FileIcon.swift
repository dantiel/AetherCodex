import AppKit

// MARK: - File icon registry

/// One place decides which glyph a file wears. The tab strip, the window title
/// badge and the file browser all ask here, so a newly-mapped type appears in
/// every surface at once.
///
/// Resolution order: exact file name (dotfiles, `Makefile`, `Dockerfile`) →
/// basename without extension (`README.md` → `readme`) → extension. Every
/// candidate is validated against the running OS symbol catalog, so a name that
/// a given macOS does not ship silently degrades to the next candidate instead
/// of rendering a blank glyph — no crash, no hole in the layout.
enum FileIcon {
    static let fallback = "doc.text"

    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    /// Symbol for a concrete file (nil → generic document).
    static func symbol(for url: URL?) -> String {
        guard let url else { return fallback }
        return symbol(named: url.lastPathComponent, extension: url.pathExtension)
    }

    /// Symbol for a bare extension (`"swift"`, `"png"`).
    static func symbol(forExtension ext: String) -> String {
        symbol(named: "", extension: ext)
    }

    static func symbol(named name: String, extension ext: String) -> String {
        let key = name.lowercased() + "|" + ext.lowercased()
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        let symbol = firstAvailable(nameCandidates(name.lowercased())
                                    + extensionCandidates(ext.lowercased())) ?? fallback
        lock.lock(); cache[key] = symbol; lock.unlock()
        return symbol
    }

    /// First candidate the running OS actually ships.
    private static func firstAvailable(_ names: [String]) -> String? {
        names.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
    }

    private static func nameCandidates(_ name: String) -> [String] {
        let base = (name as NSString).deletingPathExtension.lowercased()
        return nameTable[name] ?? nameTable[base] ?? []
    }

    private static func extensionCandidates(_ ext: String) -> [String] {
        guard !ext.isEmpty else { return [] }
        return extensionTable[ext] ?? []
    }

    /// Whole-name overrides win over the extension — a `Makefile` is a hammer,
    /// not a plain text document.
    private static let nameTable: [String: [String]] = [
        "makefile": ["hammer"], "gnumakefile": ["hammer"], "cmakelists.txt": ["hammer"],
        "dockerfile": ["shippingbox"], "containerfile": ["shippingbox"], "compose.yaml": ["shippingbox"],
        "gemfile": ["diamond"], "rakefile": ["diamond"], "podfile": ["diamond"],
        "fastfile": ["diamond"], "brewfile": ["cup.and.saucer"], "vagrantfile": ["shippingbox"],
        ".gitignore": ["arrow.triangle.branch"], ".gitattributes": ["arrow.triangle.branch"],
        ".gitmodules": ["arrow.triangle.branch"], ".gitconfig": ["arrow.triangle.branch"],
        ".env": ["lock.shield"], ".env.local": ["lock.shield"],
        "license": ["checkmark.seal"], "licence": ["checkmark.seal"], "copying": ["checkmark.seal"],
        "readme": ["doc.text"], "changelog": ["doc.text"], "contributing": ["doc.text"],
        "authors": ["doc.text"], "todo": ["checklist"],
        "aethercodex": ["gearshape"], "hermetic.manifest": ["scroll"],
        // ── Tooling, manifests & dotfiles ──────────────────────────
        "docker-compose.yml": ["shippingbox"], "docker-compose.yaml": ["shippingbox"],
        "package.swift": ["swift"], "package.resolved": ["shippingbox"],
        "procfile": ["terminal"], "justfile": ["hammer"], "taskfile.yml": ["hammer"],
        "gradlew": ["hammer"], "gradlew.bat": ["hammer"],
        ".bashrc": ["terminal"], ".zshrc": ["terminal"], ".zprofile": ["terminal"],
        ".bash_profile": ["terminal"], ".profile": ["terminal"], ".inputrc": ["terminal"],
        ".editorconfig": ["slider.horizontal.3"], ".swiftformat": ["wand.and.stars"],
        ".swiftlint.yml": ["wand.and.stars"], ".rubocop.yml": ["wand.and.stars"],
        ".npmrc": ["shippingbox"], ".nvmrc": ["shippingbox"], ".tool-versions": ["shippingbox"],
        ".gitkeep": ["arrow.triangle.branch"], ".dockerignore": ["shippingbox"],
        ".ruby-version": ["diamond"], ".rspec": ["diamond"], ".gemrc": ["diamond"],
        // ── Package managers & project manifests ──────────────────
        "cargo.toml": ["shippingbox"], "cargo.lock": ["shippingbox"],
        "go.mod": ["paperplane"], "go.sum": ["paperplane"], "go.work": ["paperplane"],
        "pom.xml": ["hammer"], "build.gradle": ["hammer"], "build.gradle.kts": ["hammer"],
        "settings.gradle": ["hammer"], "gradle.properties": ["slider.horizontal.3"],
        "package.json": ["shippingbox"], "package-lock.json": ["shippingbox"],
        "yarn.lock": ["shippingbox"], "pnpm-lock.yaml": ["shippingbox"], "bun.lockb": ["shippingbox"],
        "deno.json": ["shippingbox"], "deno.jsonc": ["shippingbox"], "deno.lock": ["shippingbox"],
        "requirements.txt": ["curlybraces"], "pyproject.toml": ["curlybraces"], "poetry.lock": ["curlybraces"],
        "uv.lock": ["curlybraces"], "gemfile.lock": ["diamond"],
        "composer.json": ["curlybraces"], "composer.lock": ["curlybraces"],
        "mix.exs": ["curlybraces"], "mix.lock": ["curlybraces"],
        "tsconfig.json": ["slider.horizontal.3"], "jsconfig.json": ["slider.horizontal.3"],
        "dockerfile.dev": ["shippingbox"], "dockerfile.prod": ["shippingbox"],
    ]

    /// Extension table. Language logos (`swift`) exist as SF Symbols; other
    /// languages borrow a semantically apt system glyph instead of a blank tile.
    private static let extensionTable: [String: [String]] = [
        // ── Languages ──────────────────────────────────────────────
        "swift": ["swift"],
        "rb": ["diamond", "curlybraces"], "ruby": ["diamond", "curlybraces"],
        "rake": ["diamond"], "gemspec": ["diamond"], "erb": ["diamond"],
        "py": ["curlybraces"], "pyi": ["curlybraces"], "ipynb": ["chart.bar.doc.horizontal"],
        "js": ["curlybraces"], "mjs": ["curlybraces"], "cjs": ["curlybraces"], "jsx": ["curlybraces"],
        "ts": ["curlybraces"], "tsx": ["curlybraces"], "vue": ["curlybraces"], "svelte": ["curlybraces"],
        "c": ["curlybraces"], "h": ["curlybraces"], "m": ["curlybraces"], "mm": ["curlybraces"],
        "cc": ["curlybraces"], "cpp": ["curlybraces"], "cxx": ["curlybraces"], "hpp": ["curlybraces"],
        "cs": ["curlybraces"], "java": ["cup.and.saucer"], "kt": ["cup.and.saucer"], "kts": ["cup.and.saucer"],
        "rs": ["gearshape.2"], "go": ["paperplane"], "php": ["curlybraces"], "pl": ["curlybraces"],
        "lua": ["curlybraces"], "r": ["chart.bar.doc.horizontal"], "scala": ["curlybraces"],
        "dart": ["curlybraces"], "ex": ["curlybraces"], "exs": ["curlybraces"], "erl": ["curlybraces"],
        "hs": ["curlybraces"], "clj": ["curlybraces"], "fs": ["curlybraces"], "vim": ["curlybraces"],
        "sh": ["terminal"], "bash": ["terminal"], "zsh": ["terminal"], "fish": ["terminal"],
        "ps1": ["terminal"], "bat": ["terminal"], "cmd": ["terminal"],
        // ── Markup & data ──────────────────────────────────────────
        "md": ["text.alignleft", "doc.richtext"], "markdown": ["text.alignleft", "doc.richtext"],
        "mdown": ["text.alignleft", "doc.richtext"], "mkdn": ["text.alignleft", "doc.richtext"],
        "txt": ["doc.plaintext"], "text": ["doc.plaintext"], "log": ["doc.plaintext"],
        "rdoc": ["doc.plaintext"], "out": ["doc.plaintext"],
        "rtf": ["doc.richtext"], "rtfd": ["doc.richtext"],
        "html": ["globe"], "htm": ["globe"], "xhtml": ["globe"],
        "xml": ["chevron.left.forwardslash.chevron.right"], "plist": ["chevron.left.forwardslash.chevron.right"],
        "entitlements": ["chevron.left.forwardslash.chevron.right"], "xib": ["chevron.left.forwardslash.chevron.right"],
        "css": ["paintbrush"], "scss": ["paintbrush"], "sass": ["paintbrush"], "less": ["paintbrush"],
        "yaml": ["list.bullet.indent"], "yml": ["list.bullet.indent"],
        "toml": ["slider.horizontal.3"], "ini": ["slider.horizontal.3"],
        "cfg": ["slider.horizontal.3"], "conf": ["slider.horizontal.3"], "xcconfig": ["slider.horizontal.3"],
        "json": ["curlybraces.square"], "json5": ["curlybraces.square"], "geojson": ["globe"],
        "csv": ["tablecells"], "tsv": ["tablecells"],
        "sql": ["cylinder"], "db": ["cylinder"], "sqlite": ["cylinder"], "sqlite3": ["cylinder"],
        // ── Documents & media ──────────────────────────────────────
        "pdf": ["doc.viewfinder"], "doc": ["doc.richtext"], "docx": ["doc.richtext"],
        "pages": ["doc.richtext"], "ppt": ["doc.richtext"], "pptx": ["doc.richtext"],
        "xls": ["tablecells"], "xlsx": ["tablecells"], "numbers": ["tablecells"],
        "epub": ["book"], "mobi": ["book"],
        "png": ["photo"], "jpg": ["photo"], "jpeg": ["photo"], "gif": ["photo"], "bmp": ["photo"],
        "tiff": ["photo"], "tif": ["photo"], "heic": ["photo"], "webp": ["photo"], "icns": ["photo"],
        "svg": ["square.on.circle"], "ico": ["photo"], "psd": ["photo"], "ai": ["photo"],
        "mp3": ["waveform"], "wav": ["waveform"], "m4a": ["waveform"], "aiff": ["waveform"],
        "flac": ["waveform"], "ogg": ["waveform"], "aac": ["waveform"],
        "mp4": ["film"], "mov": ["film"], "avi": ["film"], "mkv": ["film"], "webm": ["film"], "m4v": ["film"],
        "srt": ["text.alignleft"], "vtt": ["text.alignleft"],
        // ── Archives & binaries ────────────────────────────────────
        "zip": ["doc.zipper"], "tar": ["archivebox"], "gz": ["archivebox"], "tgz": ["archivebox"],
        "bz2": ["archivebox"], "xz": ["archivebox"], "7z": ["archivebox"], "rar": ["archivebox"],
        "dmg": ["shippingbox"], "pkg": ["shippingbox"], "iso": ["shippingbox"],
        "o": ["gearshape.2"], "a": ["archivebox"], "dylib": ["shippingbox"], "so": ["shippingbox"],
        "framework": ["shippingbox"], "xcframework": ["shippingbox"],
        // ── Crypto, config & secrets ───────────────────────────────
        "pem": ["lock.shield"], "crt": ["lock.shield"], "cer": ["lock.shield"],
        "key": ["key"], "p12": ["lock.shield"], "mobileprovision": ["checkmark.seal"],
        "xcprivacy": ["lock.shield"], "env": ["lock.shield"],
        "patch": ["doc.text.magnifyingglass"], "diff": ["doc.text.magnifyingglass"],
        // ── Further languages ──────────────────────────────────────
        "groovy": ["curlybraces"], "gradle": ["curlybraces"], "jl": ["curlybraces"],
        "nim": ["curlybraces"], "zig": ["curlybraces"], "sol": ["curlybraces"],
        "tcl": ["curlybraces"], "coffee": ["cup.and.saucer"], "haml": ["curlybraces"],
        "slim": ["curlybraces"], "elm": ["curlybraces"], "ml": ["curlybraces"], "mli": ["curlybraces"],
        "cr": ["curlybraces"], "vb": ["curlybraces"], "pas": ["curlybraces"], "hx": ["curlybraces"],
        "asm": ["gearshape.2"], "wasm": ["gearshape.2"], "wat": ["gearshape.2"],
        "applescript": ["applescript"], "psm1": ["terminal"], "nu": ["terminal"], "awk": ["terminal"],
        // ── Build artefacts & project files ────────────────────────
        "xcodeproj": ["hammer"], "xcworkspace": ["hammer"], "pbxproj": ["hammer"],
        "resolved": ["shippingbox"], "nib": ["chevron.left.forwardslash.chevron.right"],
        "metal": ["gearshape.2"], "sks": ["gamecontroller"], "ipa": ["shippingbox"], "apk": ["shippingbox"],
        "aar": ["shippingbox"], "jar": ["cup.and.saucer"], "class": ["gearshape.2"],
        "pyc": ["gearshape.2"], "dsym": ["shippingbox"], "swiftmodule": ["swift"],
        // ── Documents, data & records ──────────────────────────────
        "odt": ["doc.richtext"], "tex": ["text.alignleft"], "bib": ["text.alignleft"],
        "rst": ["text.alignleft"], "adoc": ["text.alignleft"], "org": ["text.alignleft"],
        "man": ["doc.plaintext"], "nfo": ["doc.plaintext"], "ans": ["doc.plaintext"],
        "properties": ["slider.horizontal.3"], "prop": ["slider.horizontal.3"], "lock": ["lock.shield"],
        "ndjson": ["curlybraces.square"], "jsonl": ["curlybraces.square"],
        "parquet": ["cylinder"], "avro": ["cylinder"],
        "ics": ["calendar"], "vcf": ["person.crop.circle"], "gpx": ["location"], "kml": ["globe"],
        "md5": ["number"], "sha1": ["number"], "sha256": ["number"],
        // ── Media, fonts & 3-D ─────────────────────────────────────
        "opus": ["waveform"], "mid": ["pianokeys"], "midi": ["pianokeys"],
        "m3u8": ["list.bullet"], "m3u": ["list.bullet"],
        "dng": ["photo"], "cr2": ["photo"], "nef": ["photo"], "arw": ["photo"], "raw": ["photo"],
        "eps": ["square.on.circle"], "ttf": ["textformat"], "otf": ["textformat"], "ttc": ["textformat"],
        "woff": ["textformat"], "woff2": ["textformat"], "eot": ["textformat"],
        "obj": ["cube"], "stl": ["cube"], "gltf": ["cube"], "glb": ["cube"], "fbx": ["cube"],
        "usdz": ["cube"], "blend": ["photo"], "sketch": ["paintbrush"], "afdesign": ["paintbrush"],
        "xd": ["paintbrush"],
        // ── Backups & scratch ──────────────────────────────────────
        "bak": ["clock.arrow.circlepath"], "orig": ["clock.arrow.circlepath"],
        "rej": ["clock.arrow.circlepath"], "swp": ["clock.arrow.circlepath"],
        "swo": ["clock.arrow.circlepath"], "tmp": ["clock.arrow.circlepath"],
        // ── Query, schema & config languages ───────────────────────
        "graphql": ["curlybraces"], "gql": ["curlybraces"],
        "prisma": ["cylinder"], "proto": ["curlybraces"], "capnp": ["curlybraces"],
        "nix": ["curlybraces"], "dhall": ["curlybraces"], "cue": ["curlybraces"],
        // ── Further languages & templates ──────────────────────────
        "d": ["curlybraces"], "f90": ["function"], "f95": ["function"], "f": ["function"],
        "for": ["function"], "f77": ["function"],
        "scm": ["curlybraces"], "ss": ["curlybraces"], "cl": ["curlybraces"],
        "lisp": ["curlybraces"], "el": ["curlybraces"], "rkt": ["curlybraces"],
        "ejs": ["globe"], "hbs": ["curlybraces"], "handlebars": ["curlybraces"],
        "mustache": ["curlybraces"], "njk": ["curlybraces"], "twig": ["paintbrush"],
        "liquid": ["paintbrush"], "pug": ["paintbrush"], "jade": ["paintbrush"],
        "styl": ["paintbrush"], "astro": ["curlybraces"],
        "mdx": ["doc.richtext"], "typ": ["doc.richtext"],
    ]
}