import AppKit

enum InputMethodRuntime {
    private struct Instance {
        let pid: pid_t
        let started: Date
        let executable: String
    }

    @MainActor
    static func reload(at bundle: URL, installedBefore cutoff: Date) async throws {
        let executable = bundle.appendingPathComponent("Contents/MacOS/WAWubi").path
        let legacy = InstallPayload.legacyFolder.appendingPathComponent(InstallPayload.name)
            .appendingPathComponent("Contents/MacOS/WAWubi").path
        let paths: Set<String> = [executable, legacy]
        var requested = Set<pid_t>()
        for attempt in 0..<40 {
            let stale = instances(at: paths).filter { $0.started <= cutoff || $0.executable != executable }
            if stale.isEmpty { break }
            for app in stale {
                if requested.insert(app.pid).inserted {
                    if NSRunningApplication(processIdentifier: app.pid)?.terminate() != true {
                        _ = kill(app.pid, SIGTERM)
                    }
                } else if attempt >= 15 {
                    _ = kill(app.pid, SIGTERM)
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard instances(at: paths).allSatisfy({ $0.started > cutoff && $0.executable == executable }) else {
            throw CocoaError(.executableLoad)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let app = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
        for _ in 0..<40 {
            let running = instances(at: paths)
            if app.isFinishedLaunching,
               running.contains(where: { $0.pid == app.processIdentifier }),
               running.allSatisfy({ $0.started > cutoff && $0.executable == executable }) { return }
            if app.isTerminated { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CocoaError(.executableLoad)
    }

    private static func instances(at paths: Set<String>) -> [Instance] {
        let uid = getuid()
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.stride + 16)
        let written = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count))
        }
        guard written > 0 else { return [] }
        return pids.prefix(Int(written) / MemoryLayout<pid_t>.stride).compactMap { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == uid else { return nil }
            let name = withUnsafeBytes(of: &info.pbi_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            guard name == "WAWubi", let path = launchedExecutable(pid), paths.contains(path) else { return nil }
            let started = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
            return Instance(pid: pid, started: started, executable: path)
        }
    }

    private static func launchedExecutable(_ pid: pid_t) -> String? {
        // proc_pidpath can fail after the old bundle has been removed. The initial executable
        // path in KERN_PROCARGS2 is preserved for the life of the process.
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var arguments = [UInt8](repeating: 0, count: size)
        let status = arguments.withUnsafeMutableBytes {
            sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { return nil }
        return String(decoding: arguments.prefix(size).dropFirst(MemoryLayout<Int32>.size).prefix(while: { $0 != 0 }),
                      as: UTF8.self)
    }
}
