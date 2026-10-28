import Foundation
import AppKit
import ChecklistIPC
import ImageIO

/// CL-65: one quick-capture draft that lives outside every workspace window. It is saved on this Mac
/// after each change, so it survives a closed main window, a quit and an unavailable service.
struct QuickCaptureDraft: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Identifiable, Sendable {
        var id: String { commandID }
        let path: String
        let ownedStaging: Bool
        /// Fixed when the file is chosen, so a retry after an unknown outcome replays the same command.
        let commandID: String
        var attached = false
    }
    /// Immutable bytes for the create being checked, separate from the next draft's editable text.
    struct PendingCreate: Codable, Equatable, Sendable {
        let commandID: String
        let projectID: String
        let title: String
        let brief: String
        var epicID: String? = nil
        var parameters: [String: Any] {
            var value: [String: Any] = ["command_id": commandID, "project_id": projectID, "title": title]
            if let epicID { value["epic_id"] = epicID }
            if !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value["brief"] = brief }
            return value
        }
    }
    var pendingCreate: PendingCreate? = nil
    var epicID: String? = nil
    var projectID = ""
    var title = ""
    var note = ""
    var files: [File] = []
    var createCommandID: String? = nil
    var createdTaskID: String? = nil
    var createdKey: String? = nil
    var isEmpty: Bool { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && note.isEmpty && files.isEmpty }
}

struct QuickCaptureProject: Codable, Equatable, Identifiable {
    let id: String
    let name: String
}

@MainActor
final class QuickCaptureModel: ObservableObject {
    enum State: Equatable {
        case editing
        case sending
        case notSent(String)
        case uncertain(String)
        case filesPending(String)
        case captured(key: String, taskID: String, projectID: String)
    }
    typealias Transport = @MainActor (String, [String: Any]) async throws -> [String: Any]
    static let journalKind = "quick_capture"
    static let projectsKey = "quickCaptureProjects"
    static let lastProjectKey = "quickCaptureLastProject"
    static let notSentOffline = "Not sent. Checklist's service is not available. This draft is saved on this Mac; send it again when Checklist is running."

    static let uncertainCreate = "Checklist may already have saved this ticket. Check again to confirm it using the original title, project and note."
    static let newerEdits = "Changes to the title, project or note stay as your next draft. They are not part of the ticket being checked. Files stay with that ticket."

    @Published var draft: QuickCaptureDraft {
        didSet {
            // A refused request may be retried unchanged, but different text needs a fresh ID.
            if draft.pendingCreate == nil, draft.createdTaskID == nil,
               draft.projectID != oldValue.projectID || draft.epicID != oldValue.epicID || draft.title != oldValue.title || draft.note != oldValue.note {
                draft.createCommandID = nil
            }
            if draft.projectID != oldValue.projectID { let last=CaptureEpicDefaults.last(draft.projectID,preferences:preferences); draft.epicID = last.isEmpty ? nil : last }
            if draft != oldValue { persist() }
        }
    }
    @Published private(set) var projects: [QuickCaptureProject]
    @Published private(set) var state: State = .editing
    @Published private(set) var projectsAvailable = false
    @Published var problem: String?
    @Published private(set) var epics: [Record] = []
    @Published private(set) var epicLoading = false
    @Published private(set) var epicError: String?
    @Published private(set) var epicTotal: Int?
    @Published private(set) var epicNext: String?
    @Published private(set) var epicPrevious: String?
    private var epicRead = UUID()
    private var epicProject = ""
    private var draftSaveFailed = false
    private let journal: LocalDraftJournal
    private let preferences: UserDefaults
    private let stagingDirectory: URL
    private let transport: Transport

