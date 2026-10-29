import ClippboardServices
import Foundation

// XPC services bundled in an app are only reachable by that app.
let delegate = DecoderListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
// Runs the service's main loop; never returns.
listener.resume()
