import BelvedereCore
import Foundation
import Observation

/// Una sessione lanciata da Belvedere: il processo `claude -p` o `codex app-server` e la sua chat.
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
    /// Il dialogo JSON-RPC, solo per le sessioni Codex.
    @ObservationIgnored private var codex: CodexConversation?

    init(options: LaunchOptions, history: [TranscriptItem] = []) {
        self.options = options
        let local = options.local != nil
        state = options.resumeID.map {
            ChatState(agent: options.agent, isLocal: local, history: history, resuming: $0, folder: options.folder)
        } ?? ChatState(agent: options.agent, isLocal: local, history: history)
    }

    var agent: AgentKind { options.agent }

    var binary: String? {
        let env = ProcessInfo.processInfo.environment
        let isExecutable = { FileManager.default.isExecutableFile(atPath: $0) }
        return agent == .claude
            ? ClaudeCommand.locateBinary(home: NSHomeDirectory(), path: env["PATH"], isExecutable: isExecutable)
            : CodexCommand.locateBinary(home: NSHomeDirectory(), path: env["PATH"], isExecutable: isExecutable)
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
            state.lastError = "\(agent.productName) non trovato: installa la CLI o aggiungila al PATH."
            changed()
            return
        }
        let base = ProcessInfo.processInfo.environment
        let args = agent == .claude
            ? ClaudeCommand.arguments(options, isGitRepository: GitInfo.isRepository(options.folder))
            : CodexCommand.arguments
        let env = agent == .claude ? ClaudeCommand.environment(options, base: base) : base
        let process = StreamProcess(executable: binary, arguments: args, environment: env, directory: options.folder)
        do {
            let events = try process.start()
            self.process = process
            isRunning = true
            state.lastError = nil
            if agent == .claude {
                try? process.send(StreamInput.initialize(requestID: UUID().uuidString))
            } else {
                var conversation = CodexConversation(options: options)
                conversation.begin().forEach { try? process.send($0) }
                codex = conversation
            }
            reader = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    switch event {
                    case .line(let data):
                        self.receive(data)
                    case .exited(let code, let stderr):
                        self.isRunning = false
                        self.state.processExited(code: code, stderr: stderr, now: Date())
                    }
                    self.changed()
                }
            }
        } catch {
            state.lastError = "Non riesco ad avviare \(agent.productName): \(error.localizedDescription)"
        }
        changed()
    }

    private func receive(_ data: Data) {
        guard var conversation = codex else {
            state.apply(StreamMessage.decode(data), now: Date())
            return
        }
        let replies = conversation.receive(CodexMessage.decode(data), state: &state, now: Date())
        codex = conversation
        replies.forEach(write)
    }

    /// Passa un'azione al dialogo Codex e scrive le righe che produce.
    private func withCodex(_ body: (inout CodexConversation, inout ChatState) -> [Data]) {
        guard var conversation = codex else { return }
        let lines = body(&conversation, &state)
        codex = conversation
        lines.forEach(write)
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
                state.sendFailed(state.lastError ?? "\(agent.productName) non è avviato.", now: Date())
                break
            }
            if codex != nil {
                withCodex { c, _ in c.send(message) }
            } else {
                write(StreamInput.user(message))
            }
        case .setModel(let model):
            if codex != nil {
                withCodex { c, s in c.setModel(model, state: &s); return [] }
                state.addNote("Modello: \(model), dal prossimo messaggio")
            } else {
                state.userSent(text, now: Date())
                write(StreamInput.setModel(requestID: UUID().uuidString, model: model))
            }
        case .clear:
            Task { await clear() }
        case .terminalOnly:
            break
        }
        changed()
        return route
    }

    func answer(_ ask: PermissionAsk, allow: Bool, always: Bool = false) {
        if codex != nil {
            withCodex { c, _ in c.answer(ask.id, allow: allow, always: always) }
            state.answered(ask.id)
            changed()
            return
        }
        let decision: HostDecision = allow
            ? .allow(input: ask.input, rules: always ? ask.alwaysRules : [])
            : .deny(message: "Negato dall'utente in Belvedere")
        write(StreamInput.decision(decision, for: ask.id))
        state.answered(ask.id)
        changed()
    }

    func answer(_ ask: PermissionAsk, answers: [String: String]) {
        if codex != nil {
            withCodex { c, _ in c.answer(ask.id, answers: answers) }
            state.answered(ask.id)
            changed()
            return
        }
        write(StreamInput.decision(ask.answering(answers), for: ask.id))
        state.answered(ask.id)
        changed()
    }

    func interrupt() {
        if codex != nil {
            withCodex { c, _ in c.interrupt() }
        } else {
            write(StreamInput.interrupt(requestID: UUID().uuidString))
        }
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
        // Codex apre un thread nuovo nello stesso processo.
        if codex != nil, isRunning {
            clearedFrom = state.sessionID
            withCodex { c, s in c.newThread(state: &s) }
            changed()
            return
        }
        await stop()
        clearedFrom = state.sessionID
        options = options.resuming("", cwd: state.cwd)
        options.resumeID = nil
        state = ChatState(agent: agent, isLocal: options.local != nil)
        start()
    }

    private func write(_ data: Data) {
        do {
            guard let process else { throw CocoaError(.fileWriteUnknown) }
            try process.send(data)
        } catch {
            state.sendFailed("\(agent.productName) non risponde: la sessione è ferma.", now: Date())
        }
    }

    private func changed() {
        onChange?()
    }
}
