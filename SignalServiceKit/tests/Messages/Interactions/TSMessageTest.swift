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

    func testParticipantDeleteTracksKnownDeviceConfirmations() throws {
        let localIdentifiers: LocalIdentifiers = .forUnitTests
        let contactAci = Aci.randomForTesting()
        let requestId = UUID().data
        let targetTimestamp = Date.ows_millisecondTimestamp()

        try SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: localIdentifiers,
                tx: tx,
            )
            let linkedDeviceId = DeviceId(validating: 2)!
            var localRecipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(
                serviceId: localIdentifiers.aci,
                tx: tx,
            )
            DependenciesBridge.shared.recipientManager.modifyAndSave(
                &localRecipient,
                deviceIdsToAdd: [linkedDeviceId],
                deviceIdsToRemove: [],
                shouldUpdateStorageService: false,
                tx: tx,
            )
            _ = try SignalRecipient.insertRecord(aci: contactAci, deviceIds: [.primary], tx: tx)
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

            var summary = DependenciesBridge.shared.participantDeleteManager.confirmationSummary(
                interactionId: message.sqliteRowId!,
                tx: tx,
            )
            XCTAssertEqual(summary?.expectedDeviceCount, 3)
            XCTAssertEqual(summary?.confirmedDeviceCount, 1)

            let receiptBuilder = SSKProtoDataMessageParticipantDeleteReceipt.builder()
            receiptBuilder.setVersion(ParticipantDeleteConfiguration.protocolVersion)
            receiptBuilder.setRequestID(requestId)
            receiptBuilder.setResult(.targetPending)
            DependenciesBridge.shared.participantDeleteManager.processReceipt(
                receiptBuilder.buildInfallibly(),
                responder: contactAci,
                sourceDeviceId: .primary,
                tx: tx,
            )
            summary = DependenciesBridge.shared.participantDeleteManager.confirmationSummary(
                interactionId: message.sqliteRowId!,
                tx: tx,
            )
            XCTAssertEqual(summary?.confirmedDeviceCount, 1)
            XCTAssertEqual(summary?.rejectedDeviceCount, 0)
            XCTAssertEqual(summary?.pendingDeviceCount, 2)

            receiptBuilder.setResult(.applied)
            DependenciesBridge.shared.participantDeleteManager.processReceipt(
                receiptBuilder.buildInfallibly(),
                responder: contactAci,
                sourceDeviceId: .primary,
                tx: tx,
            )

            summary = DependenciesBridge.shared.participantDeleteManager.confirmationSummary(
                interactionId: message.sqliteRowId!,
                tx: tx,
            )
            XCTAssertEqual(summary?.confirmedDeviceCount, 2)
            XCTAssertFalse(summary?.isComplete == true)

            DependenciesBridge.shared.participantDeleteManager.processReceipt(
                receiptBuilder.buildInfallibly(),
                responder: localIdentifiers.aci,
                sourceDeviceId: linkedDeviceId,
                tx: tx,
            )
            summary = DependenciesBridge.shared.participantDeleteManager.confirmationSummary(
                interactionId: message.sqliteRowId!,
                tx: tx,
            )
            XCTAssertEqual(summary?.confirmedDeviceCount, 3)
            XCTAssertTrue(summary?.isComplete == true)
        }
    }

    func testParticipantDeleteScrubsStoredQuotedReplySnapshot() throws {
        let localIdentifiers: LocalIdentifiers = .forUnitTests
        let contactAci = Aci.randomForTesting()
        let targetTimestamp = Date.ows_millisecondTimestamp()

        try SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: localIdentifiers,
                tx: tx,
            )
            let thread = TSContactThread.getOrCreateThread(
                withContactAddress: SignalServiceAddress(contactAci),
                transaction: tx,
            )
            let targetBuilder = TSOutgoingMessageBuilder.outgoingMessageBuilder(
                thread: thread,
                messageBody: AttachmentContentValidatorMock.mockValidatedBody("original secret"),
            )
            targetBuilder.timestamp = targetTimestamp
            let target = targetBuilder.build(transaction: tx)
            target.anyInsert(transaction: tx)

            let quoteBuilder = TSOutgoingMessageBuilder.outgoingMessageBuilder(
                thread: thread,
                messageBody: AttachmentContentValidatorMock.mockValidatedBody("reply"),
            )
            quoteBuilder.timestamp = targetTimestamp + 1
            quoteBuilder.quotedMessage = TSQuotedMessage(
                timestamp: NSNumber(value: targetTimestamp),
                authorAddress: SignalServiceAddress(localIdentifiers.aci),
                body: "original secret",
                bodyRanges: nil,
                quotedAttachmentForSending: nil,
                isGiftBadge: false,
                isTargetMessageViewOnce: false,
                isPoll: false,
            )
            let reply = quoteBuilder.build(transaction: tx)
            reply.anyInsert(transaction: tx)

            try DependenciesBridge.shared.participantDeleteManager.processLocalInitiation(
                requestId: UUID().data,
                targetAuthor: localIdentifiers.aci,
                targetSentTimestamp: targetTimestamp,
                scope: .directChatBothAccounts,
                groupRevision: nil,
                thread: thread,
                localAci: localIdentifiers.aci,
                tx: tx,
            )

            let updatedReply = InteractionFinder.fetch(rowId: reply.sqliteRowId!, transaction: tx) as! TSMessage
            XCTAssertNotEqual(updatedReply.quotedMessage?.body, "original secret")
            XCTAssertNil(updatedReply.quotedMessage?.attachmentInfo())
        }
    }

    func testParticipantDeleteRejectsRequestIdReuseForDifferentTarget() throws {
        let localIdentifiers: LocalIdentifiers = .forUnitTests
        let contactAci = Aci.randomForTesting()
        let requestId = UUID().data
        let firstTimestamp = Date.ows_millisecondTimestamp()

        try SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: localIdentifiers,
                tx: tx,
            )
            let thread = TSContactThread.getOrCreateThread(
                withContactAddress: SignalServiceAddress(contactAci),
                transaction: tx,
            )
            let firstBuilder = TSOutgoingMessageBuilder.outgoingMessageBuilder(thread: thread)
            firstBuilder.timestamp = firstTimestamp
            let firstMessage = firstBuilder.build(transaction: tx)
            firstMessage.anyInsert(transaction: tx)

            let secondBuilder = TSOutgoingMessageBuilder.outgoingMessageBuilder(thread: thread)
            secondBuilder.timestamp = firstTimestamp + 1
            let secondMessage = secondBuilder.build(transaction: tx)
            secondMessage.anyInsert(transaction: tx)

            try DependenciesBridge.shared.participantDeleteManager.processLocalInitiation(
                requestId: requestId,
                targetAuthor: localIdentifiers.aci,
                targetSentTimestamp: firstTimestamp,
                scope: .directChatBothAccounts,
                groupRevision: nil,
                thread: thread,
                localAci: localIdentifiers.aci,
                tx: tx,
            )
            XCTAssertThrowsError(try DependenciesBridge.shared.participantDeleteManager.processLocalInitiation(
                requestId: requestId,
                targetAuthor: localIdentifiers.aci,
                targetSentTimestamp: firstTimestamp + 1,
                scope: .directChatBothAccounts,
                groupRevision: nil,
                thread: thread,
                localAci: localIdentifiers.aci,
                tx: tx,
            ))
            XCTAssertFalse(secondMessage.wasRemotelyDeleted)
        }
    }

    func testRestoredRemoteDeleteRebuildsAntiResurrectionTombstone() throws {
        let localIdentifiers: LocalIdentifiers = .forUnitTests
        let contactAci = Aci.randomForTesting()
        let targetTimestamp = Date.ows_millisecondTimestamp()

        try SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: localIdentifiers,
                tx: tx,
            )
            let thread = TSContactThread.getOrCreateThread(
                withContactAddress: SignalServiceAddress(contactAci),
                transaction: tx,
            )
            let builder = TSOutgoingMessageBuilder.outgoingMessageBuilder(thread: thread)
            builder.timestamp = targetTimestamp
            builder.wasRemotelyDeleted = true
            let message = builder.build(transaction: tx)
            message.anyInsert(transaction: tx)

            DependenciesBridge.shared.participantDeleteManager.recordRestoredTombstone(
                message: message,
                thread: thread,
                targetAuthor: localIdentifiers.aci,
                tx: tx,
            )

            XCTAssertTrue(DependenciesBridge.shared.participantDeleteManager.isTargetDeleted(
                author: localIdentifiers.aci,
                sentTimestamp: targetTimestamp,
                threadUniqueId: thread.uniqueId,
                tx: tx,
            ))

            message.anyRemove(transaction: tx)
            let duplicateBuilder = TSOutgoingMessageBuilder.outgoingMessageBuilder(
                thread: thread,
                messageBody: AttachmentContentValidatorMock.mockValidatedBody("restored duplicate"),
            )
            duplicateBuilder.timestamp = targetTimestamp
            let duplicate = duplicateBuilder.build(transaction: tx)
            duplicate.anyInsert(transaction: tx)
            DependenciesBridge.shared.participantDeleteManager.applyPendingDeleteIfNecessary(
                to: duplicate,
                thread: thread,
                tx: tx,
            )

            XCTAssertTrue(duplicate.wasRemotelyDeleted)
            XCTAssertNil(duplicate.body)
            XCTAssertNil(DependenciesBridge.shared.participantDeleteManager.participantDeleteAuthor(
                interactionId: duplicate.sqliteRowId!,
                tx: tx,
            ))
        }
    }

    func testParticipantDeleteWaitsForGroupRevisionBeforeApplying() throws {
        let localIdentifiers: LocalIdentifiers = .forUnitTests
        let requesterAci = Aci.randomForTesting()
        let targetTimestamp = Date.ows_millisecondTimestamp()

        try SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: localIdentifiers,
                tx: tx,
            )

            var membershipBuilder = GroupMembership.Builder()
            membershipBuilder.addFullMember(localIdentifiers.aci, role: .normal)
            membershipBuilder.addFullMember(requesterAci, role: .normal)
            var modelBuilder = TSGroupModelBuilder(secretParams: try GroupSecretParams.generate())
            modelBuilder.groupMembership = membershipBuilder.build()
            modelBuilder.groupV2Revision = 1
            let initialModel = try modelBuilder.buildAsV2()
            let thread = TSGroupThread(groupModel: initialModel)
            thread.anyInsert(transaction: tx)

            let targetBuilder = TSOutgoingMessageBuilder.outgoingMessageBuilder(
                thread: thread,
                messageBody: AttachmentContentValidatorMock.mockValidatedBody("sensitive body"),
            )
            targetBuilder.timestamp = targetTimestamp
            let target = targetBuilder.build(transaction: tx)
            target.anyInsert(transaction: tx)

            let deleteBuilder = SSKProtoDataMessageParticipantDelete.builder()
            deleteBuilder.setVersion(ParticipantDeleteConfiguration.protocolVersion)
            deleteBuilder.setTargetAuthorAciBinary(localIdentifiers.aci.serviceIdBinary)
            deleteBuilder.setTargetSentTimestamp(targetTimestamp)
            deleteBuilder.setRequestID(UUID().data)
            deleteBuilder.setScope(.groupAllCurrentMembers)
            deleteBuilder.setGroupRevision(2)

            let result = try DependenciesBridge.shared.participantDeleteManager.process(
                proto: deleteBuilder.buildInfallibly(),
                origin: .remoteEnvelope(requester: requesterAci, sourceDeviceId: .primary),
                thread: thread,
                trustedServerTimestamp: targetTimestamp + 1,
                tx: tx,
            )
            XCTAssertEqual(result, .targetPending)
            XCTAssertFalse(target.wasRemotelyDeleted)

            var updatedModelBuilder = initialModel.asBuilder
            updatedModelBuilder.groupV2Revision = 2
            thread.update(with: try updatedModelBuilder.buildAsV2(), transaction: tx)
            DependenciesBridge.shared.participantDeleteManager.reprocessPendingDeletes(in: thread, tx: tx)

            XCTAssertTrue(target.wasRemotelyDeleted)
            XCTAssertEqual(try PendingParticipantDeleteRecord.fetchCount(tx.database), 0)
        }
    }
}