    init(journal: LocalDraftJournal = LocalDraftJournal(directory: LocalDraftJournal.defaultDirectory.appendingPathComponent("QuickCapture", isDirectory: true)),
         preferences: UserDefaults = .standard, stagingDirectory: URL = CaptureAttachment.staging,
         transport: @escaping Transport = QuickCaptureModel.liveTransport) {
        self.journal = journal; self.preferences = preferences; self.stagingDirectory = stagingDirectory; self.transport = transport
        draft = (try? journal.load(QuickCaptureDraft.self, kind: Self.journalKind))?["draft"] ?? QuickCaptureDraft()
        projects = (preferences.data(forKey: Self.projectsKey)).flatMap { try? JSONDecoder().decode([QuickCaptureProject].self, from: $0) } ?? []
        if draft.projectID.isEmpty, draft.pendingCreate == nil, draft.createdTaskID == nil, draft.isEmpty {
            draft.projectID = preferences.string(forKey: Self.lastProjectKey) ?? ""
        }
        if draft.epicID == nil, draft.pendingCreate == nil, draft.createdTaskID == nil {let last=CaptureEpicDefaults.last(draft.projectID,preferences:preferences);if !last.isEmpty {draft.epicID=last}}
        if draft.createdTaskID != nil { state = .filesPending(Self.savedTicketFiles) }
        else if draft.pendingCreate != nil { state = .uncertain(Self.uncertainCreate) }
    }

    /// The service connection that the app windows use; owner calls from the trusted app.
    static func liveTransport(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let reply = try await NativeServiceTransport.call(method, params)
        if let failure = reply["error"] as? [String: Any] {
            throw ChecklistError(failure["code"] as? String ?? "SERVICE_ERROR", failure["message"] as? String ?? "The Checklist service could not complete this request.", details: failure["details"] as? [String: Any] ?? [:])
        }
        return reply["data"] as? [String: Any] ?? [:]
    }

    /// Reads the current projects; offline, the last known list stays so the draft can still name its project.
    func loadProjects() async {
        do {
            let reply = try await transport("project_list", [:])
            let rows = reply["projects"] as? [[String: Any]] ?? []
            let list = rows.filter { !($0["archived"] as? Bool ?? false) }.compactMap { row -> QuickCaptureProject? in
                guard let id = row["id"] as? String, !id.isEmpty else { return nil }
                return QuickCaptureProject(id: id, name: row["name"] as? String ?? id)
            }
            projects = list; projectsAvailable = true
            preferences.set(try? JSONEncoder().encode(list), forKey: Self.projectsKey)
            if draft.pendingCreate == nil, draft.createdTaskID == nil, !list.contains(where: { $0.id == draft.projectID }) {
                // A missing destination requires a fresh choice for saved content.
                draft.projectID = draft.isEmpty && list.count == 1 ? list[0].id : ""
            }
            if case .notSent = state { state = .editing }
        } catch {
            projectsAvailable = false
            if draft.pendingCreate == nil, draft.createdTaskID == nil, !draft.isEmpty { state = .notSent(Self.notSentOffline) }
        }
    }

    func createEpicRequest(_ method:String,_ params:[String:Any]) async throws -> [String:Any] {try await transport(method,params)}
    var availableEpics: [Record] { epics.filter { RecordIdentity($0.string("project_id")) == RecordIdentity(draft.projectID) } }
    func loadEpics(cursor: String? = nil) async {
        let project = draft.projectID, read = UUID(); epicRead = read
        if epicProject != project { epics = []; epicNext = nil; epicPrevious = nil; epicTotal = nil; epicProject = project }
        guard !project.isEmpty else { epicLoading = false; return }
        epicLoading = true; epicError = nil
        do {
            let query = WorkspacePageQuery(surface: "epics", project: project)
            let page = try WorkspacePage(await transport("workspace_page", query.parameters(cursor: cursor)), query: query)
            guard !Task.isCancelled, epicRead == read, RecordIdentity(draft.projectID) == RecordIdentity(project) else { return }
            epics = page.rows; epicTotal = page.total; epicNext = page.next; epicPrevious = page.previous; epicLoading = false
        } catch {
            guard epicRead == read else { return }
            epicLoading = false; epicError = "Could not load Epics. Your draft and saved Epic are kept."
        }
    }

