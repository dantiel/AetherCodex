// swift-tools-version:5.9
import PackageDescription

// Pythia — the companion. The voice, the familiar, the one who replaces Siri in
// the Apple Design Award pantheon ("a sexier waifu in their temple").
//
// Pythia is an *identity*, not a "client". It is the same Pythia that speaks in
// the AetherCodex editor's panel, extended onto iOS. The æther is everywhere:
// the shared brain — AetherOracle — installs on every platform, and Pythia is
// its voice on this one. There is no client/server split here; there is one
// oracle, distributed, with many windows.
//
// The library (target `Pythia`) is the platform-agnostic companion: ÆtherLink
// discovery + the oracle invoke/voice/aegis protocol spoken by the Ruby
// `limen.rb` daemon. It is pure Foundation + SwiftUI — the same slice that will
// feed the WinUI3 and GTK shells.
//
// PythiaCompanionApp is the native SwiftUI application. On iOS it is wrapped by
// an Xcode app target (see README); the package keeps the source type-checkable
// against macOS too so the companion stays honest to a shared-core posture.
let package = Package(
    name: "Pythia",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "Pythia", targets: ["Pythia"])
    ],
    targets: [
        .target(
            name: "Pythia",
            path: "Sources/Pythia"
        ),
        .target(
            name: "PythiaCompanionApp",
            dependencies: ["Pythia"],
            path: "Sources/PythiaCompanionApp"
        )
    ]
)
