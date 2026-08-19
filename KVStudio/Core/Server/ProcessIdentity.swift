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

    static func isAlive(pid: pid_t, since identity: ProcessStartTime?) -> Bool {
        guard let current = startTime(of: pid) else { return false }
        guard let identity else { return true }
        return current == identity
    }
}