    var canSend: Bool {
        state != .sending && (draft.pendingCreate != nil || draft.createdTaskID != nil ||
            (!draft.projectID.isEmpty && !(draft.epicID ?? "").isEmpty && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }
    var sendTitle: String { draft.createdTaskID != nil ? "Finish attaching files" : draft.pendingCreate != nil ? "Check again" : "Create Draft" }
    var hasNewerEdits: Bool {
        guard let intent = draft.pendingCreate else { return false }
        return draft.projectID != intent.projectID || draft.epicID != intent.epicID || draft.title != intent.title || draft.note != intent.brief
    }
    static let savedTicketFiles = "The ticket is saved. Some files may still need attaching. Check again to finish using the same files."
    private var filesLocked: Bool { draft.pendingCreate != nil || draft.createdTaskID != nil || state == .sending }

    func attach(_ urls: [URL]) {
        guard !filesLocked else { problem = "Finish checking this ticket before adding files."; return }
        for url in urls where url.isFileURL {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else { problem = "Choose a regular local file; folders are not attached."; continue }
            guard draft.files.count < 20 else { problem = "Attach at most 20 files."; return }
            draft.files.append(.init(path: url.path, ownedStaging: false, commandID: UUID().uuidString))
        }
    }

    /// Saves the clipboard image as a PNG in the private staging folder and attaches it.
    @discardableResult func attachClipboardImage(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard !filesLocked else { problem = "Finish checking this ticket before adding files."; return false }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { attach(urls); return true }
        guard let bytes = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
              bytes.count <= 20 * 1_048_576, let image = NSBitmapImageRep(data: bytes),
              (1...16_384).contains(image.pixelsWide), (1...16_384).contains(image.pixelsHigh),
              let png = image.representation(using: .png, properties: [:]), png.count <= 20 * 1_048_576 else {
            problem = "The clipboard has no image or file."; return false
        }
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = stagingDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
            try png.write(to: url, options: .atomic)
            draft.files.append(.init(path: url.path, ownedStaging: true, commandID: UUID().uuidString))
            return true
        } catch { problem = "The clipboard image could not be saved for this ticket."; return false }
    }

    static func clipboardHasImage(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    func remove(_ file: QuickCaptureDraft.File) {
        guard !file.attached, !filesLocked else { return }
        draft.files.removeAll { $0.commandID == file.commandID }
        removeStaging(file)
    }

    /// Creates the Draft ticket, then attaches each file. Every step keeps its command ID in the saved
    /// draft, so a retry after an unknown outcome or an outage replays the same commands.
    func send() async {
        guard canSend else { return }
        let wasPending = draft.pendingCreate != nil
        state = .sending; problem = nil
        do {
            if draft.createdTaskID == nil {
                if draft.pendingCreate == nil {
                    let commandID = draft.createCommandID ?? UUID().uuidString
                    draft.createCommandID = commandID
                    draft.pendingCreate = .init(commandID: commandID, projectID: draft.projectID, title: draft.title, brief: draft.note, epicID: draft.epicID)
                }
                // Never send a create whose exact intent has not reached the journal.
                do { try journal.save(draft, kind: Self.journalKind, key: "draft") }
                catch { throw ChecklistError("DRAFT_SAVE_FAILED", "The draft could not be saved on this Mac.", details: ["command_outcome": "not_sent"]) }
                let reply = try await transport("task_create", draft.pendingCreate!.parameters)
                let task = reply["task"] as? [String: Any] ?? reply
                guard let id = task["id"] as? String, !id.isEmpty else { throw ChecklistError("INVALID_RESPONSE", "The service did not return the new ticket.") }
                draft.createdTaskID = id; draft.createdKey = task["key"] as? String ?? ""
            }
            let projectID = draft.pendingCreate?.projectID ?? draft.projectID
            for index in draft.files.indices where !draft.files[index].attached {
                let file = draft.files[index]
                _ = try await transport("attachment_add", ["command_id": file.commandID, "project_id": projectID, "task_id": draft.createdTaskID!, "path": file.path, "mode": "managed"])
                draft.files[index].attached = true
                removeStaging(file)
            }
            let finished = State.captured(key: draft.createdKey ?? "", taskID: draft.createdTaskID!, projectID: projectID)
            preferences.set(projectID, forKey: Self.lastProjectKey)
            CaptureEpicDefaults.remember(draft.pendingCreate?.epicID ?? draft.epicID ?? "",project:projectID,preferences:preferences)
            // Text edited while checking is a separate draft, never a second use of this command.
            let next = hasNewerEdits ? QuickCaptureDraft(epicID: draft.epicID, projectID: draft.projectID, title: draft.title, note: draft.note) : QuickCaptureDraft(epicID: draft.pendingCreate?.epicID ?? draft.epicID, projectID: projectID)
            draft = next
            state = finished
        } catch {
            if draft.createdTaskID != nil {
                state = .filesPending(Self.savedTicketFiles + " " + PlainError.text(error))
            } else if (error as? ChecklistError)?.code == "EPIC_REQUIRED", !Self.isUncertain(error) {
                draft.pendingCreate = nil; draft.createCommandID = nil
                state = .notSent(Self.text(for: error))
            } else if wasPending || Self.isUncertain(error) {
                state = .uncertain(Self.uncertainCreate)
            } else {
                draft.pendingCreate = nil
                state = .notSent(Self.text(for: error))
            }
        }
    }

    func startAnother() { state = .editing; problem = nil }

    private static func isUncertain(_ error: Error) -> Bool {
        guard let failure = error as? ChecklistError else { return true }
        if let outcome = failure.details["command_outcome"] as? String {
            return !["rejected", "not_sent"].contains(outcome)
        }
        // Wire-decoded service refusals carry an outcome above. Without that proof, only
        // known pre-send/validation failures establish that this create was not accepted.
        return !["SERVICE_UNAVAILABLE", "SERVICE_REGISTRATION_FAILED", "SERVICE_SETUP_REQUIRED",
                 "STORE_BUSY", "STORAGE_DRAINING", "STORAGE_NOT_READY", "INVALID_INPUT", "INVALID_PARAMS",
                 "VALIDATION_ERROR", "EPIC_REQUIRED"].contains(failure.code)
    }
    static func text(for error: Error) -> String {
        guard let failure = error as? ChecklistError else { return notSentOffline }
        switch failure.code {
        case "DRAFT_SAVE_FAILED": return "Not sent. The draft could not be saved on this Mac."
        case "SERVICE_UNAVAILABLE", "SERVICE_REGISTRATION_FAILED", "STORE_BUSY", "STORAGE_DRAINING", "STORAGE_NOT_READY":
            return notSentOffline
        default: return "Not sent. " + PlainError.text(error) + " This draft is saved on this Mac."
        }
    }
    private func removeStaging(_ file: QuickCaptureDraft.File) {
        let url = URL(fileURLWithPath: file.path)
        guard file.ownedStaging, url.deletingLastPathComponent().path == stagingDirectory.path,
              UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: url)
    }
    func captureTerminationCheck() -> CaptureTerminationCheck {
        let snapshot = draft, journal = journal, failed = draftSaveFailed, kind = Self.journalKind
        return CaptureTerminationCheck(verify: {
            guard !failed else { throw CocoaError(.fileWriteUnknown) }
            if !snapshot.isEmpty || snapshot.pendingCreate != nil || snapshot.createdTaskID != nil {
                try journal.checkSaved(snapshot, kind: kind, key: "draft")
            }
        }, isCurrent: { [weak self] in self?.draft == snapshot })
    }
    private func persist() {
        do { try journal.save(draft, kind: Self.journalKind, key: "draft"); draftSaveFailed = false }
        catch { draftSaveFailed = true; problem = "This draft could not be saved on this Mac: \(error.localizedDescription)" }
    }
}

extension QuickCaptureModel: CaptureTerminationParticipant {}
