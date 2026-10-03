// Copyright 2026 Kinooz.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import SwiftUI
import CommonCrypto
import Security

struct MiyaPhraseStore {
    private struct Record: Codable {
        let salt: Data
        let key: Data
        let length: Int
    }
    private let service: String

    init(service: String = "nl.kinooz.miya.native-unlock") {
        self.service = service
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "phrase"]
    }

    var isConfigured: Bool { record != nil }

    func set(_ phrase: String) throws {
        let normalized = phrase.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard normalized.count >= 8, !phrase.contains("\n") else { throw Failure.invalidPhrase }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.storage }
        let key = derive(normalized, salt: salt)
        guard key.count == 32 else { throw Failure.storage }
        let value = try JSONEncoder().encode(Record(salt: salt, key: key, length: normalized.count))
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.storage }
        } else if update != errSecSuccess { throw Failure.storage }
    }

    func removingTrigger(from draft: String) -> String? {
        guard let record, record.key.count == 32 else { return nil }
        var offset = draft.startIndex
        for line in draft.split(separator: "\n", omittingEmptySubsequences: false) {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count == record.length {
                let key = derive(candidate, salt: record.salt)
                let difference = zip(key, record.key).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
                if key.count == record.key.count, difference == 0,
                   let range = draft.range(of: candidate, range: offset..<draft.endIndex) {
                    var sanitized = draft
                    sanitized.removeSubrange(range)
                    return sanitized
                }
            }
            if let newline = draft[offset...].firstIndex(of: "\n") { offset = draft.index(after: newline) }
        }
        return nil
    }

    private var record: Record? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func derive(_ phrase: String, salt: Data) -> Data {
        let password = Array(phrase.precomposedStringWithCanonicalMapping.utf8)
        var key = Data(count: 32)
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                key.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                        passwordBytes.bindMemory(to: Int8.self).baseAddress, password.count,
                                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 100_000,
                                        output.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        return status == kCCSuccess ? key : Data()
    }

    enum Failure: Error { case invalidPhrase, storage }
}
