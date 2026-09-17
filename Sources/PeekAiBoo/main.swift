import AppKit
import Foundation
import PeekCore

let features = makeFeatures()
for feature in features {
    if let code = feature.run(arguments: Array(CommandLine.arguments.dropFirst())) {
        exit(code)
    }
}

let paths = Paths.fromEnvironment()
try! paths.ensureDir()

// Another copy is already up: quit rather than fight it for the socket.
if LineServer.isListening(paths.events) {
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// The panel is an NSPanel that's never key or main, so AppKit's automatic
// termination heuristic sees "no windows" and marks this LSUIElement app
// eligible to be killed by the system once it's been idle a few minutes
// (confirmed via `log show`: _kLSApplicationWouldBeTerminatedByTALKey flips
// to 1 with no crash log or console output, matching the self-exit report).
// This is a background watcher, not a document app, so it never wants that.
ProcessInfo.processInfo.disableAutomaticTermination("watches for agent events in the background")

let model = AppModel(
    paths: paths,
    home: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
)
model.features = features

let eventQueue = DispatchQueue(label: "com.mohsensc.peekaiboo.events")
let eventServer = try! LineServer(path: paths.events, queue: eventQueue) { data, connection in
    let event = Event.parse(data)
    connection.close()
    guard let event else { return }
    DispatchQueue.main.async {
        model.ingest(event)
    }
}
// Held for the app's lifetime; nothing else references it.
_ = eventServer

let panel = NotchPanel(app: model)
panel.show()

for feature in features {
    feature.start(app: model)
}

// For screenshot scripts, which can't send the island a synthetic click:
// starts it open instead of waiting for one, and --open-other reaches
// into a question card's Other field the same way.
if CommandLine.arguments.contains("--open") {
    model.isOpen = true
}
if CommandLine.arguments.contains("--open-other") {
    model.debugOpenOtherOnQuestion = true
}
if CommandLine.arguments.contains("--open-settings") {
    // .floating, not just makeKeyAndOrderFront: an accessory-policy app
    // without a real activation doesn't reliably win z-order over whatever
    // already has focus, which a screenshot script always does.
    let window = features.compactMap({ $0 as? Sounds }).first?.showSettings(app: model)
    window?.level = .floating
}

app.run()
