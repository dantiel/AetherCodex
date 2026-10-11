// swift-tools-version:5.9
import PackageDescription

// AetherCodex — the macOS editor shell.
//
// The shared brain lives in `AetherOracle/` (the extracted core): the Ruby
// oracle (ruby/), the tree-sitter engine (treesitter/), and the per-platform
// CLI specs (platform/). That repo is pure Ruby + C — no Swift, no UI assets.
// This package (the macOS shell) owns its own visual grammar in
// `AetherCodex/Resources/`; the iOS companion (Pythia-iOS) and the future
// WinUI3/GTK shells each own their slice of the same core.
let package = Package(
    name: "AetherCodex",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "AetherCodex", targets: ["AetherCodex"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CTreeSitter",
            path: "AetherOracle/treesitter",
            sources: [
                "core/lib.c",
                "bridge.c",
                "grammars/swift/swift_parser.c",
                "grammars/python/python_parser.c",
                "grammars/python/python_scanner.c",
                "grammars/javascript/javascript_parser.c",
                "grammars/javascript/javascript_scanner.c",
                "grammars/ruby/ruby_parser.c",
                "grammars/ruby/ruby_scanner.c",
                "grammars/rust/rust_parser.c",
                "grammars/rust/rust_scanner.c",
                "grammars/go/go_parser.c",
                "grammars/html/html_parser.c",
                "grammars/html/html_scanner.c",
                "grammars/css/css_parser.c",
                "grammars/css/css_scanner.c",
                "grammars/json/json_parser.c",
                "grammars/bash/bash_parser.c",
                "grammars/bash/bash_scanner.c",
                "grammars/c/c_parser.c",
                "grammars/php/php_parser.c",
                "grammars/php/php_scanner.c",
                "grammars/markdown/markdown_parser.c",
                "grammars/markdown/markdown_scanner.c",
                "grammars/markdown_inline/markdown_inline_parser.c",
                "grammars/markdown_inline/markdown_inline_scanner.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("_POSIX_C_SOURCE", to: "200112L"),
                .unsafeFlags(["-Wno-ambiguous-macro", "-Wno-macro-redefined"]),
            ]
        ),
        .target(
            name: "CSafeLayout",
            path: "AetherCodex/Vendor/CSafeLayout",
            sources: ["SafeLayoutBridge.m"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "AetherOracleResources",
            path: "AetherCodex/Resources",
            sources: ["AetherOracleResources.swift"],
            resources: [.process("resources")]
        ),
        .executableTarget(
            name: "AetherCodex",
            dependencies: ["CTreeSitter", "CSafeLayout", "AetherOracleResources"],
            path: "AetherCodex",
            exclude: ["Vendor", "Info.plist", "AetherCodex.entitlements"],
            sources: ["App", "Bridge"]
        ),
        .testTarget(
            name: "AetherCodexTests",
            dependencies: ["AetherCodex"],
            path: "Tests",
            resources: []
        )
    ]
)