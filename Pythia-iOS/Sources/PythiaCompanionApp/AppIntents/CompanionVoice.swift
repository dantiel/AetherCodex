import AppIntents
import Pythia

/// The pantheon as a compile-time `AppEnum` — a mirror of `pythiaCompanions`.
///
/// `AppEnum` requires static, compiler-known cases, so the runtime roster cannot be
/// enumerated directly. The `rawValue` is the companion `id`, keeping routing in
/// correspondence with `PythiaChatModel.activeCompanions` (both send
/// `active_companions: [id]` on the wire). Keep the cases in sync with
/// `Pythia/CompanionRoster.swift`.
public enum CompanionVoice: String, AppEnum, CaseIterable {
    case pythia
    case owl
    case kitsune
    case phoenix
    case ouroboros
    case bastet
    case fenrir
    case undine
    case schwan
    case drache
    case corax
    case jindujun
    case solomon

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Companion"

    public static var caseDisplayRepresentations: [CompanionVoice: DisplayRepresentation] = [
        .pythia: "🐍 Pythia",
        .owl: "🦉 Owl",
        .kitsune: "🦊 Kitsune",
        .phoenix: "🔥 Phoenix",
        .ouroboros: "🐍 Ouroboros",
        .bastet: "🐈 Bastet",
        .fenrir: "🐺 Fenrir",
        .undine: "🌊 Undine",
        .schwan: "🦢 Schwan",
        .drache: "🐉 Drache",
        .corax: "⬛ Corax",
        .jindujun: "☁️ Jindujun",
        .solomon: "👑 Solomon",
    ]

    /// The companion glyph, for the snippet header.
    public var glyph: String {
        pythiaCompanions.first { $0.id == rawValue }?.glyph ?? "🐍"
    }

    /// The display name, for the snippet header.
    public var displayName: String {
        pythiaCompanions.first { $0.id == rawValue }?.displayName ?? "Pythia"
    }
}
