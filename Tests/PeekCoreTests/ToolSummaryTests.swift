import Foundation
import Testing
@testable import PeekCore

@Suite struct ToolSummaryTests {
    @Test func bashShowsCommand() {
        let input = JSONValue.parse(Data(#"{"command":"npm test"}"#.utf8))
        #expect(ToolSummary.make(tool: "Bash", input: input, cwd: nil) == "Bash npm test")
    }

    @Test func editIsRelativeToCwd() {
        let input = JSONValue.parse(Data(#"{"file_path":"/Users/m/src/sync/main.go"}"#.utf8))
        #expect(ToolSummary.make(tool: "Edit", input: input, cwd: "/Users/m/src/sync") == "Edit main.go")
    }

    @Test func editOutsideCwdStaysAbsolute() {
        let input = JSONValue.parse(Data(#"{"file_path":"/etc/hosts"}"#.utf8))
        #expect(ToolSummary.make(tool: "Edit", input: input, cwd: "/Users/m/src/sync") == "Edit /etc/hosts")
    }

    @Test func webFetchShowsURL() {
        let input = JSONValue.parse(Data(#"{"url":"https://example.com"}"#.utf8))
        #expect(ToolSummary.make(tool: "WebFetch", input: input, cwd: nil) == "WebFetch https://example.com")
    }

    @Test func grepShowsPattern() {
        let input = JSONValue.parse(Data(#"{"pattern":"TODO"}"#.utf8))
        #expect(ToolSummary.make(tool: "Grep", input: input, cwd: nil) == "Grep TODO")
    }

    @Test func nilToolIsNil() {
        #expect(ToolSummary.make(tool: nil, input: nil, cwd: nil) == nil)
    }

    @Test func toolWithNoDetailIsJustTheName() {
        #expect(ToolSummary.make(tool: "SomeTool", input: nil, cwd: nil) == "SomeTool")
    }

    @Test func longLineIsCutTo60Chars() {
        let long = String(repeating: "x", count: 200)
        let input = JSONValue.parse(Data(#"{"command":"\#(long)"}"#.utf8))
        let line = ToolSummary.make(tool: "Bash", input: input, cwd: nil)
        #expect(line?.count == 60)
    }
}
