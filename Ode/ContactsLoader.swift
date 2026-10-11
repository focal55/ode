import Contacts
import OdeCore

enum ContactsLoader {
    static func directory() async -> HandleDirectory {
        guard (try? await CNContactStore().requestAccess(for: .contacts)) == true else { return HandleDirectory() }
        return await Task.detached { load() }.value
    }

    nonisolated private static func load() -> HandleDirectory {
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
        var entries: [HandleDirectory.Entry] = []
        try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
            guard !name.isEmpty else { return }
            entries.append(HandleDirectory.Entry(
                name: name,
                phones: contact.phoneNumbers.map(\.value.stringValue),
                emails: contact.emailAddresses.map { $0.value as String },
                nickname: contact.nickname.isEmpty ? nil : contact.nickname,
                photo: contact.thumbnailImageData
            ))
        }
        return HandleDirectory(entries: entries)
    }
}
