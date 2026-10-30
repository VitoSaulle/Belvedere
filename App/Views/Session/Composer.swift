import AppKit
import BelvedereCore
import SwiftUI
import UniformTypeIdentifiers

/// Campo della chat: ⏎ invia, ⇧⏎ va a capo, `/` per i comandi, `@` per i file.
/// Allegati come nel terminale: le immagini (graffetta, trascinate o incollate con ⌘V) partono col messaggio,
/// gli altri file entrano nel testo come `@percorso`.
struct Composer: View {
    @Environment(AppModel.self) private var model
    let host: HostedSession
    let sessionID: String
    @State private var text = ""
    @State private var terminalOnly: String?
    @State private var resumeSearch: ResumeSearch?
    @State private var files: [String] = []
    @State private var showErrorDetail = false
    @State private var images: [ImageAttachment] = []
    @State private var paste = PasteMonitor()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = host.state.lastError {
                banner(error)
            }
            if let name = terminalOnly ?? host.state.unavailableCommand {
                terminalNotice(name)
            }
            if let remote = host.state.remoteControl {
                remoteControlNotice(remote)
            }
            if !suggestions.isEmpty {
                suggestionList
            }
            field
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .frame(maxWidth: 760)
        .sheet(item: $resumeSearch) { search in
            ResumePicker(agent: host.agent, folder: host.state.cwd ?? host.options.folder, currentID: sessionID, query: search.text)
        }
        .task(id: fileQuery) { await loadFiles() }
        .onAppear {
            focused = true
            paste.start { pasteFromClipboard() }
        }
        .onDisappear { paste.stop() }
        .onChange(of: focused, initial: true) { _, on in paste.active = on }
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls)
            return !urls.isEmpty
        }
    }

    // MARK: - Campo

    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty { imageStrip }
            fieldRow
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var imageStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(images) { image in
                    ImageChip(image: image) { images.removeAll { $0 == image } }
                }
            }
            .padding(.top, 6)
        }
        .scrollIndicators(.never)
    }

    private var fieldRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button(action: choose) {
                Image(systemName: "paperclip").font(.system(size: 14, weight: .medium))
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Allega immagini o file")
            TextField("Scrivi a \(Theme.agentName(host.agent)), / per i comandi, @ per i file", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit(send)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    text += "\n"
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard let first = suggestions.first else { return .ignored }
                    accept(first)
                    return .handled
                }
                .padding(.vertical, 6)
            Menu {
                Button("Apri nel terminale", systemImage: "terminal") { Task { await model.openInTerminal(sessionID) } }
                    .disabled(model.isTransferring(sessionID))
                if host.agent == .claude {
                    let active = host.state.remoteControl != nil
                    Button(active ? "Disattiva Remote Control" : "Attiva Remote Control", systemImage: "iphone") {
                        host.setRemoteControl(!active)
                    }
                }
                if !host.isRunning {
                    Button("Riavvia la sessione", systemImage: "arrow.clockwise") { host.restart() }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Altre azioni")
            if host.state.status == .working || host.state.status == .waiting {
                Button { host.interrupt() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.85), in: .circle)
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: .command)
                .help("Ferma (⌘.)")
            }
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(canSend ? Theme.accent : Color.primary.opacity(0.15), in: .circle)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Invia (⏎)")
        }
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !images.isEmpty else { return }
        terminalOnly = nil
        let attached = images
        images = []
        switch host.send(message, images: attached) {
        case .terminalOnly(let name):
            terminalOnly = name
            return
        case .plugins where host.agent == .claude:
            model.showPlugins = true
        case .plugins:
            terminalOnly = "plugin"
            return
        case .resume(let query):
            resumeSearch = ResumeSearch(text: query ?? "")
        default:
            break
        }
        text = ""
    }

    // MARK: - Allegati

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: host.state.cwd ?? host.options.folder)
        panel.prompt = "Allega"
        guard panel.runModal() == .OK else { return }
        attach(panel.urls)
    }

    /// Immagini come allegati, il resto come `@percorso` nel testo (relativo alla cartella della sessione).
    private func attach(_ urls: [URL]) {
        var mentions: [String] = []
        for url in urls where url.isFileURL {
            if ImageAttachment.isImage(path: url.path) {
                let image = ImageAttachment(path: url.path)
                if !images.contains(image) { images.append(image) }
            } else {
                mentions.append(Self.mention(url.path, root: host.state.cwd ?? host.options.folder))
            }
        }
        if !mentions.isEmpty {
            let separator = text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? "" : " "
            text += separator + mentions.joined(separator: " ") + " "
        }
        focused = true
    }

    static func mention(_ path: String, root: String) -> String {
        let base = root.hasSuffix("/") ? root : root + "/"
        let shown = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
        return shown.contains(" ") ? "@\"\(shown)\"" : "@\(shown)"
    }

    /// ⌘V: file copiati nel Finder o un'immagine negli appunti (uno screenshot). Il testo si incolla come sempre.
    private func pasteFromClipboard() -> Bool {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            attach(urls)
            return true
        }
        if board.string(forType: .string) != nil { return false }
        guard let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        do {
            let dir = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("it.vitosaulle.Belvedere/Allegati", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) alle \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
                                                    timeZone: .current, calendar: .current))
            let url = dir.appendingPathComponent("Immagine \(stamp).png")
            try png.write(to: url)
            images.append(ImageAttachment(path: url.path))
            return true
        } catch {
            return false
        }
    }

    // MARK: - Suggerimenti

    private enum Suggestion: Hashable {
        case command(name: String, description: String)
        case file(String)
    }

    /// `/nome` all'inizio del testo, senza spazi.
    private var slashQuery: String? {
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return nil }
        return String(text.dropFirst())
    }

    /// `@percorso` come ultima parola.
    private var fileQuery: String? {
        guard let last = text.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("@") else { return nil }
        return String(last.dropFirst())
    }

    private var suggestions: [Suggestion] {
        if let query = slashQuery {
            let native = host.agent == .claude ? SlashRoute.nativeCommands : []
            return Completions.slash(query, in: host.state.commands + native).map { .command(name: $0.name, description: $0.description) }
        }
        if fileQuery != nil { return files.prefix(8).map { .file($0) } }
        return []
    }

    private func loadFiles() async {
        guard let query = fileQuery else { files = []; return }
        let root = URL(fileURLWithPath: host.state.cwd ?? host.options.folder)
        files = await Task.detached(priority: .userInitiated) { Completions.files(query, root: root) }.value
    }

    private func accept(_ suggestion: Suggestion) {
        switch suggestion {
        case .command(let name, _):
            text = "/\(name) "
        case .file(let path):
            var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            words.removeLast()
            words.append("@\(path) ")
            text = words.joined(separator: " ")
        }
        focused = true
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button { accept(suggestion) } label: {
                    HStack(spacing: 10) {
                        switch suggestion {
                        case .command(let name, let description):
                            Text("/\(name)").font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            Text(description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        case .file(let path):
                            Image(systemName: "doc").foregroundStyle(.secondary)
                            Text(path).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    // MARK: - Avvisi

    private func banner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            Text(error).font(.system(size: 12.5)).lineLimit(3).textSelection(.enabled)
            Spacer()
            if let detail = host.state.errorDetail {
                Button("Dettagli") { showErrorDetail = true }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .popover(isPresented: $showErrorDetail) {
                        ScrollView {
                            Text(detail).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }
                        .frame(width: 520, height: 320)
                    }
            }
            if !host.isRunning {
                Button("Riavvia") { host.restart() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
        .padding(10)
        .background(Theme.danger.opacity(0.10), in: .rect(cornerRadius: 12))
    }

    private func terminalNotice(_ name: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            Text("/\(name) funziona solo nel terminale.").font(.system(size: 12.5))
            Spacer()
            Button("Apri nel terminale") { Task { await model.openInTerminal(sessionID) } }
                .disabled(model.isTransferring(sessionID))
                .help(model.isTransferring(sessionID) ? "Disponibile dopo la prima risposta nel nuovo profilo" : "")
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            Button {
                terminalOnly = nil
                host.dismissUnavailableCommand()
            } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
    }

    private func remoteControlNotice(_ remote: RemoteControl) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone").foregroundStyle(.secondary)
            Text(remote.isReconnecting ? "Remote Control: riconnessione…" : "Remote Control attivo").font(.system(size: 12.5))
            Spacer()
            if let url = URL(string: remote.url) {
                Link("Apri", destination: url).font(.system(size: 12.5))
            }
            Button("Copia link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(remote.url, forType: .string)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            Button("Disattiva") { host.setRemoteControl(false) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
    }
}

/// Miniatura di un'immagine allegata, con la × per toglierla.
private struct ImageChip: View {
    let image: ImageAttachment
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = NSImage(contentsOfFile: image.path) {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(.rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
            .help(image.name)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(.regularMaterial, in: .circle)
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("Togli")
        }
        .padding(.trailing, 5)
    }
}

/// Intercetta ⌘V mentre il campo ha il fuoco: `handler` restituisce true se ha gestito lui l'incolla.
@MainActor
final class PasteMonitor {
    var active = false
    private var monitor: Any?

    func start(_ handler: @escaping @MainActor () -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.active,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
            return handler() ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
