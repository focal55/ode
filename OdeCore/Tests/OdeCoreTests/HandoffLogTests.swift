import Foundation
import Testing
@testable import OdeCore

@Suite struct HandoffLogTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-log-\(UUID().uuidString)", isDirectory: true)
    var log: HandoffLog { HandoffLog(directory: directory) }
    let at = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func missingFilesReadAsEmpty() throws {
        #expect(try log.pending().isEmpty)
        #expect(try log.kept().isEmpty)
    }

    @Test func recordedHandoffsSurviveAReload() throws {
        try log.record(Handoff(conversationID: 7, at: at))
        try log.record(Handoff(conversationID: 8, at: at))
        #expect(try HandoffLog(directory: directory).pending() == [Handoff(conversationID: 7, at: at), Handoff(conversationID: 8, at: at)])
    }

    @Test func recordingAgainKeepsTheEarlierPendingHandoff() throws {
        try log.record(Handoff(conversationID: 7, at: at))
        try log.record(Handoff(conversationID: 7, at: at.addingTimeInterval(600)))
        #expect(try log.pending() == [Handoff(conversationID: 7, at: at)])
    }

    @Test func aCorruptPendingFileDoesNotBlockRecording() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("handoffs.json"))
        try log.record(Handoff(conversationID: 7, at: at))
        #expect(try log.pending() == [Handoff(conversationID: 7, at: at)])
    }

    @Test func appendingTheSameKeptEventTwiceKeepsOne() throws {
        let event = Kept(conversationID: 7, handoffAt: at, sentAt: at.addingTimeInterval(60), messageID: 1)
        try log.appendKept([event])
        try log.appendKept([event])
        #expect(try log.kept() == [event])
    }

    @Test func keptEventsAppend() throws {
        let first = Kept(conversationID: 7, handoffAt: at, sentAt: at.addingTimeInterval(60), messageID: 1)
        let second = Kept(conversationID: 8, handoffAt: at, sentAt: at.addingTimeInterval(90), messageID: 2)
        try log.appendKept([first])
        try log.appendKept([second])
        #expect(try log.kept() == [first, second])
    }

    @Test func replacePendingOverwrites() throws {
        try log.record(Handoff(conversationID: 7, at: at))
        try log.replacePending([])
        #expect(try log.pending().isEmpty)
    }

    @Test func aCorruptKeptLogIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("kept.json")
        try Data("not json".utf8).write(to: file)
        #expect(throws: (any Error).self) {
            try log.appendKept([Kept(conversationID: 7, handoffAt: at, sentAt: at, messageID: 1)])
        }
        #expect(try Data(contentsOf: file) == Data("not json".utf8))
    }
}
