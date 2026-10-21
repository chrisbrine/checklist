import Foundation

/// Pure prompt preparation; this neither connects a conversation nor assigns work.
public enum ChecklistHandoff {
    public static func instruction(key: String,title: String,root: String,projectID: String,taskID: String,cliCommand: String) throws -> String {
        let args=try JSONSerialization.data(withJSONObject:["project_id":projectID,"task_id":taskID],options:[.sortedKeys])
        let json=String(decoding:args,as:UTF8.self)
        return "Use Checklist for \(key): \(title). Work in \(root). Run \(cliCommand) connect --task \(taskID) from that workspace; it registers this actual thread and attaches it to the ticket. Then run \(cliCommand) call task_context '\(json)' to read the task, project rules and notes. Run checklist tools for the supported schemas. Connecting alone does not claim or assign work."
    }
}
