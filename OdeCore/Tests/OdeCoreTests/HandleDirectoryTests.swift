import Foundation
import Testing
@testable import OdeCore

@Suite struct HandleDirectoryTests {
    let directory = HandleDirectory(entries: [
        .init(name: "Mom", phones: ["+1 (555) 010-4471"], emails: ["Mom@Example.com"]),
        .init(name: "Maya Chen", phones: [], emails: ["maya@example.com"]),
        .init(name: "Pizza Place", phones: ["72345"], emails: []),
    ])

    @Test(arguments: ["+15550104471", "5550104471", "15550104471", "+1 555 010 4471"])
    func phoneFormatsMatch(_ handle: String) {
        #expect(directory.name(for: handle) == "Mom")
    }

    @Test func emailsMatchCaseInsensitively() {
        #expect(directory.name(for: "mom@example.com") == "Mom")
        #expect(directory.name(for: "MAYA@example.com") == "Maya Chen")
    }

    @Test func shortCodesMatchExactly() {
        #expect(directory.name(for: "72345") == "Pizza Place")
        #expect(directory.name(for: "172345") == nil)
    }

    @Test func unknownHandlesAreNil() {
        #expect(directory.name(for: "+15559999999") == nil)
        #expect(directory.name(for: "stranger@example.com") == nil)
        #expect(directory.name(for: "") == nil)
    }

    @Test func firstContactWinsOnDuplicateHandles() {
        let directory = HandleDirectory(entries: [
            .init(name: "Work Phone", phones: ["5550104471"], emails: []),
            .init(name: "Mom", phones: ["+15550104471"], emails: []),
        ])
        #expect(directory.name(for: "+15550104471") == "Work Phone")
    }

    @Test func phoneAndEmailOfOneContactShareAKey() {
        #expect(directory.contactKey(for: "+15550104471") != nil)
        #expect(directory.contactKey(for: "+15550104471") == directory.contactKey(for: "mom@example.com"))
        #expect(directory.contactKey(for: "maya@example.com") != directory.contactKey(for: "mom@example.com"))
        #expect(directory.contactKey(for: "+15559999999") == nil)
    }

    @Test func photoAndNicknameFollowTheContact() {
        let photo = Data([1, 2, 3])
        let directory = HandleDirectory(entries: [
            .init(name: "Maya Chen", phones: ["+1 555 010 2222"], emails: ["maya@example.com"], nickname: "May", photo: photo),
            .init(name: "Sam Lee", phones: ["5550103333"], emails: []),
        ])
        #expect(directory.photo(for: "+15550102222") == photo)
        #expect(directory.photo(for: "MAYA@example.com") == photo)
        #expect(directory.nickname(for: "maya@example.com") == "May")
        #expect(directory.photo(for: "5550103333") == nil)
        #expect(directory.nickname(for: "5550103333") == nil)
        #expect(directory.photo(for: "+15559999999") == nil)
    }

    @Test func conversationPhotoComesFromAnyParticipantAndNeverForGroups() {
        let photo = Data([9])
        let directory = HandleDirectory(entries: [
            .init(name: "Maya Chen", phones: ["5550102222"], emails: ["maya@example.com"], photo: photo),
        ])
        func chat(_ id: Int64, _ handles: [String], group: Bool = false) -> Chat {
            Chat(id: id, identifier: handles[0], displayName: group ? "Crew" : nil, isGroup: group,
                 participants: handles, messageCount: 1, lastMessageDate: nil)
        }
        let merged = Conversation(chats: [chat(1, ["+15559999999"]), chat(2, ["maya@example.com"])])
        #expect(directory.photo(for: merged) == photo)
        #expect(directory.photo(for: Conversation(chats: [chat(3, ["+15559999999"])])) == nil)
        #expect(directory.photo(for: Conversation(chats: [chat(4, ["+15550102222", "+15559999999"], group: true)])) == nil)
    }
}
