import Foundation
import Testing
@testable import PeekCore

@Suite struct JSONValueTests {
    @Test func boolsStayBoolsNotNumbers() {
        let json = JSONValue.parse(Data(#"{"a":true,"b":1}"#.utf8))
        #expect(json?["a"]?.boolValue == true)
        #expect(json?["a"]?.intValue == nil)
        #expect(json?["b"]?.intValue == 1)
        #expect(json?["b"]?.boolValue == nil)
    }

    @Test func nestedSubscript() {
        let json = JSONValue.parse(Data(#"{"outer":{"inner":"hi"}}"#.utf8))
        #expect(json?["outer"]?["inner"]?.stringValue == "hi")
        #expect(json?["missing"] == nil)
    }

    @Test func arrayValue() {
        let json = JSONValue.parse(Data(#"{"list":[1,2,3]}"#.utf8))
        #expect(json?["list"]?.arrayValue?.count == 3)
        #expect(json?["list"]?.arrayValue?.first?.intValue == 1)
    }

    @Test func badInputIsNil() {
        #expect(JSONValue.parse(Data("not json".utf8)) == nil)
        #expect(JSONValue.parse(Data()) == nil)
    }

    @Test func subscriptOnNonObjectIsNil() {
        let json = JSONValue.parse(Data(#""just a string""#.utf8))
        #expect(json?["key"] == nil)
        #expect(json?.stringValue == "just a string")
    }
}
