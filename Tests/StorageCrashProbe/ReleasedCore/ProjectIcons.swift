import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

extension CommandRouter {
    func projectIcon(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        try owner(c); let pid = try scope(db,p,c,write:true); var project = try record(db,pid,type:"project"); try revision(p,project)
        if method == "project_icon_clear" { project.removeValue(forKey:"icon_path"); project.removeValue(forKey:"icon_asset") }
        else {
            let path = canonical(try text(p,"path")); let url = URL(fileURLWithPath:path)
            let values = try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
            guard values.isRegularFile == true,(values.fileSize ?? 0) <= 5*1024*1024 else { throw CoreError("INVALID_INPUT","Choose a PNG, JPEG or WebP image no larger than 5 MiB.") }
            let bytes = try Data(contentsOf:url,options:.mappedIfSafe)
            guard let source = CGImageSourceCreateWithData(bytes as CFData,nil),let type = CGImageSourceGetType(source) as String?,[UTType.png.identifier,UTType.jpeg.identifier,UTType.webP.identifier].contains(type),let props = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? JSON else { throw CoreError("INVALID_INPUT","The file is not a supported PNG, JPEG or WebP image.") }
            let width = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0,height = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
            guard width > 0,height > 0,width <= 4096,height <= 4096,let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:256] as CFDictionary) else { throw CoreError("INVALID_INPUT","The image dimensions must be at most 4096 pixels per edge.") }
            let id = uuid(),directory = root.appendingPathComponent("icons").appendingPathComponent(pid);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let output = directory.appendingPathComponent(id+".png")
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL,UTType.png.identifier as CFString,1,nil) else { throw CoreError("FILE_ACCESS_REQUIRED","The app could not write its normalized project icon.") }
            CGImageDestinationAddImage(destination,image,[:] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CoreError("FILE_ACCESS_REQUIRED","The normalized icon could not be saved.") }
            let normalized = try Data(contentsOf:output)
            project["icon_path"] = output.path
            project["icon_asset"] = ["id":id,"sha256":hash(normalized),"width":image.width,"height":image.height,"fallback_symbol":project["icon"] ?? "folder","label":project["name"] ?? "Project"]
        }
        project = revised(project);try save(db,project,type:"project");try event(db,caller:c,project:pid,entity:pid,kind:method == "project_icon_clear" ? "project_icon_cleared" : "project_icon_imported",data:["icon_asset_id":(project["icon_asset"] as? JSON)?["id"] ?? NSNull()]);return project
    }
    func projectProjection(_ source: JSON,caller: Caller) -> JSON {
        guard !caller.isOwner else { return source }
        var project = source;project.removeValue(forKey:"icon_path")
        if caller.role == "assistant" { project.removeValue(forKey:"root_path") }
        return project
    }
}
