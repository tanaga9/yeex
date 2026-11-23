import AppKit
import CoreGraphics

guard CGSessionCopyCurrentDictionary() != nil else {
    let message = "YeeX needs a macOS desktop session. Open YeeX.app from Finder or a regular Terminal window.\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(EXIT_FAILURE)
}

let application = NSApplication.shared
let delegate = Application()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
