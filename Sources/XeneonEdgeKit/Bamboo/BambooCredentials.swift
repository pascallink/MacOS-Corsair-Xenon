// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Token-Suche fuer Bamboo - bewusst nur lesend gegen die Keychain, kein
// Codepfad kann einen von Hand angelegten Eintrag schreiben oder loeschen.

import Foundation
import Security

/// Quelle fuer ein Bamboo-Zugriffstoken, pro Host aufgeloest.
public protocol BambooTokenSource {
    func token(forHost host: String) -> String?
}

/// Liest das Token aus der Keychain (generisches Passwort, Service
/// `"xeneon-bamboo"`, Account = Host), Rueckfall Umgebungsvariable
/// `XENEON_BAMBOO_TOKEN`. Schreibt nie in die Keychain und loggt weder Status
/// noch Wert.
public struct KeychainBambooTokenSource: BambooTokenSource {
    public init() {}

    public func token(forHost host: String) -> String? {
        if let fromKeychain = readFromKeychain(host: host), !fromKeychain.isEmpty {
            return fromKeychain
        }
        let fromEnvironment = ProcessInfo.processInfo.environment["XENEON_BAMBOO_TOKEN"]
        guard let fromEnvironment, !fromEnvironment.isEmpty else { return nil }
        return fromEnvironment
    }

    private func readFromKeychain(host: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "xeneon-bamboo",
            kSecAttrAccount: host,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
