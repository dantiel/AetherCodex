# Pythia — iOS

The Apple Design Award pillar for iOS: the oracle, native on the phone.

## Architecture

Pythia is the *companion* — the same familiar that speaks in the AetherCodex
editor's panel, extended onto the phone. iOS **cannot host the Ruby brain** — the
daemon (`AetherOracle/ruby/standalone_daemon.rb`) is a framed STDIN/STDOUT protocol
driven by `NSTask` (macOS-only), and `AetherOracle/ruby/limen.rb` is the
HTTP/WebSocket layer. So on iOS the companion reaches the local oracle over the
LAN, reusing the exact `limen.rb` contract:

| Endpoint | Method | Purpose |
|---|---|---|
| `/aether/heartbeat` | GET | discovery — name, path, port, busy, active_tasks |
| `/aether/invoke` | POST | chat — `{prompt, type:"chat"}` → `{answer, html}` |
| `/aether/voices` | GET | Vox roster |
| `/aether/speak` | POST | speak `{text, voice}` |
| `/aether/aegis` | GET | reasoning state |

The daemon binds `0.0.0.0`, so it is reachable from the phone; discovery scans the
Mac's address across ports `4550…4610`.

## Targets

- **Pythia** — the platform-agnostic companion (Foundation + SwiftUI). This is the
  *voice* of the shared brain — **AetherOracle** (Ruby brain + CTreeSitter +
  Resources) — which installs on every platform. The æther is everywhere; there is
  no client/server split, only one distributed oracle with many windows. This same
  slice will feed the WinUI3 and GTK shells.
- **PythiaCompanionApp** — the native SwiftUI application.

## Build

The package type-checks against macOS out of the box:

```sh
swift build
```

To run on a device/simulator, wrap the app target in an Xcode app target:

1. **Xcode** → File → New → Project → iOS App, name `Pythia`.
2. Drag `Sources/PythiaCompanionApp/*.swift` and the `Pythia` folder into the
   app target (or add the local Swift package as a dependency and let the app
   target import `Pythia`).
3. Set the bundle id, drop `Info.plist` as the target's Info.plist (it carries the
   ATS local-networking exemption + `NSLocalNetworkUsageDescription`).
4. Run against a simulator while the Mac's daemon is listening.

> **Note:** the local Xcode installation has the iOS 26.2 SDK but no installed
> simulator runtime (`xcodebuild -showsdks` lists it, `simctl list runtimes` is
> empty). Download the iOS platform from Xcode → Settings → Components to run.

## Correspondence

The companion roster (`pythiaCompanions`) mirrors `AetherCodex/App/PythiaPanel.swift`
and the daemon's `ready` frame. It is a mirror, not a duplicate — keep them in sync
when the pantheon changes.
