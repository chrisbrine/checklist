import Foundation
import Darwin
import CoreFoundation

/// Identity comes only from the executable's containing bundle, including for helpers.
public struct ChecklistInstance {
    public let slot: Int?
    public let bundleURL: URL?
    public let bundleIdentifier: String
    public let displayName: String
    public let machServiceName: String
    public let keychainService: String
    public let root: URL
    public let ownerDataRoot: URL
    public var bundleFileName: String { displayName + ".app" }
    public var ownerPathSuffix: String { "/" + bundleFileName + "/Contents/MacOS/ChecklistApp" }
    public var ownerRequirement: String { "identifier \"\(bundleIdentifier)\"" }
    public var agentPlistName: String { machServiceName + ".plist" }
    public var retiredAgentPlistName: String { slot.map { "org.checklist.test\($0).service.plist" } ?? "org.checklist.service.plist" }
    public var startInstruction: String { "Start this test slot with script/test_instances.py start --slot \(slot ?? 0)" }
    public var cliCommand: String {
        guard slot != nil else { return "/Applications/Checklist.app/Contents/MacOS/checklist" }
        let bundle = bundleURL ?? root.deletingLastPathComponent().appendingPathComponent(bundleFileName)
        return "'" + bundle.appendingPathComponent("Contents/MacOS/checklist").path.replacingOccurrences(of:"'",with:"'\\''") + "'"
    }

