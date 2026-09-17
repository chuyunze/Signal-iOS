//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import SignalServiceKit

class TSMessageTest: SSKBaseTest {
    private var thread: TSThread!

    override func setUp() {
        super.setUp()

        self.thread = TSContactThread.getOrCreateThread(contactAddress: SignalServiceAddress(phoneNumber: "fake-thread-id"))
    }

    func testExpiresAtWithoutStartedTimer() {
        let builder = TSOutgoingMessageBuilder.outgoingMessageBuilder(
            thread: self.thread,
            messageBody: AttachmentContentValidatorMock.mockValidatedBody("foo"),
        )
        builder.timestamp = 1
        builder.expiresInSeconds = 100

        let message = SSKEnvironment.shared.databaseStorageRef.read { builder.build(transaction: $0) }
        XCTAssertEqual(0, message.expiresAt)
    }

    func testExpiresAtWithStartedTimer() {
        let now = Date.ows_millisecondTimestamp()
        let expirationSeconds: UInt32 = 10

        let builder = TSOutgoingMessageBuilder.outgoingMessageBuilder(
            thread: self.thread,
            messageBody: AttachmentContentValidatorMock.mockValidatedBody("foo"),
        )
        builder.timestamp = 1
        builder.expiresInSeconds = expirationSeconds
        builder.expireStartedAt = now

        let message = SSKEnvironment.shared.databaseStorageRef.read { builder.build(transaction: $0) }
        XCTAssertEqual(now + UInt64(expirationSeconds * 1000), message.expiresAt)
    }

    func canBeRemotelyDeletedByNonAdmin() {
        let now = Date.ows_millisecondTimestamp()

        do {
            let builder = TSOutgoingMessageBuilder.outgoingMessageBuilder(thread: self.thread)
            builder.timestamp = now - UInt64.minuteInMs
            let message = SSKEnvironment.shared.databaseStorageRef.read { builder.build(transaction: $0) }

            XCTAssert(message.canBeRemotelyDeletedByNonAdmin)
        }

        do {
            let builder: TSIncomingMessageBuilder = .withDefaultValues(thread: self.thread)
            builder.timestamp = now - UInt64.minuteInMs
            let message = builder.build()

            XCTAssertFalse(message.canBeRemotelyDeletedByNonAdmin)
        }

        do {
            let builder = TSOutgoingMessageBuilder.outgoingMessageBuilder(thread: self.thread)
            builder.timestamp = now - UInt64.minuteInMs
            let message = SSKEnvironment.shared.databaseStorageRef.read { builder.build(transaction: $0) }
            SSKEnvironment.shared.databaseStorageRef.write { transaction in
                message.anyInsert(transaction: transaction)
                message.updateWithRemotelyDeletedAndRemoveRenderableContent(with: transaction)
            }

            XCTAssertFalse(message.canBeRemotelyDeletedByNonAdmin)
        }

        do {
            let builder = TSOutgoingMessageBuilder.outgoingMessageBuilder(thread: self.thread)
            builder.timestamp = now - UInt64.minuteInMs
            builder.giftBadge = OWSGiftBadge(redemptionCredential: Data())
            let message = SSKEnvironment.shared.databaseStorageRef.read { builder.build(transaction: $0) }

            XCTAssertFalse(message.canBeRemotelyDeletedByNonAdmin)
        }

        do {
            let builder = TSOutgoingMessageBuilder.outgoingMessageBuilder(thread: self.thread)
            builder.timestamp = now + UInt64.minuteInMs
            let message = SSKEnvironment.shared.databaseStorageRef.read { builder.build(transaction: $0) }

            XCTAssertTrue(message.canBeRemotelyDeletedByNonAdmin)
        }

        do {
            let builder = TSOutgoingMessageBuilder.outgoingMessageBuilder(thread: self.thread)
            builder.timestamp = now + (25 * UInt64.hourInMs)
            let message = SSKEnvironment.shared.databaseStorageRef.read { builder.build(transaction: $0) }

            XCTAssertTrue(message.canBeRemotelyDeletedByNonAdmin)
        }

        do {
            let builder = TSOutgoingMessageBuilder.outgoingMessageBuilder(thread: self.thread)
            builder.timestamp = now - (25 * UInt64.hourInMs)
            let message = SSKEnvironment.shared.databaseStorageRef.read { builder.build(transaction: $0) }

            XCTAssertFalse(message.canBeRemotelyDeletedByNonAdmin)
        }
    }

    func testApplyAuthorizedRemoteDeleteDoesNotApplyPolicy() throws {
        let builder = TSOutgoingMessageBuilder.outgoingMessageBuilder(
            thread: thread,
            messageBody: AttachmentContentValidatorMock.mockValidatedBody("sensitive body"),
        )
        builder.timestamp = 1

        try SSKEnvironment.shared.databaseStorageRef.write { tx in
            let message = builder.build(transaction: tx)
            message.anyInsert(transaction: tx)

            let deletedMessage = try TSMessage.applyAuthorizedRemoteDelete(message, transaction: tx)

            XCTAssertTrue(deletedMessage.wasRemotelyDeleted)
            XCTAssertNil(deletedMessage.body)
        }
    }

