import BelvedereCore
import Foundation
import Observation

/// Plugin di Claude Code gestiti con `claude plugin …`: Belvedere non scrive mai i file dei plugin.
@MainActor @Observable
final class PluginManager {
    private(set) var catalog: PluginCatalog?
    private(set) var isLoading = false
    /// Plugin con un comando in corso (installa, abilita…).
    private(set) var busy: Set<String> = []
    private(set) var error: String?
    /// Comando da confermare nel terminale (plugin che si installa eseguendo un comando del marketplace).
    private(set) var terminalCommand: String?
    private(set) var changedSinceOpen = false

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let output = await Self.run(PluginCommand.listArguments, in: nil)
        guard output.code == 0, let catalog = try? PluginCatalog.decode(output.stdout) else {
            error = output.code == -1
                ? "Claude Code non trovato: installa la CLI o aggiungila al PATH."
                : "Non riesco a leggere i plugin: \(Self.text(output))"
            return
        }
        self.catalog = catalog
        error = nil
    }

    func perform(_ action: PluginAction, plugin: String, scope: String = "user", projectPath: String? = nil) async {
        let key = plugin + "|" + scope + "|" + (projectPath ?? "")
        guard !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        terminalCommand = nil
        let output = await Self.run(PluginCommand.arguments(action, plugin: plugin, scope: scope), in: projectPath)
        let result = PluginResult.decode(output.stdout, exitCode: output.code)
        if result.needsTerminal {
            terminalCommand = PluginCommand.terminalLine(action, plugin: plugin, scope: scope)
            error = nil
        } else if !result.succeeded {
            error = result.message.isEmpty ? Self.text(output) : result.message
        } else {
            error = nil
            changedSinceOpen = true
        }
        await load()
    }

    func isBusy(_ plugin: String, scope: String = "user", projectPath: String? = nil) -> Bool {
        busy.contains(plugin + "|" + scope + "|" + (projectPath ?? ""))
    }

    func dismissMessages() {
        error = nil
        terminalCommand = nil
    }

    // MARK: - Processo

    private struct Output: Sendable {
        var code: Int32
        var stdout: Data
        var stderr: Data
    }

    private static func text(_ output: Output) -> String {
        let err = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty ? String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : err
    }

    /// Esegue `claude` con gli argomenti dati; i comandi di progetto partono nella cartella del progetto.
    private nonisolated static func run(_ arguments: [String], in folder: String?) async -> Output {
        let env = ProcessInfo.processInfo.environment
        guard let binary = ClaudeCommand.locateBinary(home: NSHomeDirectory(), path: env["PATH"],
                                                      isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return Output(code: -1, stdout: Data(), stderr: Data())
        }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.environment = ClaudeCommand.environment(LaunchOptions(folder: folder ?? NSHomeDirectory()), base: env)
            process.currentDirectoryURL = URL(fileURLWithPath: folder ?? NSHomeDirectory())
            process.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch {
                return Output(code: -1, stdout: Data(), stderr: Data(error.localizedDescription.utf8))
            }
            // Si legge prima di aspettare l'uscita: l'elenco dei marketplace supera il buffer della pipe.
            async let o = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            async let e = (try? err.fileHandleForReading.readToEnd()) ?? Data()
            let (stdout, stderr) = await (o, e)
            process.waitUntilExit()
            return Output(code: process.terminationStatus, stdout: stdout, stderr: stderr)
        }.value
    }
}
