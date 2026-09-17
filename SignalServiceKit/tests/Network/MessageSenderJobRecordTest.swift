//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

class SSKMessageSenderJobRecordTest: SSKBaseTest {

    func test_savedVisibleMessage() {
        let message = OutgoingMessageFactory().create()
        self.read { transaction in
            let jobRecord = try! MessageSenderJobRecord(
                persistedMessage: .init(
                    rowId: 0,
                    message: message,
                ),
                isHighPriority: false,
                transaction: transaction,
            )

            switch jobRecord.messageType {
            case .persisted:
                break
            case .transient, .editMessage, .none:
                XCTFail("Incorrect message type")
            }
            XCTAssertNotNil(jobRecord.threadId)
        }
    }

    func test_invisibleMessage() {
        let message = OutgoingMessageFactory().buildDeliveryReceipt()
        self.read { transaction in
            let jobRecord = MessageSenderJobRecord(
                transientMessage: message,
                isHighPriority: false,
            )

            switch jobRecord.messageType {
            case .transient:
                break
            case .persisted, .editMessage, .none:
                XCTFail("Incorrect message type")
            }
            XCTAssertNotNil(jobRecord.threadId)
        }
    }

    func testParticipantDeleteMessageSurvivesSecureCodingRoundTrip() throws {
        let localIdentifiers: LocalIdentifiers = .forUnitTests
        let participantDeleteMessage: OutgoingParticipantDeleteMessage = try SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: localIdentifiers,
                tx: tx,
            )
            let thread = TSContactThread.getOrCreateThread(
                withContactAddress: SignalServiceAddress(Aci.randomForTesting()),
                transaction: tx,
            )
            let messageBuilder = TSOutgoingMessageBuilder.outgoingMessageBuilder(thread: thread)
            messageBuilder.timestamp = Date.ows_millisecondTimestamp()
            let targetMessage = messageBuilder.build(transaction: tx)
            return try XCTUnwrap(OutgoingParticipantDeleteMessage(
                thread: thread,
                message: targetMessage,
                localIdentifiers: localIdentifiers,
                tx: tx,
            ))
        }

        try assertParticipantDeleteMessageSurvivesSecureCodingRoundTrip(
            participantDeleteMessage,
            expectsLegacyDelete: true,
        )
    }

    func testParticipantDeleteForIncomingMessageSurvivesSecureCodingRoundTrip() throws {
        let localIdentifiers: LocalIdentifiers = .forUnitTests
        let participantDeleteMessage: OutgoingParticipantDeleteMessage = try SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: localIdentifiers,
                tx: tx,
            )
            let contactAci = Aci.randomForTesting()
            let thread = TSContactThread.getOrCreateThread(
                withContactAddress: SignalServiceAddress(contactAci),
                transaction: tx,
            )
            let messageBuilder: TSIncomingMessageBuilder = .withDefaultValues(
                thread: thread,
                authorAci: contactAci,
            )
            messageBuilder.timestamp = Date.ows_millisecondTimestamp()
            let targetMessage = messageBuilder.build()
            targetMessage.anyInsert(transaction: tx)
            return try XCTUnwrap(OutgoingParticipantDeleteMessage(
                thread: thread,
                message: targetMessage,
                localIdentifiers: localIdentifiers,
                tx: tx,
            ))
        }

        try assertParticipantDeleteMessageSurvivesSecureCodingRoundTrip(
            participantDeleteMessage,
            expectsLegacyDelete: false,
        )
    }

    private func assertParticipantDeleteMessageSurvivesSecureCodingRoundTrip(
        _ participantDeleteMessage: OutgoingParticipantDeleteMessage,
        expectsLegacyDelete: Bool,
    ) throws {
        let archivedData = try NSKeyedArchiver.archivedData(
            withRootObject: participantDeleteMessage,
            requiringSecureCoding: true,
        )
        let restoredMessage = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(
            ofClass: TransientOutgoingMessage.self,
            from: archivedData,
        ) as? OutgoingParticipantDeleteMessage)

        XCTAssertEqual(restoredMessage.requestId, participantDeleteMessage.requestId)
        XCTAssertEqual(restoredMessage.targetAuthor, participantDeleteMessage.targetAuthor)
        XCTAssertEqual(restoredMessage.targetSentTimestamp, participantDeleteMessage.targetSentTimestamp)

        let dataMessage = try SSKEnvironment.shared.databaseStorageRef.read { tx in
            let thread = try XCTUnwrap(restoredMessage.thread(tx: tx))
            let builder = try XCTUnwrap(restoredMessage.dataMessageBuilder(
                with: thread,
                transaction: tx,
            ))
            return try builder.build()
        }
        XCTAssertNotNil(dataMessage.participantDelete)
        XCTAssertEqual(dataMessage.delete != nil, expectsLegacyDelete)
    }
}
