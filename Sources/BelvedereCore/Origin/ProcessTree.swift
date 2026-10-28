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

    /// Figli, nipoti e così via, dal più vicino; letti con libproc.
    public static func descendants(of pid: Int32, limit: Int = 256) -> [Int32] {
        var result: [Int32] = []
        var queue = [pid]
        while let current = queue.first, result.count < limit {
            queue.removeFirst()
            var children = [pid_t](repeating: 0, count: 64)
            // Restituisce il numero di PID, non di byte.
            let count = proc_listchildpids(current, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            for child in children.prefix(Swift.min(Int(Swift.max(count, 0)), children.count)) where child > 0 && !result.contains(child) {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }
}
