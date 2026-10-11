import Foundation

/// Maps Messages handles (phone numbers, emails) to contact names.
public struct HandleDirectory: Sendable {
    public struct Entry: Sendable {
        public let name: String
        public let phones: [String]
        public let emails: [String]
        public let nickname: String?
        public let photo: Data?

        public init(name: String, phones: [String], emails: [String], nickname: String? = nil, photo: Data? = nil) {
            self.name = name
            self.phones = phones
            self.emails = emails
            self.nickname = nickname
            self.photo = photo
        }
    }

    private var entries: [Entry] = []
    private var entryIndex: [String: Int] = [:]

    public init(entries: [Entry] = []) {
        self.entries = entries
        for (index, entry) in entries.enumerated() {
            for key in entry.phones.compactMap(Self.phoneKey) + entry.emails.compactMap(Self.emailKey) where entryIndex[key] == nil {
                entryIndex[key] = index
            }
        }
    }

    public func name(for handle: String) -> String? {
        contactKey(for: handle).map { entries[$0].name }
    }

    public func nickname(for handle: String) -> String? {
        contactKey(for: handle).flatMap { entries[$0].nickname }
    }

    public func photo(for handle: String) -> Data? {
        contactKey(for: handle).flatMap { entries[$0].photo }
    }

    public func photo(for conversation: Conversation) -> Data? {
        guard !conversation.isGroup else { return nil }
        return conversation.participants.lazy.compactMap { photo(for: $0) }.first
    }

    /// Identifies the contact card a handle belongs to, so one person's phone and email
    /// chats can be merged without conflating two contacts who share a name.
    public func contactKey(for handle: String) -> Int? {
        let key = handle.contains("@") ? Self.emailKey(handle) : Self.phoneKey(handle)
        return key.flatMap { entryIndex[$0] }
    }

    // Contacts store numbers in whatever format the user typed; Messages uses E.164. Comparing
    // the last ten digits absorbs country codes and punctuation; shorter numbers are short
    // codes and must match exactly.
    static func phoneKey(_ phone: String) -> String? {
        let digits = phone.filter(\.isASCIIDigit)
        guard !digits.isEmpty else { return nil }
        return "tel:" + (digits.count > 10 ? String(digits.suffix(10)) : digits)
    }

    static func emailKey(_ email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : "mail:" + trimmed
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
