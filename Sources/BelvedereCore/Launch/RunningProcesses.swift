import Darwin
import Foundation

/// Processi vivi sulla macchina, letti con libproc.
public enum RunningProcesses {
    /// Percorso reale (es. `/var/…` → `/private/var/…`), come lo riporta il kernel.
    public static func canonical(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    /// Cartelle di lavoro dei processi con questo nome, esclusi i PID indicati.
    /// Belvedere la usa per non riprendere una sessione la cui cartella ha già un `claude` aperto.
    public static func folders(named name: String, excluding excluded: Set<Int32>) -> Set<String> {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var result: Set<String> = []
        for pid in pids.prefix(Int(max(filled, 0))) where pid > 0 && !excluded.contains(pid) {
            var buffer = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0,
                  String(cString: buffer) == name else { continue }
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if !path.isEmpty { result.insert(path) }
        }
        return result
    }
}
