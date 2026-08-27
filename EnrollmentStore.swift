import Foundation
import Security

/// The enrolled owner template: a handful of embeddings captured under different
/// angles and lighting.
struct OwnerTemplate: Codable {
    var embedderIdentifier: String
    var vectors: [[Float]]
    var createdAt: Date
    var updatedAt: Date
}

/// Keychain-backed storage.
///
/// Deliberate design point: the template is stored **without** a biometric access
/// control flag. If reading it required user presence, the background watcher
/// could never read it — it would prompt for Touch ID on every frame. The
/// protection lives on the *write* and *delete* paths (which go through
/// `AuthGate`) and on `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, which keeps
/// the template on this Mac only and unreadable while the machine is locked.
///
/// The template is a set of float vectors, not an image. It cannot be turned
/// back into a photograph of your face.
enum EnrollmentStore {

    private static let service = "com.jacksonmafra.vakt"
    private static let account = "owner.template.v1"

    static func load() -> OwnerTemplate? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(OwnerTemplate.self, from: data)
    }

    /// Requires prior authentication. Call only from an `AuthGate`-guarded path.
    @discardableResult
    static func save(_ template: OwnerTemplate) -> Bool {
        guard let data = try? JSONEncoder().encode(template) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        add[kSecAttrLabel as String] = "VAKT owner face template"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(base as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
