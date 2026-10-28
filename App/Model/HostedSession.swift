import BelvedereCore
import Foundation
import Observation

/// Una sessione Claude Code lanciata da Belvedere: il processo `claude -p` e la sua chat.
@MainActor @Observable
final class HostedSession: Identifiable {
    let id = UUID()
    private(set) var state: ChatState
    private(set) var options: LaunchOptions
    private(set) var isRunning = false
    let launchedAt = Date()

    /// Chiamato dopo ogni cambiamento di stato: AppModel aggiorna Plancia, menu bar e notch.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Prima di riprendere una sessione: un motivo per non farlo (es. è aperta in un terminale), o `nil`.
    @ObservationIgnored var resumeBlocker: (() -> String?)?
    /// Id della conversazione lasciata con `/clear`, per spostare la navigazione su quella nuova.
    private(set) var clearedFrom: String?
    private var isStopping = false
    @ObservationIgnored private var process: StreamProcess?
    @ObservationIgnored private var reader: Task<Void, Never>?

    init(options: LaunchOptions, history: [TranscriptItem] = []) {
        self.options = options
        state = options.resumeID.map { ChatState(history: history, resuming: $0, folder: options.folder) }
            ?? ChatState(history: history)
    }

    var binary: String? {
        let env = ProcessInfo.processInfo.environment
        return ClaudeCommand.locateBinary(home: NSHomeDirectory(), path: env["PATH"]) {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    var pid: Int32? { process?.pid }

    func start() {
        guard !isRunning, !isStopping else { return }
        if options.resumeID != nil, let reason = resumeBlocker?() {
            state.lastError = reason
            changed()
            return
        }
        guard let binary else {
            state.lastError = "Claude Code non trovato: installa la CLI o aggiungila al PATH."
            changed()
            return
        }
        let args = ClaudeCommand.arguments(options, isGitRepository: GitInfo.isRepository(options.folder))
        let env = ClaudeCommand.environment(options, base: ProcessInfo.processInfo.environment)
        let process = StreamProcess(executable: binary, arguments: args, environment: env, directory: options.folder)
        do {
            let events = try process.start()
            self.process = process
            isRunning = true
            state.lastError = nil
            try? process.send(StreamInput.initialize(requestID: UUID().uuidString))
            reader = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    switch event {
                    case .line(let data):
                        self.state.apply(StreamMessage.decode(data), now: Date())
                    case .exited(let code, let stderr):
                        self.isRunning = false
                        self.state.processExited(code: code, stderr: stderr, now: Date())
                    }
                    self.changed()
                }
            }
        } catch {
            state.lastError = "Non riesco ad avviare Claude Code: \(error.localizedDescription)"
        }
        changed()
    }

    /// Instrada il testo: messaggi e comandi vanno a Claude, `/clear` e `/model` si gestiscono qui.
    /// Restituisce la rotta, così la vista può spiegare i comandi che funzionano solo nel terminale.
    @discardableResult
    func send(_ text: String) -> SlashRoute {
        let route = SlashRoute.route(text, terminalCommands: state.terminalCommands)
        switch route {
        case .send(let message):
            if !isRunning { resumeIfPossible() }
            state.userSent(message, now: Date())
            // Senza processo il messaggio non parte: niente «al lavoro» e resta il motivo.
            guard isRunning else {
                state.sendFailed(state.lastError ?? "Claude Code non è avviato.", now: Date())
                break
            }
            write(StreamInput.user(message))
        case .setModel(let model):
            state.userSent(text, now: Date())
            write(StreamInput.setModel(requestID: UUID().uuidString, model: model))
        case .clear:
            Task { await clear() }
        case .terminalOnly:
            break
        }
        changed()
        return route
    }

    func answer(_ ask: PermissionAsk, allow: Bool, always: Bool = false) {
        let decision: HostDecision = allow
            ? .allow(input: ask.input, rules: always ? ask.alwaysRules : [])
            : .deny(message: "Negato dall'utente in Belvedere")
        write(StreamInput.decision(decision, for: ask.id))
        state.answered(ask.id)
        changed()
    }

    func answer(_ ask: PermissionAsk, answers: [String: String]) {
        write(StreamInput.decision(ask.answering(answers), for: ask.id))
        state.answered(ask.id)
        changed()
    }

    func interrupt() {
        write(StreamInput.interrupt(requestID: UUID().uuidString))
    }

    func stop() async {
        guard let process, !isStopping else { return }
        // Mentre si ferma nessun invio o «Riavvia» può partire un secondo processo.
        isStopping = true
        await process.stop()
        await reader?.value
        if self.process === process {
            self.process = nil
            isRunning = false
        }
        isStopping = false
    }

    /// Riavvia il processo dopo un errore, riprendendo la stessa conversazione.
    func restart() {
        guard !isRunning else { return }
        resumeIfPossible()
    }

    private func resumeIfPossible() {
        // Nella cartella dove la sessione lavora davvero: un worktree già creato non si ricrea.
        if let id = state.sessionID { options = options.resuming(id, cwd: state.cwd) }
        start()
    }

    private func clear() async {
        await stop()
        clearedFrom = state.sessionID
        options = options.resuming("", cwd: state.cwd)
        options.resumeID = nil
        state = ChatState()
        start()
    }

    private func write(_ data: Data) {
        do {
            guard let process else { throw CocoaError(.fileWriteUnknown) }
            try process.send(data)
        } catch {
            state.sendFailed("Claude Code non risponde: la sessione è ferma.", now: Date())
        }
    }

    private func changed() {
        onChange?()
    }
}
