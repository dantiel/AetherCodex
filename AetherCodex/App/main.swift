import Cocoa
import Darwin

// Never let a broken pipe (Ruby daemon died mid-write) kill the whole app.
// writeInput() uses raw write(2), whose default SIGPIPE disposition terminates
// the process; ignoring it here lets the write return EPIPE so the existing
// revive/error path can recover instead of crash at startup.
signal(SIGPIPE, SIG_IGN)

// Explicitly create the shared application instance first.
// Without @main or NSApplicationMain(), NSApp is nil until
// NSApplication.shared is called.
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate

app.run()