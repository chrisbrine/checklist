import Foundation
import CryptoKit
import ChecklistIPC

struct CaptureAttachmentDestination: Codable, Equatable {
    let storeIncarnation: String
    let projectID: String
    let taskID: String?
    static func == (a: Self,b: Self) -> Bool {
        Data(a.storeIncarnation.utf8) == Data(b.storeIncarnation.utf8) && Data(a.projectID.utf8) == Data(b.projectID.utf8) && a.taskID.map {Data($0.utf8)} == b.taskID.map {Data($0.utf8)}
    }
}
struct CaptureAttachment: Identifiable, Codable {
    let id: UUID
    var destination: CaptureAttachmentDestination
    let url: URL
    let mode: String
    let ownedStaging: Bool
    let commandID: String
    init(destination: CaptureAttachmentDestination,url: URL,mode: String,ownedStaging: Bool = false) {
        id = UUID();self.destination = destination;self.url = url;self.mode = mode;self.ownedStaging = ownedStaging;commandID = UUID().uuidString
    }
    static var staging: URL { ChecklistInstance.current.cachesRoot.appendingPathComponent("ChecklistAttachmentDrafts",isDirectory:true) }
    func removeOwnedStaging() {
        guard ownedStaging,url.deletingLastPathComponent().path == Self.staging.path,UUID(uuidString:url.deletingPathExtension().lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at:url)
    }
}

@MainActor
enum CaptureAttachmentDrafts {
    private static let prefix = "attachment-capture.v1."
    private static func key(_ destination: CaptureAttachmentDestination) -> String {
        let encoder = JSONEncoder();encoder.outputFormatting = .sortedKeys
        let bytes = (try? encoder.encode(destination)) ?? Data()
        return prefix + SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
    }
    static func load(_ destination: CaptureAttachmentDestination,preferences: UserDefaults) -> [CaptureAttachment] {
        guard let bytes = preferences.data(forKey:key(destination)),let files = try? JSONDecoder().decode([CaptureAttachment].self,from:bytes) else { return [] }
        return Array(files.filter {$0.destination == destination}.prefix(20))
    }
    static func save(_ files: [CaptureAttachment],destination: CaptureAttachmentDestination,preferences: UserDefaults) {
        let selected = Array(files.filter {$0.destination == destination}.prefix(20))
        if selected.isEmpty { preferences.removeObject(forKey:key(destination)) }
        else if let bytes = try? JSONEncoder().encode(selected) { preferences.set(bytes,forKey:key(destination)) }
    }
    static func accepted(_ file: CaptureAttachment,preferences: UserDefaults) {
        save(load(file.destination,preferences:preferences).filter {$0.id != file.id},destination:file.destination,preferences:preferences)
    }
}

