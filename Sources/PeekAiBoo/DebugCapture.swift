import AppKit

/// `--print-geometry`: prints a window's frame to stdout as `NAME x y w h`
/// (screen points) whenever it's on screen. A capture script reads these
/// lines to `screencapture -R` just the relevant rect, instead of the whole
/// screen — useful since the desktop this runs on is rarely just our app.
@MainActor
enum DebugCapture {
    static var printGeometry = false

    static func printFrame(_ name: String, _ window: NSWindow) {
        guard printGeometry, window.isVisible else { return }
        let f = window.frame
        print("\(name) \(Int(f.minX)) \(Int(f.minY)) \(Int(f.width)) \(Int(f.height)) level=\(window.level.rawValue)")
        fflush(stdout)
    }
}
