//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import LibSignalClient

public enum RegistrationRequestFactory {

    /// Exchanges a single-use invitation for an anonymous LOGIN receipt credential.
    public static func claimInvitationRequest(
        invitationCode: String,
        receiptCredentialRequest: Data,
        logger: PrefixedLogger,
    ) -> TSRequest {
        var result = TSRequest(
            url: URL(string: "v1/invitations/claim")!,
            method: "POST",
            parameters: [
                "invitationCode": invitationCode,
                "receiptCredentialRequest": receiptCredentialRequest.base64EncodedString(),
            ],
            logger: logger,
        )
        result.auth = .registration(nil)
        return result
    }

    // MARK: - Session API

    /// See `RegistrationServiceResponses.BeginSessionResponseCodes` for possible responses.
    public static func beginSessionRequest(
        e164: E164,
        pushToken: String?,
        mcc: String?,
        mnc: String?,
        logger: PrefixedLogger,
    ) -> TSRequest {
        let urlPathComponents = URLPathComponents(
            ["v1", "verification", "session"],
        )
        var urlComponents = URLComponents()
        urlComponents.percentEncodedPath = urlPathComponents.percentEncoded
        let url = urlComponents.url!

        var parameters: [String: Any] = [
            "number": e164.stringValue,
        ]
        if let pushToken {
            owsAssertDebug(!pushToken.isEmpty)
            parameters["pushToken"] = pushToken
            parameters["pushTokenType"] = "apn"
        }
        if let mcc {
            parameters["mcc"] = mcc
        }
        if let mnc {
            parameters["mnc"] = mnc
        }

        var result = TSRequest(url: url, method: "POST", parameters: parameters, logger: logger)
        result.auth = .registration(nil)
        return result
    }

    /// See `RegistrationServiceResponses.FetchSessionResponseCodes` for possible responses.
    public static func fetchSessionRequest(
        sessionId: String,
        logger: PrefixedLogger,
    ) -> TSRequest {
        owsAssertDebug(!sessionId.isEmpty)

        let urlPathComponents = URLPathComponents(
            ["v1", "verification", "session", sessionId],
        )
        var urlComponents = URLComponents()
        urlComponents.percentEncodedPath = urlPathComponents.percentEncoded
        let url = urlComponents.url!

        var result = TSRequest(url: url, method: "GET", parameters: nil, logger: logger)
        result.auth = .registration(nil)
        redactSessionIdFromLogs(sessionId, in: &result)
        return result
    }

    /// See `RegistrationServiceResponses.FulfillChallengeResponseCodes` for possible responses.
    /// TODO[Registration]: this can also take an APNS token to resend a push challenge. Push token challenges
    /// are  best-effort, but as an optimization we may want to do that.
    public static func fulfillChallengeRequest(
        sessionId: String,
        captchaToken: String?,
        pushChallengeToken: String?,
        logger: PrefixedLogger,
    ) -> TSRequest {
        owsAssertDebug(!sessionId.isEmpty)
        owsAssertDebug(!captchaToken.isEmptyOrNil || !pushChallengeToken.isEmptyOrNil)

        let urlPathComponents = URLPathComponents(
            ["v1", "verification", "session", sessionId],
        )
        var urlComponents = URLComponents()
        urlComponents.percentEncodedPath = urlPathComponents.percentEncoded
        let url = urlComponents.url!

        var parameters: [String: Any] = [:]
        if let captchaToken {
            parameters["captcha"] = captchaToken
        }
        if let pushChallengeToken {
            parameters["pushChallenge"] = pushChallengeToken
        }

        var result = TSRequest(url: url, method: "PATCH", parameters: parameters, logger: logger)
        result.auth = .registration(nil)
        redactSessionIdFromLogs(sessionId, in: &result)
        return result
    }

    public enum VerificationCodeTransport: String {
        case sms
        case voice
    }

    /// See `RegistrationServiceResponses.RequestVerificationCodeResponseCodes` for possible responses.
    ///
    /// - parameter languageCode: Language in which the client prefers to receive SMS or voice verification messages
    ///       If nil, english is used.
    /// - parameter countryCode: If provided, combined with language code.
    public static func requestVerificationCodeRequest(
        sessionId: String,
        languageCode: String?,
        countryCode: String?,
        transport: VerificationCodeTransport,
        logger: PrefixedLogger,
    ) -> TSRequest {
        owsAssertDebug(!sessionId.isEmpty)

        let urlPathComponents = URLPathComponents(
            ["v1", "verification", "session", sessionId, "code"],
        )
        var urlComponents = URLComponents()
        urlComponents.percentEncodedPath = urlPathComponents.percentEncoded
        let url = urlComponents.url!

        let parameters: [String: Any] = [
            "transport": transport.rawValue,
            "client": "ios",
        ]

        var languageCodes = [String]()
        if let languageCode {
            if let countryCode {
                languageCodes.append("\(languageCode)-\(countryCode)")
            }
            languageCodes.append(languageCode)
        }
        if !languageCodes.contains("en") {
            languageCodes.append("en")
        }

        let languageHeader: String = HttpHeaders.formatAcceptLanguageHeader(languageCodes)

        var result = TSRequest(url: url, method: "POST", parameters: parameters, logger: logger)
        result.auth = .registration(nil)
        result.headers[HttpHeaders.acceptLanguageHeaderKey] = languageHeader
        redactSessionIdFromLogs(sessionId, in: &result)
        return result
    }

