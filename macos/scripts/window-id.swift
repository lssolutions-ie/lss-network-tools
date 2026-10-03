// Prints the CGWindowID of the frontmost on-screen window owned by the given
// application name (kCGWindowOwnerName = CFBundleName, default
// "LSS Network Tools"). Used by scripts/screenshot.sh.
//   swift scripts/window-id.swift ["LSS Network Tools"]
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "LSS Network Tools"
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write("window-id: CGWindowListCopyWindowInfo failed\n".data(using: .utf8)!)
    exit(1)
}
for window in list {
    guard (window["kCGWindowOwnerName"] as? String) == owner,
          (window["kCGWindowLayer"] as? Int) == 0,
          let number = window["kCGWindowNumber"] as? Int,
          let bounds = window["kCGWindowBounds"] as? [String: Any],
          let width = bounds["Width"] as? Double, width > 200 else { continue }
    print(number)
    exit(0)
}
FileHandle.standardError.write("window-id: no window owned by \(owner)\n".data(using: .utf8)!)
exit(2)
