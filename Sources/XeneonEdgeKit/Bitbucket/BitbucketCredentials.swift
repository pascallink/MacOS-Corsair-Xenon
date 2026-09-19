// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Token lookup for Bitbucket Data Center — deliberately read-only against the
// keychain so no code path here can ever write, overwrite or delete a
// credential the user placed there by hand.

import Foundation
import Security

/// Quelle fuer ein Bitbucket-Zugriffstoken, pro Host aufgeloest.
public protocol BitbucketTokenSource {
    func token(forHost host: String) -> String?
}

/// Liest ein Bitbucket-Token aus der Keychain, mit Rueckfall auf die
/// Umgebungsvariable `XENEON_BITBUCKET_TOKEN`. Schreibt nie in die Keychain -
/// das Anlegen des Eintrags ist bewusst ein manueller Schritt ausserhalb
/// dieses Kits.
public struct KeychainTokenSource: BitbucketTokenSource {
    public init() {}

    /// Sucht ein generisches Passwort mit Service `"xeneon-bitbucket"` und
    /// dem uebergebenen Host als Account. Liefert die Umgebungsvariable
    /// `XENEON_BITBUCKET_TOKEN` als Rueckfall, wenn die Keychain keinen oder
    /// nur einen leeren Wert liefert. Ist auch der Rueckfall leer, ist das
    /// Ergebnis `nil`.
    public func token(forHost host: String) -> String? {
        if let fromKeychain = readFromKeychain(host: host), !fromKeychain.isEmpty {
            return fromKeychain
        }

        let fromEnvironment = ProcessInfo.processInfo.environment["XENEON_BITBUCKET_TOKEN"]
        guard let fromEnvironment, !fromEnvironment.isEmpty else { return nil }
        return fromEnvironment
    }

    /// Liest den gespeicherten Wert per `SecItemCopyMatching`. Jeder Status
    /// ausser `errSecSuccess` und jeder nicht als UTF-8 lesbare Wert ergeben
    /// `nil` - es wird nie geloggt, welcher Status das war.
    private func readFromKeychain(host: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "xeneon-bitbucket",
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