    /// See `RegistrationServiceResponses.SubmitVerificationCodeResponseCodes` for possible responses.
    public static func submitVerificationCodeRequest(
        sessionId: String,
        code: String,
        logger: PrefixedLogger,
    ) -> TSRequest {
        owsAssertDebug(!sessionId.isEmpty)
        owsAssertDebug(!code.isEmpty)

        let urlPathComponents = URLPathComponents(
            ["v1", "verification", "session", sessionId, "code"],
        )
        var urlComponents = URLComponents()
        urlComponents.percentEncodedPath = urlPathComponents.percentEncoded
        let url = urlComponents.url!

        let parameters: [String: Any] = [
            "code": code,
        ]

        var result = TSRequest(url: url, method: "PUT", parameters: parameters, logger: logger)
        result.auth = .registration(nil)
        redactSessionIdFromLogs(sessionId, in: &result)
        return result
    }

    // MARK: - SVR2 Auth Check

    public static func svr2AuthCredentialCheckRequest(
        e164: E164,
        credentials: [SVR2AuthCredential],
        logger: PrefixedLogger,
    ) -> TSRequest {
        owsAssertDebug(!credentials.isEmpty)

        let urlPathComponents = URLPathComponents(
            ["v2", "svr", "auth", "check"],
        )
        var urlComponents = URLComponents()
        urlComponents.percentEncodedPath = urlPathComponents.percentEncoded
        let url = urlComponents.url!

        let parameters: [String: Any] = [
            "number": e164.stringValue,
            "passwords": credentials.map {
                "\($0.credential.username):\($0.credential.password)"
            },
        ]

        var result = TSRequest(url: url, method: "POST", parameters: parameters, logger: logger)
        result.auth = .registration(nil)
        return result
    }

    // MARK: - Account Creation/Change Number

    public enum VerificationMethod {
        /// The ID of an existing, validated RegistrationSession.
        case sessionId(String)
        /// Base64 encoded registration recovery password (derived from KBS master secret).
        case recoveryPassword(RegistrationRecoveryPassword)
        /// An anonymous LOGIN receipt issued after atomically claiming an invitation.
        case invitationReceipt(Data)
    }

    public struct ApnRegistrationId: Codable {
        public let apnsToken: String

        public init(apnsToken: String) {
            self.apnsToken = apnsToken
        }

        public enum CodingKeys: String, CodingKey {
            case apnsToken = "apnRegistrationId"
        }
    }

