import Foundation

extension CommandRouter {
    static var ticketBulkTasksSchema: JSON {
        ["type":"array","minItems":1,"maxItems":200,"items":["type":"object","properties":["task_id":["type":"string","minLength":1,"maxLength":4000],"expected_revision":["type":"integer","minimum":1]],"required":["task_id","expected_revision"],"additionalProperties":false]]
    }
    static var ticketBulkChangesSchema: JSON {
        func choice(_ kind: String,_ properties: JSON,_ required: [String]) -> JSON {
            var fields = properties;fields["kind"] = ["const":kind]
            return ["type":"object","properties":fields,"required":["kind"]+required,"additionalProperties":false]
        }
        let id: JSON = ["type":"string","minLength":1,"maxLength":4000]
        let tags: JSON = ["type":"array","items":id,"maxItems":200,"uniqueItems":true]
        var status = choice("status",["action":["enum":["queue","defer","block","cancel","reopen"]],"reason":["type":"string","maxLength":4000]],["action"])
        status["allOf"] = [["if":["properties":["action":["enum":["cancel","reopen"]]]],"then":["required":["reason"],"properties":["reason":["minLength":1,"pattern":"\\S"]]]]]
        return ["type":"object","oneOf":[
            status,
            choice("tags",["add":tags,"remove":tags],[]),
            choice("assignee",["planned_assignee":["oneOf":[["enum":["human","unassigned"]],["type":"object","properties":["kind":["enum":["human","unassigned","agent"]],"provider":id,"session_id":id],"required":["kind"],"additionalProperties":false]]],"assignment_reason":["type":"string","maxLength":2000]],["planned_assignee"]),
            choice("epic",["epic_id":["type":["string","null"],"maxLength":4000]],["epic_id"]),
            choice("triage",["triage_id":id,"action":["enum":["add","remove"]]],["triage_id","action"]),
            choice("archive",["action":["enum":["archive","unarchive","trash","restore"]]],["action"])
        ]]
    }
}
