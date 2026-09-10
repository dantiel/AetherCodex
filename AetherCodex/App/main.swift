import Cocoa

// Explicitly create the shared application instance first.
// Without @main or NSApplicationMain(), NSApp is nil until
// NSApplication.shared is called.
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate

app.run()