    /// Create an account, or re-register if one exists.
    ///
    /// - parameter verificationMethod: A way to verify phone number and account ownership.
    /// - parameter e164: The phone number being registered for.
    /// - parameter accountAttributes: Attributes for the account, same as those in
    ///   `updatePrimaryDeviceAttributesRequest`.
    /// - parameter skipDeviceTransfer: If true, indicates that the end user has elected
    ///   not to transfer data from another device even though a device transfer is technically possible
    ///   given the capabilities of the calling device and the device associated with the existing account (if any).
    ///   If false and if a device transfer is technically possible, the registration request will fail with an HTTP/409
    ///   response indicating that the client should prompt the user to transfer data from an existing device.
    /// - parameter apnRegistrationId: Apple Push Notification Service token(s) for the server to send
    ///   push notifications to. Either this must be non-nil, or `AccountAttributes.isManualMessageFetchEnabled`
    ///   must be true, otherwise the request will fail.
    /// - parameter prekeyBundles: Prekey information to include in the request; mirrors the requests to `v2/keys`.
    public static func createAccountRequest(
        verificationMethod: VerificationMethod,
        e164: E164,
        authPassword: String,
        accountAttributes: AccountAttributes,
        skipDeviceTransfer: Bool,
        apnRegistrationId: ApnRegistrationId?,
        prekeyBundles: RegistrationPreKeyUploadBundles,
        logger: PrefixedLogger,
    ) -> TSRequest {
        owsAssertDebug((apnRegistrationId != nil) != accountAttributes.isManualMessageFetchEnabled)

        let urlPathComponents = URLPathComponents(
            ["v1", "registration"],
        )
        var urlComponents = URLComponents()
        urlComponents.percentEncodedPath = urlPathComponents.percentEncoded
        let url = urlComponents.url!

        let jsonEncoder = JSONEncoder()
        let accountAttributesData = try! jsonEncoder.encode(accountAttributes)
        let accountAttributesDict = try! JSONSerialization.jsonObject(with: accountAttributesData, options: .fragmentsAllowed) as! [String: Any]

        var parameters: [String: Any] = [
            "accountAttributes": accountAttributesDict,
            "skipDeviceTransfer": skipDeviceTransfer,
            "aciIdentityKey": prekeyBundles.aci.identityKeyPair.keyPair.publicKey.serialize().base64EncodedStringWithoutPadding(),
            "pniIdentityKey": prekeyBundles.pni.identityKeyPair.keyPair.publicKey.serialize().base64EncodedStringWithoutPadding(),
            "aciSignedPreKey": OWSRequestFactory.signedPreKeyRequestParameters(prekeyBundles.aci.signedPreKey),
            "pniSignedPreKey": OWSRequestFactory.signedPreKeyRequestParameters(prekeyBundles.pni.signedPreKey),
            "aciPqLastResortPreKey": OWSRequestFactory.pqPreKeyRequestParameters(prekeyBundles.aci.lastResortPreKey),
            "pniPqLastResortPreKey": OWSRequestFactory.pqPreKeyRequestParameters(prekeyBundles.pni.lastResortPreKey),
            "requireAtomic": true,
        ]
        switch verificationMethod {
        case .sessionId(let sessionId):
            parameters["sessionId"] = sessionId
        case .recoveryPassword(let recoveryPassword):
            parameters["recoveryPassword"] = recoveryPassword.canonicalStringRepresentation
        case .invitationReceipt(let presentation):
            parameters["receiptCredentialPresentation"] = presentation.base64EncodedString()
        }

        if let apnRegistrationId {
            let apnRegistrationIdData = try! jsonEncoder.encode(apnRegistrationId)
            let apnRegistrationIdDict = try! JSONSerialization.jsonObject(with: apnRegistrationIdData, options: .fragmentsAllowed) as! [String: Any]
            parameters["apnToken"] = apnRegistrationIdDict
        }

        var result = TSRequest(url: url, method: "POST", parameters: parameters, logger: logger)
        // As odd as this is, it is to spec.
        result.auth = .registration((username: e164.stringValue, password: authPassword))
        result.headers["X-Signal-Agent"] = "OWI"
        return result
    }

    /// Creates an ACI-only account without assigning a phone number or PNI.
    public static func createNumberlessAccountRequest(
        receiptCredentialPresentation: Data,
        authPassword: String,
        accountAttributes: AccountAttributes,
        apnRegistrationId: ApnRegistrationId?,
        aciPrekeyBundle: RegistrationPreKeyUploadBundle,
        logger: PrefixedLogger,
    ) -> TSRequest {
        owsAssertDebug((apnRegistrationId != nil) != accountAttributes.isManualMessageFetchEnabled)

        let url = URL(string: "v1/registration")!
        let jsonEncoder = JSONEncoder()
        let attributes = numberlessAccountAttributes(accountAttributes, jsonEncoder: jsonEncoder)
        var parameters: [String: Any] = [
            "accountAttributes": attributes,
            "skipDeviceTransfer": true,
            "aciIdentityKey": aciPrekeyBundle.identityKeyPair.keyPair.publicKey.serialize().base64EncodedStringWithoutPadding(),
            "aciSignedPreKey": OWSRequestFactory.signedPreKeyRequestParameters(aciPrekeyBundle.signedPreKey),
            "aciPqLastResortPreKey": OWSRequestFactory.pqPreKeyRequestParameters(aciPrekeyBundle.lastResortPreKey),
            "receiptCredentialPresentation": receiptCredentialPresentation.base64EncodedString(),
            "requireAtomic": true,
        ]
        if let apnRegistrationId {
            let data = try! jsonEncoder.encode(apnRegistrationId)
            parameters["apnToken"] = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        }

        var result = TSRequest(url: url, method: "POST", parameters: parameters, logger: logger)
        // Numberless registration deliberately has no E164/basic-auth username.
        result.auth = .registration((username: "__no_number__", password: authPassword))
        result.headers["X-Signal-Agent"] = "OWI"
        return result
    }

