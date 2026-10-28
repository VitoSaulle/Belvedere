import Darwin

/// Risale l'albero dei processi con sysctl.
public enum ProcessTree {
    public static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Antenati dal genitore in su, fino a launchd (pid 1) o a `max` passi.
    public static func ancestors(of pid: Int32, max: Int = 32) -> [Int32] {
        var chain: [Int32] = []
        var current = pid
        while chain.count < max, let next = parent(of: current), next > 0, next != current, !chain.contains(next) {
            chain.append(next)
            if next == 1 { break }
            current = next
        }
        return chain
    }
}
