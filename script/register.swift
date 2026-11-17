import Carbon
import Foundation

let id = "top.fuluwa.inputmethod.Wubi86.Hans"
let files = FileManager.default
let shared = URL(fileURLWithPath: "/Library/Input Methods/WA 五笔.app", isDirectory: true)
let user = files.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Input Methods/WA 五笔.app", isDirectory: true)
let app = files.fileExists(atPath: shared.path) ? shared : user
let status = TISRegisterInputSource(app as CFURL)
guard status == noErr else {
    print("TIS registration failed (\(status))")
    exit(1)
}
let query = [kTISPropertyInputSourceID as String: id] as CFDictionary
guard let items = TISCreateInputSourceList(query, true)?.takeRetainedValue() as? [TISInputSource],
      let input = items.first else {
    print("WA Wubi is not in the current input source list")
    exit(2)
}
let enable = TISEnableInputSource(input)
guard enable == noErr else {
    print("TIS enable failed (\(enable))")
    exit(3)
}
if CommandLine.arguments.contains("--select") {
    let result = TISSelectInputSource(input)
    guard result == noErr else { print("TIS select failed (\(result))"); exit(4) }
}
print("WA Wubi registered and enabled")
