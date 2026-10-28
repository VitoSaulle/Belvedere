import BelvedereCore
import Foundation

// belvedere-statusline [--wrap <base64>]: inoltra a Belvedere il JSON della status line,
// poi stampa la status line originale dell'utente (se c'era) o una riga compatta.
let input = FileHandle.standardInput.readDataToEndOfFile()
_ = Relay.post(path: "/statusline", body: input, port: Relay.port, timeout: 0.3)

let args = Array(CommandLine.arguments.dropFirst())
if let i = args.firstIndex(of: "--wrap"), i + 1 < args.count,
   let decoded = Data(base64Encoded: args[i + 1]), let command = String(data: decoded, encoding: .utf8) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let stdin = Pipe()
    process.standardInput = stdin
    do {
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        exit(process.terminationStatus)
    } catch {
        exit(0)
    }
}

if let payload = try? StatusLinePayload.decode(input, now: Date()) {
    print(StatusLineText.render(payload))
} else {
    print("Belvedere")
}
