// A regular app with no windows, for the Side Buttons E2E checks: while it
// is active, the topmost window on screen belongs to some other app - like
// Preview, Mail or Safari after their last window closed.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate()
app.run()