    func testParticipantDeleteIsIdempotentAcrossRequestIds() throws {
        let localIdentifiers: LocalIdentifiers = .forUnitTests
        let contactAci = Aci.randomForTesting()
        let targetTimestamp = Date.ows_millisecondTimestamp() - 365 * UInt64.dayInMs
        let firstRequestId = UUID(uuidString: "14201C6D-3E38-4B96-9A8F-093EDAD7B670")!.data
        let secondRequestId = UUID(uuidString: "FF193DC5-1038-4774-9763-B687A89E2D9D")!.data

        try SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: localIdentifiers,
                tx: tx,
            )
            let thread = TSContactThread.getOrCreateThread(
                withContactAddress: SignalServiceAddress(contactAci),
                transaction: tx,
            )
            let builder = TSOutgoingMessageBuilder.outgoingMessageBuilder(
                thread: thread,
                messageBody: AttachmentContentValidatorMock.mockValidatedBody("sensitive body"),
            )
            builder.timestamp = targetTimestamp
            let message = builder.build(transaction: tx)
            message.anyInsert(transaction: tx)

            for requestId in [firstRequestId, firstRequestId, secondRequestId] {
                try DependenciesBridge.shared.participantDeleteManager.processLocalInitiation(
                    requestId: requestId,
                    targetAuthor: localIdentifiers.aci,
                    targetSentTimestamp: targetTimestamp,
                    scope: .directChatBothAccounts,
                    groupRevision: nil,
                    thread: thread,
                    localAci: localIdentifiers.aci,
                    tx: tx,
                )
            }

            XCTAssertTrue(message.wasRemotelyDeleted)
            XCTAssertNil(message.body)
            XCTAssertEqual(try ParticipantDeleteRequestRecord.fetchCount(tx.database), 2)
            XCTAssertEqual(try ParticipantDeleteTombstoneRecord.fetchCount(tx.database), 1)
        }
    }

    func testParticipantDeletePendingRequestConsumesLaterMessage() throws {
        let localIdentifiers: LocalIdentifiers = .forUnitTests
        let contactAci = Aci.randomForTesting()
        let targetTimestamp = Date.ows_millisecondTimestamp()
        let requestId = UUID(uuidString: "14201C6D-3E38-4B96-9A8F-093EDAD7B670")!.data

        try SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: localIdentifiers,
                tx: tx,
            )
            let thread = TSContactThread.getOrCreateThread(
                withContactAddress: SignalServiceAddress(contactAci),
                transaction: tx,
            )
            let deleteBuilder = SSKProtoDataMessageParticipantDelete.builder()
            deleteBuilder.setVersion(ParticipantDeleteConfiguration.protocolVersion)
            deleteBuilder.setTargetAuthorAciBinary(localIdentifiers.aci.serviceIdBinary)
            deleteBuilder.setTargetSentTimestamp(targetTimestamp)
            deleteBuilder.setRequestID(requestId)
            deleteBuilder.setScope(.directChatBothAccounts)

            let result = try DependenciesBridge.shared.participantDeleteManager.process(
                proto: deleteBuilder.buildInfallibly(),
                origin: .localSentTranscript(localAci: localIdentifiers.aci, sourceDeviceId: .primary),
                thread: thread,
                trustedServerTimestamp: targetTimestamp + 1,
                tx: tx,
            )
            XCTAssertEqual(result, .targetPending)
            XCTAssertEqual(try PendingParticipantDeleteRecord.fetchCount(tx.database), 1)

            let messageBuilder = TSOutgoingMessageBuilder.outgoingMessageBuilder(
                thread: thread,
                messageBody: AttachmentContentValidatorMock.mockValidatedBody("late body"),
            )
            messageBuilder.timestamp = targetTimestamp
            let message = messageBuilder.build(transaction: tx)
            message.anyInsert(transaction: tx)
            DependenciesBridge.shared.participantDeleteManager.applyPendingDeleteIfNecessary(
                to: message,
                thread: thread,
                tx: tx,
            )

            XCTAssertTrue(message.wasRemotelyDeleted)
            XCTAssertNil(message.body)
            XCTAssertEqual(try PendingParticipantDeleteRecord.fetchCount(tx.database), 0)
            XCTAssertEqual(try ParticipantDeleteTombstoneRecord.fetchCount(tx.database), 1)
        }
    }

    func testParticipantDeleteLocalInitiationRequiresExistingTarget() throws {
        let localIdentifiers: LocalIdentifiers = .forUnitTests
        let contactAci = Aci.randomForTesting()

        try SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: localIdentifiers,
                tx: tx,
            )
            let thread = TSContactThread.getOrCreateThread(
                withContactAddress: SignalServiceAddress(contactAci),
                transaction: tx,
            )

            XCTAssertThrowsError(try DependenciesBridge.shared.participantDeleteManager.processLocalInitiation(
                requestId: UUID().data,
                targetAuthor: localIdentifiers.aci,
                targetSentTimestamp: Date.ows_millisecondTimestamp(),
                scope: .directChatBothAccounts,
                groupRevision: nil,
                thread: thread,
                localAci: localIdentifiers.aci,
                tx: tx,
            ))
            XCTAssertEqual(try ParticipantDeleteRequestRecord.fetchCount(tx.database), 0)
            XCTAssertEqual(try PendingParticipantDeleteRecord.fetchCount(tx.database), 0)
            XCTAssertEqual(try ParticipantDeleteTombstoneRecord.fetchCount(tx.database), 0)
        }
    }
}
