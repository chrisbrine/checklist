import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

/// Selection only. The parent commits these exact descriptors after its actual
/// capture/note target receipt, through the ordinary durable command callbacks.
struct AttachmentCaptureSection: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.checklistTextScale) private var textScale
    @Binding var pending: [CaptureAttachment]
    @Binding var destination: CaptureAttachmentDestination
    var disabled = false
    @State private var mode = "managed"
    @State private var failure: String?
    @State private var targeted = false
    @State private var dropGeneration = UUID()
    private var selected: [CaptureAttachment] { pending.filter { $0.destination == destination } }
    private var canSelect: Bool { !disabled && !destination.projectID.isEmpty && !destination.storeIncarnation.isEmpty }
    var body: some View {
        VStack(alignment:.leading,spacing: Spacing.small) {
            AccessibleHStack {
                Button("Add files…") { add(chooseFiles(directories:false)) }
                Button("Paste image or files") { paste() }
                Menu {
                    Picker("Import as", selection: $mode) {
                        Text("Managed copy").tag("managed"); Text("External reference").tag("reference")
                    }.pickerStyle(.inline)
                } label: {
                    Text("Import as: \(mode == "managed" ? "Managed copy" : "External reference")").checklistFont(.body)
                }.menuStyle(.button).buttonStyle(.checklistBordered).menuIndicator(.hidden)
                    .accessibilityLabel("Import as").accessibilityValue(mode == "managed" ? "Managed copy" : "External reference")
            }.checklistDisabled([(!canSelect, "Choose a project before adding files.")])
            if destination.projectID.isEmpty { Text("Choose a project before selecting files.").checklistFont(.micro).foregroundStyle(.secondary) }
            Text("Drop images or files here. Managed copies keep the Finder original; references keep using its external location.").checklistFont(.micro).foregroundStyle(.secondary)
            if !selected.isEmpty {
                ScrollView {
                    VStack(alignment:.leading,spacing: Spacing.compact) {
                        ForEach(selected) { item in
                            AccessibleHStack { Label(item.url.lastPathComponent,systemImage:item.mode == "reference" ? "link" : "doc").lineLimit(1);Text(item.mode == "reference" ? "Reference" : "Managed copy").checklistFont(.micro).foregroundStyle(.secondary);Spacer();Button("Remove") { pending.removeAll {$0.id == item.id};item.removeOwnedStaging() }.buttonStyle(.link).checklistDisabled([(disabled, "Files cannot change while the ticket is being created.")]) }
                        }
                    }
                }.frame(height:min(280, CGFloat(selected.count * 26) * textScale * textScale))
            }
            if let failure { Text(failure).checklistFont(.micro).foregroundStyle(.orange) }
        }.padding(Spacing.small).background(targeted ? Color.accentColor.opacity(0.08) : Color.clear,in:RoundedRectangle(cornerRadius: Radius.small))
            .onDrop(of:[UTType.fileURL.identifier,UTType.image.identifier],isTargeted:$targeted,perform:drop)
            .onAppear { restore() }
            .onChange(of:destination) { _,_ in dropGeneration = UUID();restore() }
            .onChange(of:pending.map(\.id)) { _,_ in CaptureAttachmentDrafts.save(pending,destination:destination,preferences:store.windowPreferences) }
            .onDisappear { dropGeneration = UUID() }
    }
    private func restore() {
        guard selected.isEmpty else { return }
        pending += CaptureAttachmentDrafts.load(destination,preferences:store.windowPreferences)
    }
    private func add(_ urls: [URL],mode selectedMode: String? = nil) {
        guard canSelect else { return }
        guard selected.count + urls.count <= 20 else { failure = "Select at most 20 files at a time.";return }
        for url in urls {
            var directory: ObjCBool = false
            guard url.isFileURL,FileManager.default.fileExists(atPath:url.path,isDirectory:&directory),!directory.boolValue else { failure = "Choose a regular local file; directories are not copied.";continue }
            pending.append(.init(destination:destination,url:url,mode:selectedMode ?? mode))
        }
        CaptureAttachmentDrafts.save(pending,destination:destination,preferences:store.windowPreferences)
    }
    private func image(_ data: Data) {
        guard canSelect else { return }
        do {
            guard data.count <= 20 * 1_048_576,
                  let source = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  (1...16_384).contains(width.intValue),(1...16_384).contains(height.intValue),width.int64Value * height.int64Value <= 16_777_216,
                  let representation = NSBitmapImageRep(data:data),let png = representation.representation(using:.png,properties:[:]),png.count <= 20 * 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
            guard selected.count < 20 else { failure = "Select at most 20 files at a time.";return }
            try FileManager.default.createDirectory(at:CaptureAttachment.staging,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let url = CaptureAttachment.staging.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
            try png.write(to:url,options:.atomic)
            pending.append(.init(destination:destination,url:url,mode:"managed",ownedStaging:true))
            CaptureAttachmentDrafts.save(pending,destination:destination,preferences:store.windowPreferences)
        } catch { failure = "The clipboard image could not be prepared. Use a local image file instead." }
    }
    private func paste() {
        if let urls = NSPasteboard.general.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],!urls.isEmpty { add(urls);return }
        if let bytes = NSPasteboard.general.data(forType:.png) ?? NSPasteboard.general.data(forType:.tiff) { image(bytes) }
        else { failure = "The clipboard has no local file or image." }
    }
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard canSelect,providers.count <= 20 else { return false }
        let selectedMode = mode,expectedDestination = destination,generation = dropGeneration
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil) { value,_ in
                    let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation:$0,relativeTo:nil) }
                    Task { @MainActor in
                        guard dropGeneration == generation,destination == expectedDestination,!store.busy,!store.hasPendingMutation else { store.notice = "Drop destination is no longer ready; existing selections were preserved. Drop again in the intended destination.";return }
                        if let url { add([url],mode:selectedMode) }
                    }
                }
            } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to:.image) == true }) {
                provider.loadDataRepresentation(forTypeIdentifier:type) { bytes,_ in Task { @MainActor in
                    guard dropGeneration == generation,destination == expectedDestination,!store.busy,!store.hasPendingMutation else { store.notice = "Drop destination is no longer ready; existing selections were preserved. Drop again in the intended destination.";return }
                    if let bytes { image(bytes) }
                } }
            }
        }
        return true
    }
}

