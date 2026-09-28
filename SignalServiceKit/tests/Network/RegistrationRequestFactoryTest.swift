//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import XCTest
@testable import SignalServiceKit

public class RegistrationRequestFactoryTest: XCTestCase {

    private func numberlessPrekeyBundle() -> RegistrationPreKeyUploadBundle {
        let identityKeyPair = ECKeyPair.generateKeyPair()
        return RegistrationPreKeyUploadBundle(
            identity: .aci,
            identityKeyPair: identityKeyPair,
            signedPreKey: SignedPreKeyStoreImpl.generateSignedPreKey(
                keyId: PreKeyId.random(),
                signedBy: identityKeyPair.keyPair.privateKey,
            ),
            lastResortPreKey: KyberPreKeyStoreImpl.generatePreKeyRecord(
                keyId: 0,
                now: Date(),
                signedBy: identityKeyPair.keyPair.privateKey,
            ),
        )
    }

    private func numberlessAccountAttributes() -> AccountAttributes {
        let accountEntropyPool = AccountEntropyPool()
        return AccountAttributes(
            isManualMessageFetchEnabled: true,
            registrationId: 1,
            pniRegistrationId: 2,
            unidentifiedAccessKey: nil,
            unrestrictedUnidentifiedAccess: false,
            reglockToken: nil,
            registrationRecoveryPassword: accountEntropyPool.getMasterKey()
                .deriveRegistrationRecoveryPassword().canonicalStringRepresentation,
            encryptedDeviceName: nil,
            discoverableByPhoneNumber: nil,
            capabilities: .init(hasSVRBackups: false),
        )
    }

    func test_claimInvitationUsesUnauthenticatedEndpoint() {
        let credentialRequest = Data([0x01, 0x02, 0x03])
        let request = RegistrationRequestFactory.claimInvitationRequest(
            invitationCode: "single-use-code",
            receiptCredentialRequest: credentialRequest,
            logger: .empty(),
        )

        XCTAssertEqual(request.url.relativeString, "v1/invitations/claim")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.parameters["invitationCode"] as? String, "single-use-code")
        XCTAssertEqual(
            request.parameters["receiptCredentialRequest"] as? String,
            credentialRequest.base64EncodedString(),
        )
    }

    func test_recoverNumberlessAccountDoesNotSendInvitationOrPniKeys() {
        let accountId = Aci.randomForTesting()
        let accountEntropyPool = AccountEntropyPool()

        let request = RegistrationRequestFactory.recoverNumberlessAccountRequest(
            accountId: accountId,
            recoveryPassword: accountEntropyPool.getMasterKey().deriveRegistrationRecoveryPassword(),
            newAuthPassword: "new-device-password",
            totp: 123456,
            accountAttributes: numberlessAccountAttributes(),
            apnRegistrationId: nil,
            aciPrekeyBundle: numberlessPrekeyBundle(),
            logger: .empty(),
        )

        XCTAssertEqual(request.url.relativeString, "v1/registration")
        XCTAssertEqual(request.parameters["totp"] as? UInt32, 123456)
        XCTAssertNotNil(request.parameters["recoveryPassword"])
        XCTAssertNil(request.parameters["receiptCredentialPresentation"])
        XCTAssertNil(request.parameters["pniIdentityKey"])
        XCTAssertNil(request.parameters["pniSignedPreKey"])
        let requestAttributes = request.parameters["accountAttributes"] as? [String: Any]
        XCTAssertNil(requestAttributes?["pniRegistrationId"])
        XCTAssertEqual(requestAttributes?["unrestrictedUnidentifiedAccess"] as? Bool, true)
        switch request.auth {
        case .registration(let credentials):
            XCTAssertEqual(credentials?.username, accountId.serviceIdString)
            XCTAssertEqual(credentials?.password, "new-device-password")
        default:
            XCTFail("Expected registration authentication")
        }
    }

    func test_createNumberlessAccountOmitsAllPniFields() {
        let request = RegistrationRequestFactory.createNumberlessAccountRequest(
            receiptCredentialPresentation: Data([0x01, 0x02, 0x03]),
            authPassword: "new-device-password",
            accountAttributes: numberlessAccountAttributes(),
            apnRegistrationId: nil,
            aciPrekeyBundle: numberlessPrekeyBundle(),
            logger: .empty(),
        )

        let requestAttributes = request.parameters["accountAttributes"] as? [String: Any]
        XCTAssertNil(requestAttributes?["pniRegistrationId"])
        XCTAssertEqual(requestAttributes?["unrestrictedUnidentifiedAccess"] as? Bool, true)
        XCTAssertNil(request.parameters["pniIdentityKey"])
        XCTAssertNil(request.parameters["pniSignedPreKey"])
        XCTAssertNil(request.parameters["pniPqLastResortPreKey"])
    }

    func test_requestVerificationCodeLocale() {
        // (languageCode, countryCode, expected header)
        let expectedValues: [(String?, String?, String)] = [
            ("en", "US", "en-US, en;q=0.9"),
            ("en", nil, "en"),
            ("es", "US", "es-US, es;q=0.9, en;q=0.8"),
            ("es", nil, "es, en;q=0.9"),
            (nil, nil, "en"),
        ]

        for (languageCode, countryCode, expectedHeader) in expectedValues {
            let request = RegistrationRequestFactory.requestVerificationCodeRequest(
                sessionId: "123",
                languageCode: languageCode,
                countryCode: countryCode,
                transport: .sms,
                logger: .empty(),
            )
            XCTAssertEqual(request.url.relativeString, "v1/verification/session/123/code")
            XCTAssertEqual(request.parameters["transport"] as? String, "sms")
            XCTAssertEqual(request.headers["Accept-Language"], expectedHeader)
        }
    }
}
