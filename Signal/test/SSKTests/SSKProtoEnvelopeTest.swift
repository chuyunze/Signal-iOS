//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

import SwiftProtobuf
@testable import SignalServiceKit

class SSKProtoEnvelopeTest: XCTestCase {
    func testParse_EmptyData() {
        let data = Data()
        XCTAssertThrowsError(try SSKProtoEnvelope(serializedData: data))
    }

    func testParse_UnparseableData() {
        let data = "asdf".data(using: .utf8)!
        XCTAssertThrowsError(try SSKProtoEnvelope(serializedData: data)) { error in
            XCTAssert(error is SwiftProtobuf.BinaryDecodingError)
        }
    }

    func testParse_ValidData() {
        // `encodedData` was derived thus:
        //     let builder = SSKProtoEnvelopeBuilder()
        //     builder.setTimestamp(NSDate.ows_millisecondTimeStamp())
        //     builder.setSourceUuid(UUID().uuidString)
        //     builder.setSourceDevice(1)
        //     builder.setType(SSKProtoEnvelopeType.ciphertext)
        //     let encodedData = try! builder.build().serializedData().base64EncodedString()
        let encodedData = "CAEo/ovqh7gwOAFaJENFNTk5RjlCLThDNjQtNEM1OC1CNUQwLUU4MDE0NTAxQzhBMw=="
        let data = Data(base64Encoded: encodedData)!

        XCTAssertNoThrow(try SSKProtoEnvelope(serializedData: data))
    }

    func testParse_invalidData() {
        // `encodedData` was derived thus:
        // var proto = SignalServiceKit.SignalServiceProtos_Envelope()
        // proto.sourceUuid = UUID().uuidString
        // proto.sourceDevice = 1
        // // MISSING TIMESTAMP!
        //
        // let encodedData = try! proto.serializedData().base64EncodedString()
        let encodedData = "OAFaJEZEMkU1M0RELUJEQjAtNDg1Qi04OUFELTlBRTA3RTYxRjUzMw=="
        let data = Data(base64Encoded: encodedData)!

        XCTAssertThrowsError(try SSKProtoEnvelope(serializedData: data)) { error -> Void in
            switch error {
            case SSKProtoError.invalidProtobuf:
                break
            default:
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testParse_roundtrip() {
        let builder = SSKProtoEnvelope.builder(timestamp: 123)
        builder.setType(SSKProtoEnvelopeType.prekeyBundle)
        builder.setSourceServiceIDBinary(Aci.constantForTesting("CE599F9B-8C64-4C58-B5D0-E8014501C8A3").serviceIdBinary)
        builder.setSourceDevice(1)

        let phonyContent = "phony data".data(using: .utf8)!

        builder.setContent(phonyContent)

        var envelopeData: Data
        do {
            envelopeData = try builder.buildSerializedData()
        } catch {
            XCTFail("Couldn't serialize data.")
            return
        }

        var envelope: SSKProtoEnvelope
        do {
            envelope = try SSKProtoEnvelope(serializedData: envelopeData)
        } catch {
            XCTFail("Couldn't serialize data.")
            return
        }

        XCTAssertEqual(envelope.type, SSKProtoEnvelopeType.prekeyBundle)
        XCTAssertEqual(envelope.timestamp, 123)
        XCTAssertEqual(envelope.sourceServiceIDBinary, Aci.constantForTesting("CE599F9B-8C64-4C58-B5D0-E8014501C8A3").serviceIdBinary)
        XCTAssertEqual(envelope.sourceDevice, 1)
        XCTAssertTrue(envelope.hasContent)
        XCTAssertEqual(envelope.content, phonyContent)
    }

    func testParticipantDeleteRoundTrip() throws {
        let targetAuthor = Aci.constantForTesting("CE599F9B-8C64-4C58-B5D0-E8014501C8A3")
        let requestId = UUID(uuidString: "14201C6D-3E38-4B96-9A8F-093EDAD7B670")!.data
        let builder = SSKProtoDataMessageParticipantDelete.builder()
        builder.setVersion(ParticipantDeleteConfiguration.protocolVersion)
        builder.setTargetAuthorAciBinary(targetAuthor.serviceIdBinary)
        builder.setTargetSentTimestamp(1_725_555_123_456)
        builder.setRequestID(requestId)
        builder.setClientRequestedAt(1_725_555_999_999)
        builder.setScope(.groupAllCurrentMembers)
        builder.setGroupRevision(42)

        let decoded = try SSKProtoDataMessageParticipantDelete(serializedData: builder.buildSerializedData())

        XCTAssertEqual(decoded.version, ParticipantDeleteConfiguration.protocolVersion)
        XCTAssertEqual(decoded.targetAuthorAciBinary, targetAuthor.serviceIdBinary)
        XCTAssertEqual(decoded.targetSentTimestamp, 1_725_555_123_456)
        XCTAssertEqual(decoded.requestID, requestId)
        XCTAssertEqual(decoded.clientRequestedAt, 1_725_555_999_999)
        XCTAssertEqual(decoded.scope, .groupAllCurrentMembers)
        XCTAssertEqual(decoded.groupRevision, 42)
    }

    func testParticipantDeleteReceiptRoundTrip() throws {
        let requestId = UUID(uuidString: "14201C6D-3E38-4B96-9A8F-093EDAD7B670")!.data
        let builder = SSKProtoDataMessageParticipantDeleteReceipt.builder()
        builder.setVersion(ParticipantDeleteConfiguration.protocolVersion)
        builder.setRequestID(requestId)
        builder.setResult(.targetPending)

        let decoded = try SSKProtoDataMessageParticipantDeleteReceipt(serializedData: builder.buildSerializedData())

        XCTAssertEqual(decoded.version, ParticipantDeleteConfiguration.protocolVersion)
        XCTAssertEqual(decoded.requestID, requestId)
        XCTAssertEqual(decoded.result, .targetPending)
    }
}
