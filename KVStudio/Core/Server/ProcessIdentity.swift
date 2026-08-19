import Darwin
import Foundation

// A pid alone is ambiguous across app launches; the kernel start time pins it to one incarnation.
struct ProcessStartTime: Codable, Equatable, Sendable {
    let seconds: Int64
    let microseconds: Int32
}

enum ProcessIdentity {

    static func startTime(of pid: pid_t) -> ProcessStartTime? {
        guard pid > 0 else { return nil }

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        guard Int32(info.kp_proc.p_stat) != SZOMB else { return nil }

        let started = info.kp_proc.p_starttime
        return ProcessStartTime(seconds: Int64(started.tv_sec), microseconds: Int32(started.tv_usec))
    }

    static func isPIDInUse(_ pid: pid_t) -> Bool { startTime(of: pid) != nil }

    // An unidentified pid may already belong to a stranger, so a nil identity is never alive.
    static func isAlive(pid: pid_t, since identity: ProcessStartTime?) -> Bool {
        guard let identity, let current = startTime(of: pid) else { return false }
        return current == identity
    }

    static func executablePath(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    static func pids(runningExecutableAt path: String, startedNoEarlierThan earliest: Date) -> [pid_t] {
        let wanted = resolved(path)
        let threshold = Int64(earliest.timeIntervalSince1970)
        return allPIDs().filter { pid in
            guard let started = startTime(of: pid), started.seconds >= threshold else { return false }
            guard let running = executablePath(of: pid) else { return false }
            return resolved(running) == wanted
        }
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(count) * 2)
        let written = proc_listallpids(&buffer, Int32(MemoryLayout<pid_t>.stride * buffer.count))
        guard written > 0 else { return [] }
        return Array(buffer.prefix(Int(written)))
    }
}
