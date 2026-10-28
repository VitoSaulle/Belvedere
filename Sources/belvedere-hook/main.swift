import BelvedereCore
import Foundation

// belvedere-hook <EventName>: inoltra a Belvedere l'evento del hook ricevuto su stdin.
// Esce sempre con 0: se Belvedere è chiuso, Claude Code prosegue come se il hook non ci fosse.
let name = CommandLine.arguments.dropFirst().first ?? "Unknown"
let input = FileHandle.standardInput.readDataToEndOfFile()

var payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
payload["belvedere_ppid"] = Int(getppid())
let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? input

var timeout: TimeInterval = 1
if name == "PermissionRequest", case .hold(let seconds) = PermissionPolicy.default {
    timeout = seconds + 1
}
if let reply = Relay.post(path: "/hooks/\(name)", body: body, port: Relay.port, timeout: timeout),
   name == "PermissionRequest", !reply.isEmpty {
    FileHandle.standardOutput.write(reply)
}
exit(0)
