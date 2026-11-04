import Darwin
import Foundation

public enum ListeningPorts {
    public static func pids(inGroup group: pid_t) -> [pid_t] {
        guard group > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: 2048)
        let count = buffer.withUnsafeMutableBytes { raw in
            proc_listpgrppids(group, raw.baseAddress, Int32(raw.count))
        }
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count))).filter { $0 > 0 }
    }

    public static func ports(inGroup group: pid_t) -> [Int] {
        Array(Set(pids(inGroup: group).flatMap(ports(ofProcess:)))).sorted()
    }

    public static func ports(ofProcess pid: pid_t) -> [Int] {
        let entrySize = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / entrySize + 16)
        let filled = descriptors.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else { return [] }
        var ports: Set<Int> = []
        for descriptor in descriptors.prefix(Int(filled) / entrySize) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            guard info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }
}

public enum ServerOutput {
    nonisolated(unsafe) static let escapeSequence = /\u{1B}(?:\[[0-?]*[ -\/]*[@-~]|\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\)?|[@-Z\\-_])/
    nonisolated(unsafe) static let localURL = /(?i)(?:https?:\/\/)?(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):(\d{2,5})(?!\d)/
    nonisolated(unsafe) static let errorWords = /(?i)\b(?:error|errors|failed|failure|exception|fatal|panic|traceback|eaddrinuse|cannot|unable)\b/

    public static func stripANSI(_ line: String) -> String {
        line.replacing(escapeSequence, with: "")
    }

    public static func clean(_ line: String) -> String {
        String(stripANSI(line).unicodeScalars.filter { $0 == "\t" || !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
    }

    public static func localPort(in line: String) -> Int? {
        guard let match = line.firstMatch(of: localURL), let port = Int(match.1), (1...65535).contains(port) else { return nil }
        return port
    }

    public static func looksLikeError(_ line: String) -> Bool {
        line.contains(errorWords)
    }
}
