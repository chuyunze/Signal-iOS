//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import CryptoKit
public import LibSignalClient

/// Client-side half of the one-time invitation protocol. The invitation is sent
/// only to the claim endpoint; account creation receives an unlinkable ZK receipt.
public final class InvitationCredentialService {
    public static let loginReceiptLevel: UInt64 = 300

    private let networkManager: NetworkManager
    private let keychainStorage: KeychainStorage
    private let logger = PrefixedLogger(prefix: "[InvitationCredentialService]")
    private static let keychainService = "org.signal.numberless-registration"
    private static let pendingClaimKey = "pending-invitation-claim"

    public init(
        networkManager: NetworkManager,
        keychainStorage: KeychainStorage = KeychainStorageImpl(
            isUsingProductionService: TSConstants.isUsingProductionService
        )
    ) {
        self.networkManager = networkManager
        self.keychainStorage = keychainStorage
    }

    public struct ClaimedInvitation {
        public let presentation: ReceiptCredentialPresentation
        public let authPassword: String
    }

    public func claim(invitationCode: String) async throws -> ClaimedInvitation {
        let normalizedCode = invitationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...128).contains(normalizedCode.count) else {
            throw OWSAssertionError("Invalid invitation format")
        }

        let codeDigest = Data(SHA256.hash(data: Data(normalizedCode.utf8)))
        let prepared: (
            context: ReceiptCredentialRequestContext,
            request: ReceiptCredentialRequest,
            pending: PendingClaim
        )
        if let pending = try? loadPendingClaim(), pending.codeDigest == codeDigest {
            do {
                prepared = (
                    try ReceiptCredentialRequestContext(contents: pending.context),
                    try ReceiptCredentialRequest(contents: pending.request),
                    pending
                )
                logger.info("Reusing the pending invitation credential request.")
            } catch {
                logger.warn("Discarding an unreadable pending invitation credential request: \(error)")
                clearPendingClaim()
                prepared = try generateAndPersistRequest(codeDigest: codeDigest)
            }
        } else {
            prepared = try generateAndPersistRequest(codeDigest: codeDigest)
        }
        let networkRequest = RegistrationRequestFactory.claimInvitationRequest(
            invitationCode: normalizedCode,
            receiptCredentialRequest: prepared.request.serialize(),
            logger: logger,
        )
        logger.info("Requesting an invitation receipt credential.")
        let credential = try await ReceiptCredentialManager(
            dateProvider: Date.init,
            logger: logger,
            networkManager: networkManager,
        ).requestReceiptCredential(
            via: networkRequest,
            isValidReceiptLevelPredicate: { $0 == Self.loginReceiptLevel },
            context: prepared.context,
        )
        logger.info("Received and validated the invitation receipt credential.")
        let presentation = try ReceiptCredentialManager.generateReceiptCredentialPresentation(
            receiptCredential: credential,
        )
        // Use the in-memory password. Reading it from Keychain again here could
        // strand a successfully claimed single-use invitation if the read fails.
        return ClaimedInvitation(presentation: presentation, authPassword: prepared.pending.authPassword)
    }

    /// Clear only after account creation succeeds. Keeping the request context
    /// until then lets an interrupted registration retrieve the same receipt.
    public func clearPendingClaim() {
        try? keychainStorage.removeValue(service: Self.keychainService, key: Self.pendingClaimKey)
    }

    private struct PendingClaim: Codable {
        let codeDigest: Data
        let context: Data
        let request: Data
        let authPassword: String
    }

    private func loadPendingClaim() throws -> PendingClaim {
        let data = try keychainStorage.dataValue(
            service: Self.keychainService,
            key: Self.pendingClaimKey
        )
        return try JSONDecoder().decode(PendingClaim.self, from: data)
    }

    private func savePendingClaim(_ pendingClaim: PendingClaim) throws {
        try keychainStorage.setDataValue(
            JSONEncoder().encode(pendingClaim),
            service: Self.keychainService,
            key: Self.pendingClaimKey
        )
    }

    private func generateAndPersistRequest(codeDigest: Data) throws -> (
        context: ReceiptCredentialRequestContext,
        request: ReceiptCredentialRequest,
        pending: PendingClaim
    ) {
        let request = ReceiptCredentialManager.generateReceiptRequest()
        let pending = PendingClaim(
            codeDigest: codeDigest,
            context: request.context.serialize(),
            request: request.request.serialize(),
            authPassword: Randomness.generateRandomBytes(16).hexadecimalString,
        )
        do {
            try savePendingClaim(pending)
        } catch {
            logger.error("Failed to persist the pending invitation credential request: \(error)")
            throw error
        }
        logger.info("Persisted a new pending invitation credential request.")
        return (request.context, request.request, pending)
    }
}