    public init(slotValue: Any? = nil, bundleURL: URL? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String:String] = ProcessInfo.processInfo.environment) throws {
        if let slotValue {
            guard let number = slotValue as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !["f", "d"].contains(String(cString:number.objCType)), (1...4).contains(number.intValue),
                  number == NSNumber(value:number.intValue) else {
                throw ChecklistError("INVALID_INSTANCE_SLOT", "ChecklistInstanceSlot must be an integer from 1 through 4; omit it for the live instance.")
            }
            slot = number.intValue
        } else { slot = nil }
        self.bundleURL = bundleURL
        if let slot {
            bundleIdentifier = "org.checklist.app.test\(slot)"
            displayName = "Checklist Test \(slot)"
            machServiceName = "org.checklist.test\(slot).coordination"
            keychainService = "org.checklist.test\(slot).enrollments"
            root = home.appendingPathComponent("Library/Application Support/Checklist Test Instances/slot-\(slot)/data", isDirectory:true)
            let live = try ChecklistInstance(home:home,environment:environment)
            guard try !Self.rootsOverlap(root,live.root),
                  bundleIdentifier != live.bundleIdentifier, machServiceName != live.machServiceName,
                  keychainService != live.keychainService else {
                throw ChecklistError("INSTANCE_COLLISION", "A test instance must not use the live store or identity.")
            }
        } else {
            bundleIdentifier = "org.checklist.app"; displayName = "Checklist"
            machServiceName = "org.checklist.coordination"; keychainService = "org.checklist.local.enrollments"
            if let path = environment["CHECKLIST_DATA_ROOT"], !path.isEmpty {
                root = URL(fileURLWithPath:path)
                let testTree = home.appendingPathComponent("Library/Application Support/Checklist Test Instances",isDirectory:true)
                guard try !Self.rootsOverlap(root,testTree) else {
                    throw ChecklistError("INSTANCE_COLLISION", "CHECKLIST_DATA_ROOT must not overlap the reserved test instance tree.")
                }
            }
            else { root = home.appendingPathComponent("Library/Application Support/Checklist", isDirectory:true) }
        }
        ownerDataRoot = slot == nil ? home.appendingPathComponent("Library/Application Support/Checklist") : root
    }

    static func rootsOverlap(_ left: URL,_ right: URL) throws -> Bool {
        let a = try canonicalRoot(left), b = try canonicalRoot(right)
        if a.missing.isEmpty && b.missing.isEmpty {
            if a.device == b.device && a.inode == b.inode { return true }
            if try hasAncestor(b.existing,matching:a) || hasAncestor(a.existing,matching:b) { return true }
        }
        let aParts = a.foldedComponents, bParts = b.foldedComponents
        return aParts.starts(with:bParts) || bParts.starts(with:aParts)
    }

    private struct CanonicalRoot {
        let existing: URL
        let missing: [String]
        let device: dev_t
        let inode: ino_t
        var foldedComponents: [String] {
            (existing.pathComponents + missing).map {
                $0.decomposedStringWithCanonicalMapping.folding(options:[.caseInsensitive],locale:nil).decomposedStringWithCanonicalMapping
            }
        }
    }

    private static func hasAncestor(_ path: URL,matching root: CanonicalRoot) throws -> Bool {
        var ancestor = path.deletingLastPathComponent()
        while true {
            var info = stat()
            guard stat(ancestor.path,&info) == 0 else {
                throw ChecklistError("INSTANCE_COLLISION", "Cannot verify an existing instance root ancestor.")
            }
            if info.st_dev == root.device && info.st_ino == root.inode { return true }
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { return false }
            ancestor = parent
        }
    }

    private static func canonicalRoot(_ url: URL) throws -> CanonicalRoot {
        var existing = try resolvingLinks(url), missing: [String] = [], before = stat()
        while stat(existing.path,&before) != 0 {
            guard errno == ENOENT || errno == ENOTDIR else {
                throw ChecklistError("INSTANCE_COLLISION", "Cannot inspect an instance root.")
            }
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else {
                throw ChecklistError("INSTANCE_COLLISION", "Cannot find an existing instance root ancestor.")
            }
            missing.insert(existing.lastPathComponent,at:0)
            existing = parent
        }
        let descriptor = open(existing.path,O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ChecklistError("INSTANCE_COLLISION", "Cannot open an instance root ancestor.") }
        defer { close(descriptor) }
        var actual = stat(), spelling = [CChar](repeating:0,count:Int(MAXPATHLEN))
        guard fstat(descriptor,&actual) == 0, before.st_dev == actual.st_dev, before.st_ino == actual.st_ino,
              fcntl(descriptor,F_GETPATH,&spelling) == 0 else {
            throw ChecklistError("INSTANCE_COLLISION", "Cannot verify the canonical instance root spelling and identity.")
        }
        return CanonicalRoot(existing:URL(fileURLWithPath:String(cString:spelling)),missing:missing,device:actual.st_dev,inode:actual.st_ino)
    }

    private static func resolvingLinks(_ url: URL) throws -> URL {
        // Foundation can leave aliases unresolved when a later component is absent.
        // Walk links before normalizing '..', including dangling links into future stores.
        var pending = Array(url.pathComponents.dropFirst().reversed())
        var resolved = URL(fileURLWithPath:"/",isDirectory:true), links = 0
        while let component = pending.popLast() {
            if component == "." { continue }
            if component == ".." { resolved.deleteLastPathComponent(); continue }
            let candidate = resolved.appendingPathComponent(component)
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath:candidate.path) {
                links += 1
                guard links <= 40 else {
                    throw ChecklistError("INSTANCE_COLLISION", "Cannot resolve instance roots: too many symbolic links.")
                }
                if target.hasPrefix("/") { resolved = URL(fileURLWithPath:"/",isDirectory:true) }
                pending.append(contentsOf:target.split(separator:"/").map(String.init).reversed())
            } else { resolved = candidate }
        }
        // Keep physical components; Foundation may shorten only existing /private paths.
        return resolved
    }

    public static var executableURL: URL {
        var bytes = [CChar](repeating:0,count:4096)
        let path = proc_pidpath(getpid(),&bytes,UInt32(bytes.count)) > 0 ? String(cString:bytes) : CommandLine.arguments[0]
        return URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath()
    }
    public static func read(executable: URL) throws -> ChecklistInstance {
        let contents = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents", bundle.pathExtension == "app" else { return try ChecklistInstance() }
        let plistURL = contents.appendingPathComponent("Info.plist")
        // A containing app without a readable identity is damaged, never live.
        let data = try Data(contentsOf:plistURL)
        guard let plist = try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any] else {
            throw ChecklistError("INVALID_INSTANCE_SLOT", "Cannot read the containing bundle's instance identity.")
        }
        return try ChecklistInstance(slotValue:plist["ChecklistInstanceSlot"],bundleURL:bundle)
    }
    public static let current: ChecklistInstance = {
        do { return try read(executable:executableURL) }
        catch { fputs("Checklist: \(error.localizedDescription)\n",stderr); exit(78) }
    }()
}
