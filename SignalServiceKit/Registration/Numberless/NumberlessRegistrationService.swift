//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Executes the privacy boundary of numberless registration: the invitation is
/// exchanged first, and only the unlinkable receipt presentation is sent to the
/// account-creation endpoint.
public final class NumberlessRegistrationService {
    public struct Result {
        public let identity: RegistrationServiceResponses.NumberlessAccountIdentityResponse
        public let authPassword: String
    }
    private let invitationCredentialService: InvitationCredentialService
    private let networkManager: NetworkManager
    private let logger = PrefixedLogger(prefix: "[NumberlessRegistrationService]")

    public init(networkManager: NetworkManager) {
        self.networkManager = networkManager
        self.invitationCredentialService = InvitationCredentialService(networkManager: networkManager)
    }

    public func register(
        invitationCode: String,
        accountAttributes: AccountAttributes,
        apnRegistrationId: RegistrationRequestFactory.ApnRegistrationId?,
        aciPrekeyBundle: RegistrationPreKeyUploadBundle
    ) async throws -> Result {
        let claimedInvitation = try await invitationCredentialService.claim(invitationCode: invitationCode)
        let request = RegistrationRequestFactory.createNumberlessAccountRequest(
            receiptCredentialPresentation: claimedInvitation.presentation.serialize(),
            authPassword: claimedInvitation.authPassword,
            accountAttributes: accountAttributes,
            apnRegistrationId: apnRegistrationId,
            aciPrekeyBundle: aciPrekeyBundle,
            logger: logger,
        )
        let response = try await networkManager.asyncRequest(request)
        guard response.responseStatusCode == 200, let body = response.responseBodyData else {
            throw response.asError()
        }
        do {
            let identity = try JSONDecoder().decode(
                RegistrationServiceResponses.NumberlessAccountIdentityResponse.self,
                from: body,
            )
            invitationCredentialService.clearPendingClaim()
            return Result(identity: identity, authPassword: claimedInvitation.authPassword)
        } catch {
            throw OWSAssertionError("Invalid numberless registration response: \(error)")
        }
    }
}