@MainActor
enum CaptureAttachmentUpload {
    /// Original IDs remain stable through known-outcome retry/reconciliation.
    static func send(_ files: [CaptureAttachment],projectID: String,taskID: String,store: ChecklistStore,accepted: @escaping (UUID) -> Void,completion: @escaping () -> Void) {
        guard let first = files.first else { completion();return }
        guard Data(first.destination.projectID.utf8) == Data(projectID.utf8),Data(first.destination.storeIncarnation.utf8) == Data(store.storeIncarnation.utf8),first.destination.taskID == nil || first.destination.taskID.map {Data($0.utf8)} == Data(taskID.utf8) else { store.error = "The attachment destination changed. Its selection is preserved.";return }
        store.run("attachment_add",["command_id":first.commandID,"project_id":projectID,"task_id":taskID,"path":first.url.path,"mode":first.mode],success:"File attached") { reply in
            guard let id = reply["id"] as? String,!id.isEmpty,reply["sha256"] is String,
                  (reply["project_id"] as? String).map({Data($0.utf8)}) == Data(projectID.utf8),
                  (reply["task_id"] as? String).map({Data($0.utf8)}) == Data(taskID.utf8) else { store.error = "The file may already be added. Check it again; your selection is kept.";return }
            accepted(first.id);CaptureAttachmentDrafts.accepted(first,preferences:store.windowPreferences);first.removeOwnedStaging()
            send(Array(files.dropFirst()),projectID:projectID,taskID:taskID,store:store,accepted:accepted,completion:completion)
        }
    }
}
