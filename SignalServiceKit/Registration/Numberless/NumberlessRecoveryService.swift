//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import LibSignalClient

public final class NumberlessRecoveryService {
    public enum RecoveryError: Error, Equatable {
        case invalidCredentials
        case totpRequiredOrInvalid
        case rateLimited(retryAfter: TimeInterval?)
        case rejected
    }

    public struct Result {
        public let identity: RegistrationServiceResponses.NumberlessAccountIdentityResponse
        public let authPassword: String
    }

    private let networkManager: NetworkManager
    private let logger = PrefixedLogger(prefix: "[NumberlessRecoveryService]")

    public init(networkManager: NetworkManager) {
        self.networkManager = networkManager
    }

    public func recover(
        accountId: Aci,
        accountEntropyPool: AccountEntropyPool,
        totp: UInt32?,
        accountAttributes: AccountAttributes,
        apnRegistrationId: RegistrationRequestFactory.ApnRegistrationId?,
        aciPrekeyBundle: RegistrationPreKeyUploadBundle,
    ) async throws -> Result {
        let authPassword = Randomness.generateRandomBytes(16).hexadecimalString
        let recoveryPassword = accountEntropyPool.getMasterKey().deriveRegistrationRecoveryPassword()
        let request = RegistrationRequestFactory.recoverNumberlessAccountRequest(
            accountId: accountId,
            recoveryPassword: recoveryPassword,
            newAuthPassword: authPassword,
            totp: totp,
            accountAttributes: accountAttributes,
            apnRegistrationId: apnRegistrationId,
            aciPrekeyBundle: aciPrekeyBundle,
            logger: logger,
        )

        do {
            let response = try await networkManager.asyncRequest(request)
            guard response.responseStatusCode == 200, let body = response.responseBodyData else {
                throw RecoveryError.rejected
            }
            let identity = try JSONDecoder().decode(
                RegistrationServiceResponses.NumberlessAccountIdentityResponse.self,
                from: body,
            )
            guard identity.aci == accountId else {
                throw OWSAssertionError("Recovered account identifier did not match request")
            }
            return Result(identity: identity, authPassword: authPassword)
        } catch let error as OWSHTTPError {
            switch error.responseStatusCode {
            case 403:
                throw RecoveryError.invalidCredentials
            case 441:
                throw RecoveryError.totpRequiredOrInvalid
            case 429:
                throw RecoveryError.rateLimited(retryAfter: error.responseHeaders?.retryAfterTimeInterval)
            default:
                throw error
            }
        }
    }
}
