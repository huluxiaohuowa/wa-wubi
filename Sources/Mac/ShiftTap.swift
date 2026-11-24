struct ShiftTap {
    private var press: (key: UInt16, app: String?, session: ObjectIdentifier, time: Double)?

    mutating func begin(key: UInt16, app: String?, session: ObjectIdentifier, time: Double) {
        press = (key, app, session, time)
    }

    mutating func cancel() { press = nil }

    mutating func end(key: UInt16, app: String?, session: ObjectIdentifier, time: Double) -> Bool {
        defer { cancel() }
        guard let press, press.key == key, press.app == app, time >= press.time else { return false }
        if press.session == session { return true }
        // An input-context reconnect can route the release to another controller in the same app.
        return app != nil && time - press.time <= 0.5
    }
}