    /// Reclaims an existing ACI-only account using the recovery password derived
    /// from its Account Entropy Pool. This path never consumes an invitation.
    public static func recoverNumberlessAccountRequest(
        accountId: Aci,
        recoveryPassword: RegistrationRecoveryPassword,
        newAuthPassword: String,
        totp: UInt32?,
        accountAttributes: AccountAttributes,
        apnRegistrationId: ApnRegistrationId?,
        aciPrekeyBundle: RegistrationPreKeyUploadBundle,
        logger: PrefixedLogger,
    ) -> TSRequest {
        owsAssertDebug((apnRegistrationId != nil) != accountAttributes.isManualMessageFetchEnabled)

        let jsonEncoder = JSONEncoder()
        let attributes = numberlessAccountAttributes(accountAttributes, jsonEncoder: jsonEncoder)
        var parameters: [String: Any] = [
            "accountAttributes": attributes,
            "skipDeviceTransfer": true,
            "recoveryPassword": recoveryPassword.canonicalStringRepresentation,
            "aciIdentityKey": aciPrekeyBundle.identityKeyPair.keyPair.publicKey.serialize().base64EncodedStringWithoutPadding(),
            "aciSignedPreKey": OWSRequestFactory.signedPreKeyRequestParameters(aciPrekeyBundle.signedPreKey),
            "aciPqLastResortPreKey": OWSRequestFactory.pqPreKeyRequestParameters(aciPrekeyBundle.lastResortPreKey),
            "requireAtomic": true,
        ]
        if let totp {
            parameters["totp"] = totp
        }
        if let apnRegistrationId {
            let data = try! jsonEncoder.encode(apnRegistrationId)
            parameters["apnToken"] = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        }

        var result = TSRequest(url: URL(string: "v1/registration")!, method: "POST", parameters: parameters, logger: logger)
        result.auth = .registration((username: accountId.serviceIdString, password: newAuthPassword))
        result.headers["X-Signal-Agent"] = "OWI"
        return result
    }

    /// Update the phone number on an account.
    ///
    /// - parameter verificationMethod: A way to verify phone number and account ownership.
    /// - parameter e164: The phone number to change to.
    /// - parameter reglockToken: If reglock is enabled, required to succeed. Derived from the
    ///   kbs master key.
    /// - parameter pniChangeNumberParameters: pni related params used to inform
    ///   linked device of the change number and rotated pni keys.
    public static func changeNumberRequest(
        verificationMethod: VerificationMethod,
        e164: E164,
        reglockToken: RegistrationLock?,
        pniChangeNumberParameters: PniDistribution.Parameters,
        logger: PrefixedLogger,
    ) -> TSRequest {
        let urlPathComponents = URLPathComponents(
            ["v2", "accounts", "number"],
        )
        var urlComponents = URLComponents()
        urlComponents.percentEncodedPath = urlPathComponents.percentEncoded
        let url = urlComponents.url!

        var parameters: [String: Any] = [
            "number": e164.stringValue,
        ]
        switch verificationMethod {
        case .sessionId(let sessionId):
            parameters["sessionId"] = sessionId
        case .recoveryPassword(let recoveryPassword):
            parameters["recoveryPassword"] = recoveryPassword.canonicalStringRepresentation
        case .invitationReceipt:
            owsFail("Invitation receipts cannot authorize a phone-number change")
        }
        if let reglockToken {
            parameters["reglock"] = reglockToken.canonicalStringRepresentation
        }

        parameters.merge(
            pniChangeNumberParameters.requestParameters(),
            uniquingKeysWith: { _, _ in
                owsFail("Unexpectedly encountered duplicate keys!", logger: logger)
            },
        )

        return TSRequest(url: url, method: "PUT", parameters: parameters, logger: logger)
    }

    // MARK: - Helpers

    private static func numberlessAccountAttributes(
        _ accountAttributes: AccountAttributes,
        jsonEncoder: JSONEncoder,
    ) -> [String: Any] {
        let attributesData = try! jsonEncoder.encode(accountAttributes)
        var attributes = try! JSONSerialization.jsonObject(with: attributesData) as! [String: Any]

        // A numberless account has no PNI. The server requires the PNI identity
        // key, registration ID, signed pre-key, and PQ pre-key to be either all
        // present or all absent.
        attributes.removeValue(forKey: "pniRegistrationId")

        // Before a profile-derived unidentified access key exists, the server
        // requires unrestricted unidentified access to be enabled.
        if attributes["unidentifiedAccessKey"] == nil {
            attributes["unrestrictedUnidentifiedAccess"] = true
        }

        return attributes
    }

    private static func redactSessionIdFromLogs(_ sessionId: String, in request: inout TSRequest) {
        request.applyRedactionStrategy(.redactURL(sensitiveValues: [sessionId]))
    }
}
