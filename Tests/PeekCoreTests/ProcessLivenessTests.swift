import Foundation
import Testing
@testable import PeekCore

@Suite struct ProcessLivenessTests {
    @Test func aRunningProcessIsAlive() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        #expect(processIsAlive(process.processIdentifier))
    }

    @Test func aReapedProcessIsNotAlive() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.05"]
        try process.run()
        process.waitUntilExit()
        #expect(!processIsAlive(process.processIdentifier))
    }
}
