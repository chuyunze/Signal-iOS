//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
public import LibSignalClient

public enum RemoteDeleteAuthor: Equatable {
    case admin(aci: Aci, displayName: String)
    case participant(aci: Aci, displayName: String)
    case regular(displayName: String)
    case localUser
}

public class AdminDeleteManager {
    public typealias RecipientAddressStates = [SignalServiceAddress: TSOutgoingMessageRecipientState]

    public struct DeleteType: OptionSet {
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public let rawValue: Int

        public static let admin = DeleteType(rawValue: 1 << 1)
        public static let regular = DeleteType(rawValue: 1 << 2)
    }

    private let recipientDatabaseTable: RecipientDatabaseTable
    private let tsAccountManager: TSAccountManager
    private let kvStore: NewKeyValueStore
    private let storageServiceManager: StorageServiceManager

    private static let kvStoreAdminDeleteEducationReadKey = "adminDeleteEducationRead"

    private let logger = PrefixedLogger(prefix: "AdminDelete")

    init(
        recipientDatabaseTable: RecipientDatabaseTable,
        tsAccountManager: TSAccountManager,
        storageServiceManager: StorageServiceManager,
    ) {
        self.recipientDatabaseTable = recipientDatabaseTable
        self.tsAccountManager = tsAccountManager
        self.kvStore = NewKeyValueStore(collection: "AdminDeleteManager")
        self.storageServiceManager = storageServiceManager
    }

    private func insertAdminDelete(
        groupThread: TSGroupThread,
        interactionId: Int64,
        deleteAuthor: Aci,
        tx: DBWriteTransaction,
    ) throws(TSMessage.RemoteDeleteError) {
        guard
            let deleteAuthorId = recipientDatabaseTable.fetchRecipient(
                serviceId: deleteAuthor,
                transaction: tx,
            )?.id
        else {
            logger.error("Failed to process admin delete for missing signal recipient")
            throw .invalidDelete
        }

        failIfThrows {
            var adminDeleteRecord = AdminDeleteRecord(
                interactionId: interactionId,
                deleteAuthorId: deleteAuthorId,
            )
            try adminDeleteRecord.insert(tx.database)
        }
    }

    public func tryToAdminDeleteMessage(
        originalMessageAuthorAci: Aci,
        deleteAuthorAci: Aci,
        sentAtTimestamp: UInt64,
        groupThread: TSGroupThread,
        threadUniqueId: String?,
        serverTimestamp: UInt64,
        transaction: DBWriteTransaction,
    ) throws(TSMessage.RemoteDeleteError) {
        guard SDS.fitsInInt64(sentAtTimestamp) else {
            owsFailDebug("Unable to delete a message with invalid sentAtTimestamp: \(sentAtTimestamp)")
            throw .invalidDelete
        }

        guard
            let groupModel = groupThread.groupModel as? TSGroupModelV2,
            groupModel.membership.isFullMemberAndAdministrator(deleteAuthorAci)
        else {
            logger.error("Failed to process admin delete for non-admin")
            throw .invalidDelete
        }

        if
            let threadUniqueId, let messageToDelete = InteractionFinder.findMessage(
                withTimestamp: sentAtTimestamp,
                threadId: threadUniqueId,
                author: SignalServiceAddress(originalMessageAuthorAci),
                transaction: transaction,
            )
        {
            let allowDeleteTimeframe = RemoteConfig.current.adminDeleteMaxAgeInSeconds + .day
            let latestMessage = try TSMessage.remotelyDeleteMessage(
                messageToDelete,
                deleteAuthorAci: deleteAuthorAci,
                allowedDeleteTimeframeSeconds: allowDeleteTimeframe,
                serverTimestamp: serverTimestamp,
                transaction: transaction,
            )

            return try insertAdminDelete(
                groupThread: groupThread,
                interactionId: latestMessage.sqliteRowId!,
                deleteAuthor: deleteAuthorAci,
                tx: transaction,
            )
        } else {
            throw .deletedMessageMissing
        }
    }

    public func adminDeleteAuthor(interactionId: Int64, tx: DBReadTransaction) -> Aci? {
        return failIfThrows {
            guard
                let adminDeleteRecord = try AdminDeleteRecord
                    .filter(AdminDeleteRecord.Columns.interactionId == interactionId)
                    .fetchOne(tx.database)
            else {
                return nil
            }

            let signalRecipient = recipientDatabaseTable.fetchRecipient(
                rowId: adminDeleteRecord.deleteAuthorId,
                tx: tx,
            )
            return signalRecipient?.aci
        }
    }

    public func canAdminDeleteMessage(
        message: TSMessage,
        thread: TSThread,
        tx: DBReadTransaction,
    ) -> Bool {
        guard let groupThread = thread as? TSGroupThread else {
            return false
        }

        guard let localAci = tsAccountManager.localIdentifiers(tx: tx)?.aci else {
            return false
        }

        guard groupThread.groupModel.groupMembership.isFullMemberAndAdministrator(localAci) else {
            return false
        }

        guard message.canBeRemotelyDeletedByAdmin else {
            return false
        }

        return true
    }

    public func insertAdminDeleteForSignalRecipient(
        _ recipientId: SignalRecipient.RowId,
        interactionId: Int64,
        tx: DBWriteTransaction,
    ) {
        failIfThrows {
            var adminDeleteRecord = AdminDeleteRecord(
                interactionId: interactionId,
                deleteAuthorId: recipientId,
            )
            try adminDeleteRecord.insert(tx.database)
        }
    }

    public func adminDeleteEducationReadStatus(tx: DBReadTransaction) -> Bool {
        return kvStore.fetchValue(Bool.self, forKey: Self.kvStoreAdminDeleteEducationReadKey, tx: tx) ?? false
    }

    public func setAdminDeleteEducationRead(tx: DBWriteTransaction, updateStorageService: Bool) {
        guard !adminDeleteEducationReadStatus(tx: tx) else {
            return
        }
        kvStore.writeValue(true, forKey: Self.kvStoreAdminDeleteEducationReadKey, tx: tx)
        if updateStorageService {
            storageServiceManager.recordPendingLocalAccountUpdates()
        }
    }

    // MARK: - Recipient states

    public static func updateRecipientStatesAdminDelete(recipientAddressStates: RecipientAddressStates?, interactionId: Int64, tx: DBWriteTransaction) {

        failIfThrows {
            var adminDeleteRecord = try AdminDeleteRecord
                .filter(AdminDeleteRecord.Columns.interactionId == interactionId)
                .fetchOne(tx.database)
            adminDeleteRecord?.recipientAddressStates = recipientAddressStates
            try adminDeleteRecord?.update(tx.database)
        }
    }

    public static func isFailedAdminDelete(recipientAddressStates: RecipientAddressStates?) -> Bool {
        guard let recipientAddressStates else {
            return false
        }
        return recipientAddressStates.values.contains {
            $0.status == .failed
        }
    }

    public static func wasSentToAnyRecipient(recipientAddressStates: RecipientAddressStates?) -> Bool {
        guard let recipientAddressStates else {
            return false
        }

        return recipientAddressStates.values.contains {
            switch $0.status {
            case .sent, .delivered, .read, .viewed:
                return true
            case .skipped, .sending, .pending, .failed:
                return false
            }
        }
    }

    public static func failedRecipientsWithErrorCode(_ errorCode: Int, recipientAddressStates: RecipientAddressStates?) -> [SignalServiceAddress] {
        guard let recipientAddressStates else {
            return []
        }

        return recipientAddressStates.filter { _, state in
            state.status == .failed && state.errorCode == errorCode
        }.map { $0.key }
    }

    public static func recipientAddressStates(message: TSMessage, tx: DBReadTransaction) -> RecipientAddressStates? {
        failIfThrows {
            try AdminDeleteRecord
                .filter(AdminDeleteRecord.Columns.interactionId == message.sqliteRowId!)
                .fetchOne(tx.database)?.recipientAddressStates
        }
    }
}

// MARK: - Participant Delete

public enum ParticipantDeleteConfiguration {
    public static let protocolVersion: UInt32 = 1
    public static let allowsUnlimitedMessageAge = true
    public static let featureEnabled = true

    static let pendingLifetime: UInt64 = 45 * UInt64.dayInMs
    static let receiptLifetime: UInt64 = 45 * UInt64.dayInMs
    static let maximumPendingPerRequester = 128
    static let maximumPendingPerConversation = 512
    static let maximumPendingGlobally = 10_000
    static let maximumOrphanReceipts = 2_048
}

public enum ParticipantDeleteOrigin {
    case remoteEnvelope(requester: Aci, sourceDeviceId: DeviceId)
    case localSentTranscript(localAci: Aci, sourceDeviceId: DeviceId)
    case localInitiation(localAci: Aci)

    var requester: Aci {
        switch self {
        case .remoteEnvelope(let requester, _): requester
        case .localSentTranscript(let localAci, _), .localInitiation(let localAci): localAci
        }
    }

    var sourceDeviceId: DeviceId? {
        switch self {
        case .remoteEnvelope(_, let sourceDeviceId), .localSentTranscript(_, let sourceDeviceId): sourceDeviceId
        case .localInitiation: nil
        }
    }

    var shouldSendReceipt: Bool {
        if case .remoteEnvelope = self { return true }
        return false
    }
}

public enum ParticipantDeleteError: Error {
    case unsupportedVersion
    case invalidRequestId
    case invalidTarget
    case invalidThread
    case scopeMismatch
    case requesterIsNotCurrentMember
    case futureTarget
    case pendingLimitExceeded
}

public final class ParticipantDeleteManager {
    private struct Request {
        let version: UInt32
        let targetAuthor: Aci
        let targetSentTimestamp: UInt64
        let requestId: Data
        let scope: SSKProtoDataMessageParticipantDeleteScope
        let groupRevision: UInt32?
    }

    private struct ValidatedRequest {
        let request: Request
        let requester: Aci
        let requesterDeviceId: DeviceId?
        let stableConversationId: Data
        let localThreadUniqueId: String
    }

    private let recipientDatabaseTable: RecipientDatabaseTable
    private let tsAccountManager: TSAccountManager
    private let logger = PrefixedLogger(prefix: "ParticipantDelete")

    init(recipientDatabaseTable: RecipientDatabaseTable, tsAccountManager: TSAccountManager) {
        self.recipientDatabaseTable = recipientDatabaseTable
        self.tsAccountManager = tsAccountManager
    }

    public func canParticipantDelete(message: TSMessage, thread: TSThread, tx: DBReadTransaction) -> Bool {
        guard ParticipantDeleteConfiguration.featureEnabled else { return false }
        guard !thread.isNoteToSelf, !thread.isTerminatedGroup else { return false }
        guard message.uniqueThreadId == thread.uniqueId else { return false }
        guard message.isIncoming || message.isOutgoing else { return false }
        guard message.timestamp > 0, SDS.fitsInInt64(message.timestamp) else { return false }
        guard Self.isSupportedTarget(message) else { return false }
        guard !message.wasRemotelyDeleted else { return false }
        guard let localAci = tsAccountManager.localIdentifiers(tx: tx)?.aci else { return false }
        guard Self.authorAci(for: message, localAci: localAci) != nil else { return false }

        if let contactThread = thread as? TSContactThread {
            return contactThread.contactAddress.aci != nil
        }
        if
            let groupThread = thread as? TSGroupThread,
            let groupModel = groupThread.groupModel as? TSGroupModelV2
        {
            return groupModel.membership.isFullMember(localAci)
        }
        return false
    }

    public func process(
        proto: SSKProtoDataMessageParticipantDelete,
        origin: ParticipantDeleteOrigin,
        thread: TSThread,
        trustedServerTimestamp: UInt64?,
        tx: DBWriteTransaction,
    ) throws -> SSKProtoDataMessageParticipantDeleteReceiptResult {
        let request = try Self.parse(proto: proto)
        return try process(
            request: request,
            origin: origin,
            thread: thread,
            trustedServerTimestamp: trustedServerTimestamp,
            tx: tx,
        )
    }

    public func processLocalInitiation(
        requestId: Data,
        targetAuthor: Aci,
        targetSentTimestamp: UInt64,
        scope: SSKProtoDataMessageParticipantDeleteScope,
        groupRevision: UInt32?,
        thread: TSThread,
        localAci: Aci,
        tx: DBWriteTransaction,
    ) throws {
        guard requestId.count == 16 else { throw ParticipantDeleteError.invalidRequestId }
        guard
            targetSentTimestamp > 0,
            SDS.fitsInInt64(targetSentTimestamp),
            scope != .unknown,
            InteractionFinder.findMessage(
                withTimestamp: targetSentTimestamp,
                threadId: thread.uniqueId,
                author: SignalServiceAddress(targetAuthor),
                transaction: tx,
            ) != nil
        else { throw ParticipantDeleteError.invalidTarget }

        let request = Request(
            version: ParticipantDeleteConfiguration.protocolVersion,
            targetAuthor: targetAuthor,
            targetSentTimestamp: targetSentTimestamp,
            requestId: requestId,
            scope: scope,
            groupRevision: groupRevision,
        )
        _ = try process(
            request: request,
            origin: .localInitiation(localAci: localAci),
            thread: thread,
            trustedServerTimestamp: nil,
            tx: tx,
        )
    }

    public func processReceipt(
        _ proto: SSKProtoDataMessageParticipantDeleteReceipt,
        responder: Aci,
        sourceDeviceId: DeviceId,
        tx: DBWriteTransaction,
    ) {
        guard
            proto.version == ParticipantDeleteConfiguration.protocolVersion,
            let requestId = proto.requestID,
            requestId.count == 16,
            let result = proto.result,
            result != .unknown
        else {
            logger.warn("Ignoring invalid participant-delete receipt")
            return
        }

        failIfThrows {
            let now = Date.ows_millisecondTimestamp()
            try ParticipantDeleteDeviceReceiptRecord
                .filter(Column("receivedAt") <= Int64(now - ParticipantDeleteConfiguration.receiptLifetime))
                .deleteAll(tx.database)

            let requestRecord = try ParticipantDeleteRequestRecord.fetchOne(tx.database, key: requestId)
            if
                let requestRecord,
                !isValidReceiptResponder(responder, requestRecord: requestRecord, tx: tx)
            {
                logger.warn("Ignoring participant-delete receipt from outside the target conversation")
                return
            }
            if
                requestRecord == nil,
                try orphanReceiptCount(tx: tx) >= ParticipantDeleteConfiguration.maximumOrphanReceipts
            {
                logger.warn("Ignoring orphan participant-delete receipt above capacity limit")
                return
            }

            try ParticipantDeleteDeviceReceiptRecord(
                requestId: requestId,
                responderAci: responder.serviceIdBinary,
                responderDeviceId: Int64(sourceDeviceId.rawValue),
                result: Int(result.rawValue),
                receivedAt: Int64(now),
            ).insert(tx.database)
        }
    }

    private func orphanReceiptCount(tx: DBReadTransaction) throws -> Int {
        try Int.fetchOne(
            tx.database,
            sql: """
                SELECT COUNT(*)
                FROM ParticipantDeleteDeviceReceipt AS receipt
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM ParticipantDeleteRequest AS request
                    WHERE request.requestId = receipt.requestId
                )
                """,
        ) ?? 0
    }

    private func isValidReceiptResponder(
        _ responder: Aci,
        requestRecord: ParticipantDeleteRequestRecord,
        tx: DBReadTransaction,
    ) -> Bool {
        guard let thread = TSThread.fetchViaCache(uniqueId: requestRecord.localThreadUniqueId, transaction: tx) else {
            return false
        }
        if let contactThread = thread as? TSContactThread {
            return contactThread.contactAddress.aci == responder
        }
        if
            let groupThread = thread as? TSGroupThread,
            let groupModel = groupThread.groupModel as? TSGroupModelV2
        {
            return groupModel.membership.isFullMember(responder)
        }
        return false
    }

    public func processFailure(
        proto: SSKProtoDataMessageParticipantDelete,
        error: Error,
        requester: Aci,
        tx: DBWriteTransaction,
    ) {
        guard let requestId = proto.requestID, requestId.count == 16 else { return }

        let result: SSKProtoDataMessageParticipantDeleteReceiptResult = {
            guard let participantDeleteError = error as? ParticipantDeleteError else {
                return .rejectedInvalidTarget
            }
            switch participantDeleteError {
            case .requesterIsNotCurrentMember:
                return .rejectedNotCurrentMember
            case .unsupportedVersion:
                return .rejectedNotSupported
            default:
                return .rejectedInvalidTarget
            }
        }()
        queueReceipt(requestId: requestId, result: result, recipient: requester, tx: tx)
    }

    /// Consumes a validated pending tombstone before attachment downloads and
    /// user notification for a newly inserted message.
    public func applyPendingDeleteIfNecessary(
        to message: TSMessage,
        thread: TSThread,
        tx: DBWriteTransaction,
    ) {
        guard
            let localAci = tsAccountManager.localIdentifiers(tx: tx)?.aci,
            let authorAci = Self.authorAci(for: message, localAci: localAci),
            let stableConversationId = try? stableConversationId(for: thread, localAci: localAci),
            message.timestamp > 0,
            SDS.fitsInInt64(message.timestamp)
        else { return }

        let tombstone: ParticipantDeleteTombstoneRecord? = failIfThrows {
            try ParticipantDeleteTombstoneRecord
                .filter(Column("stableConversationId") == stableConversationId)
                .filter(Column("targetAuthorAci") == authorAci.serviceIdBinary)
                .filter(Column("targetSentTimestamp") == Int64(message.timestamp))
                .fetchOne(tx.database)
        }
        if let tombstone {
            guard Self.isSupportedTarget(message) else {
                logger.warn("Ignoring unsupported message that matches a participant-delete tombstone")
                return
            }
            do {
                try tx.database.inSavepoint {
                    let latestMessage: TSMessage
                    if message.wasRemotelyDeleted {
                        latestMessage = message
                    } else {
                        latestMessage = try TSMessage.applyAuthorizedRemoteDelete(message, transaction: tx)
                    }
                    try tx.database.execute(
                        sql: """
                            UPDATE ParticipantDeleteTombstone
                            SET interactionId = ?, localThreadUniqueId = ?
                            WHERE stableConversationId = ? AND targetAuthorAci = ? AND targetSentTimestamp = ?
                            """,
                        arguments: [
                            latestMessage.sqliteRowId,
                            thread.uniqueId,
                            stableConversationId,
                            authorAci.serviceIdBinary,
                            Int64(message.timestamp),
                        ],
                    )
                    try insertAuthorMetadata(
                        interactionId: latestMessage.sqliteRowId,
                        requester: try Aci.parseFrom(serviceIdBinary: tombstone.requesterAci),
                        tx: tx,
                    )
                    return .commit
                }
            } catch {
                logger.error("Failed to reapply participant-delete tombstone")
            }
            return
        }

        let pending: PendingParticipantDeleteRecord? = failIfThrows {
            try PendingParticipantDeleteRecord
                .filter(Column("stableConversationId") == stableConversationId)
                .filter(Column("targetAuthorAci") == authorAci.serviceIdBinary)
                .filter(Column("targetSentTimestamp") == Int64(message.timestamp))
                .fetchOne(tx.database)
        }
        guard let pending else { return }
        guard Self.isSupportedTarget(message) else {
            rejectPendingDelete(pending, localAci: localAci, tx: tx)
            return
        }

        do {
            try tx.database.inSavepoint {
                let latestMessage: TSMessage
                if message.wasRemotelyDeleted {
                    latestMessage = message
                } else {
                    latestMessage = try TSMessage.applyAuthorizedRemoteDelete(message, transaction: tx)
                }
                try insertTombstone(
                    stableConversationId: pending.stableConversationId,
                    threadUniqueId: pending.localThreadUniqueId,
                    targetAuthor: authorAci,
                    targetSentTimestamp: message.timestamp,
                    interactionId: latestMessage.sqliteRowId,
                    firstRequestId: pending.firstRequestId,
                    requester: try Aci.parseFrom(serviceIdBinary: pending.requesterAci),
                    tx: tx,
                )
                try PendingParticipantDeleteRecord
                    .filter(Column("stableConversationId") == pending.stableConversationId)
                    .filter(Column("targetAuthorAci") == pending.targetAuthorAci)
                    .filter(Column("targetSentTimestamp") == pending.targetSentTimestamp)
                    .deleteAll(tx.database)

                let requestRecords = try ParticipantDeleteRequestRecord
                    .filter(Column("stableConversationId") == pending.stableConversationId)
                    .filter(Column("targetAuthorAci") == pending.targetAuthorAci)
                    .filter(Column("targetSentTimestamp") == pending.targetSentTimestamp)
                    .fetchAll(tx.database)
                for requestRecord in requestRecords {
                    try tx.database.execute(
                        sql: "UPDATE ParticipantDeleteRequest SET processingResult = ? WHERE requestId = ?",
                        arguments: [SSKProtoDataMessageParticipantDeleteReceiptResult.applied.rawValue, requestRecord.requestId],
                    )
                    if
                        requestRecord.requesterAci != localAci.serviceIdBinary,
                        let requester = try? Aci.parseFrom(serviceIdBinary: requestRecord.requesterAci)
                    {
                        queueReceipt(requestId: requestRecord.requestId, result: .applied, recipient: requester, tx: tx)
                    }
                }
                return .commit
            }
        } catch {
            logger.error("Failed to consume pending participant delete")
        }
    }

    public func participantDeleteAuthor(interactionId: Int64, tx: DBReadTransaction) -> Aci? {
        return failIfThrows {
            guard
                let record = try ParticipantDeleteAuthorRecord.fetchOne(tx.database, key: interactionId),
                let recipient = recipientDatabaseTable.fetchRecipient(rowId: record.deleteAuthorId, tx: tx)
            else { return nil }
            return recipient.aci
        }
    }

    private func process(
        request: Request,
        origin: ParticipantDeleteOrigin,
        thread: TSThread,
        trustedServerTimestamp: UInt64?,
        tx: DBWriteTransaction,
    ) throws -> SSKProtoDataMessageParticipantDeleteReceiptResult {
        let validated = try validate(
            request: request,
            origin: origin,
            thread: thread,
            trustedServerTimestamp: trustedServerTimestamp,
            tx: tx,
        )

        if let previous = try ParticipantDeleteRequestRecord.fetchOne(tx.database, key: request.requestId) {
            let result = SSKProtoDataMessageParticipantDeleteReceiptResult(rawValue: Int32(previous.processingResult)) ?? .alreadyApplied
            if origin.shouldSendReceipt {
                queueReceipt(requestId: request.requestId, result: result, recipient: origin.requester, tx: tx)
            }
            return result
        }

        if try tombstoneExists(for: validated, tx: tx) {
            try insertRequest(validated, result: .alreadyApplied, tx: tx)
            if origin.shouldSendReceipt {
                queueReceipt(requestId: request.requestId, result: .alreadyApplied, recipient: origin.requester, tx: tx)
            }
            return .alreadyApplied
        }

        guard let target = InteractionFinder.findMessage(
            withTimestamp: request.targetSentTimestamp,
            threadId: validated.localThreadUniqueId,
            author: SignalServiceAddress(request.targetAuthor),
            transaction: tx,
        ) else {
            try tx.database.inSavepoint {
                try insertPending(validated, trustedServerTimestamp: trustedServerTimestamp, tx: tx)
                try insertRequest(validated, result: .targetPending, tx: tx)
                return .commit
            }
            if origin.shouldSendReceipt {
                queueReceipt(requestId: request.requestId, result: .targetPending, recipient: origin.requester, tx: tx)
            }
            return .targetPending
        }

        guard target.uniqueThreadId == validated.localThreadUniqueId, target.timestamp == request.targetSentTimestamp else {
            throw ParticipantDeleteError.invalidTarget
        }
        guard Self.isSupportedTarget(target) else {
            throw ParticipantDeleteError.invalidTarget
        }

        var result: SSKProtoDataMessageParticipantDeleteReceiptResult = .applied
        try tx.database.inSavepoint {
            if target.wasRemotelyDeleted {
                result = .alreadyApplied
                try insertTombstone(
                    stableConversationId: validated.stableConversationId,
                    threadUniqueId: validated.localThreadUniqueId,
                    targetAuthor: request.targetAuthor,
                    targetSentTimestamp: request.targetSentTimestamp,
                    interactionId: target.sqliteRowId,
                    firstRequestId: request.requestId,
                    requester: validated.requester,
                    tx: tx,
                )
            } else {
                let latestMessage = try TSMessage.applyAuthorizedRemoteDelete(target, transaction: tx)
                try insertTombstone(
                    stableConversationId: validated.stableConversationId,
                    threadUniqueId: validated.localThreadUniqueId,
                    targetAuthor: request.targetAuthor,
                    targetSentTimestamp: request.targetSentTimestamp,
                    interactionId: latestMessage.sqliteRowId,
                    firstRequestId: request.requestId,
                    requester: validated.requester,
                    tx: tx,
                )
            }
            try insertRequest(validated, result: result, tx: tx)
            return .commit
        }
        if origin.shouldSendReceipt {
            queueReceipt(requestId: request.requestId, result: result, recipient: origin.requester, tx: tx)
        }
        return result
    }

    private static func parse(proto: SSKProtoDataMessageParticipantDelete) throws -> Request {
        guard proto.version == ParticipantDeleteConfiguration.protocolVersion else {
            throw ParticipantDeleteError.unsupportedVersion
        }
        guard let requestId = proto.requestID, requestId.count == 16 else {
            throw ParticipantDeleteError.invalidRequestId
        }
        guard
            let targetAuthorBinary = proto.targetAuthorAciBinary,
            let targetAuthor = try? Aci.parseFrom(serviceIdBinary: targetAuthorBinary),
            proto.hasTargetSentTimestamp,
            proto.targetSentTimestamp > 0,
            SDS.fitsInInt64(proto.targetSentTimestamp),
            let scope = proto.scope,
            scope != .unknown
        else {
            throw ParticipantDeleteError.invalidTarget
        }
        return Request(
            version: proto.version,
            targetAuthor: targetAuthor,
            targetSentTimestamp: proto.targetSentTimestamp,
            requestId: requestId,
            scope: scope,
            groupRevision: proto.hasGroupRevision ? proto.groupRevision : nil,
        )
    }

    private func validate(
        request: Request,
        origin: ParticipantDeleteOrigin,
        thread: TSThread,
        trustedServerTimestamp: UInt64?,
        tx: DBReadTransaction,
    ) throws -> ValidatedRequest {
        guard let localAci = tsAccountManager.localIdentifiers(tx: tx)?.aci else {
            throw ParticipantDeleteError.invalidTarget
        }
        guard !thread.isNoteToSelf, !thread.isTerminatedGroup else {
            throw ParticipantDeleteError.invalidThread
        }
        switch origin {
        case .remoteEnvelope:
            break
        case .localSentTranscript(let authenticatedLocalAci, _), .localInitiation(let authenticatedLocalAci):
            guard authenticatedLocalAci == localAci else {
                throw ParticipantDeleteError.invalidThread
            }
        }

        let stableConversationId: Data
        if let contactThread = thread as? TSContactThread {
            guard
                request.scope == .directChatBothAccounts,
                let contactAci = contactThread.contactAddress.aci,
                request.targetAuthor == localAci || request.targetAuthor == contactAci
            else { throw ParticipantDeleteError.scopeMismatch }

            switch origin {
            case .remoteEnvelope(let requester, _):
                guard requester == contactAci else { throw ParticipantDeleteError.invalidThread }
            case .localSentTranscript(let transcriptAci, _), .localInitiation(let transcriptAci):
                guard transcriptAci == localAci else { throw ParticipantDeleteError.invalidThread }
            }
            stableConversationId = Self.directConversationId(localAci: localAci, contactAci: contactAci)
        } else if
            let groupThread = thread as? TSGroupThread,
            let groupModel = groupThread.groupModel as? TSGroupModelV2
        {
            guard request.scope == .groupAllCurrentMembers else { throw ParticipantDeleteError.scopeMismatch }
            guard groupModel.membership.isFullMember(localAci) else {
                throw ParticipantDeleteError.invalidThread
            }
            guard groupModel.membership.isFullMember(origin.requester) else {
                throw ParticipantDeleteError.requesterIsNotCurrentMember
            }
            stableConversationId = Data([0x02]) + groupModel.groupId
        } else {
            throw ParticipantDeleteError.invalidThread
        }

        if let trustedServerTimestamp, request.targetSentTimestamp > trustedServerTimestamp {
            throw ParticipantDeleteError.futureTarget
        }

        return ValidatedRequest(
            request: request,
            requester: origin.requester,
            requesterDeviceId: origin.sourceDeviceId,
            stableConversationId: stableConversationId,
            localThreadUniqueId: thread.uniqueId,
        )
    }

    private func stableConversationId(for thread: TSThread, localAci: Aci) throws -> Data {
        if let contactThread = thread as? TSContactThread, let contactAci = contactThread.contactAddress.aci {
            return Self.directConversationId(localAci: localAci, contactAci: contactAci)
        }
        if let groupThread = thread as? TSGroupThread, let groupModel = groupThread.groupModel as? TSGroupModelV2 {
            return Data([0x02]) + groupModel.groupId
        }
        throw ParticipantDeleteError.invalidThread
    }

    private static func directConversationId(localAci: Aci, contactAci: Aci) -> Data {
        let local = localAci.serviceIdBinary
        let contact = contactAci.serviceIdBinary
        return Data([0x01]) + (local.lexicographicallyPrecedes(contact) ? local + contact : contact + local)
    }

    static func authorAci(for message: TSMessage, localAci: Aci) -> Aci? {
        if let incomingMessage = message as? TSIncomingMessage {
            return incomingMessage.authorAddress.aci
        }
        if message is TSOutgoingMessage {
            return localAci
        }
        return nil
    }

    private static func isSupportedTarget(_ message: TSMessage) -> Bool {
        guard !message.isViewOnceMessage, !message.isPoll, message.giftBadge == nil else { return false }
        guard !(message is OWSPaymentMessage), !(message is OWSArchivedPaymentMessage) else { return false }
        guard !message.isStoryReply else { return false }
        return true
    }

    private func tombstoneExists(for validated: ValidatedRequest, tx: DBReadTransaction) throws -> Bool {
        try ParticipantDeleteTombstoneRecord
            .filter(Column("stableConversationId") == validated.stableConversationId)
            .filter(Column("targetAuthorAci") == validated.request.targetAuthor.serviceIdBinary)
            .filter(Column("targetSentTimestamp") == Int64(validated.request.targetSentTimestamp))
            .fetchCount(tx.database) > 0
    }

    private func insertRequest(
        _ validated: ValidatedRequest,
        result: SSKProtoDataMessageParticipantDeleteReceiptResult,
        tx: DBWriteTransaction,
    ) throws {
        let requestRecord = ParticipantDeleteRequestRecord(
            requestId: validated.request.requestId,
            requesterAci: validated.requester.serviceIdBinary,
            requesterDeviceId: validated.requesterDeviceId.map { Int64($0.rawValue) },
            stableConversationId: validated.stableConversationId,
            localThreadUniqueId: validated.localThreadUniqueId,
            targetAuthorAci: validated.request.targetAuthor.serviceIdBinary,
            targetSentTimestamp: Int64(validated.request.targetSentTimestamp),
            protocolVersion: Int(validated.request.version),
            processingResult: Int(result.rawValue),
            createdAt: Int64(Date.ows_millisecondTimestamp()),
        )
        try requestRecord.insert(tx.database)
        try removeInvalidOrphanReceipts(for: requestRecord, tx: tx)
    }

    private func removeInvalidOrphanReceipts(
        for requestRecord: ParticipantDeleteRequestRecord,
        tx: DBWriteTransaction,
    ) throws {
        let receipts = try ParticipantDeleteDeviceReceiptRecord
            .filter(Column("requestId") == requestRecord.requestId)
            .fetchAll(tx.database)
        for receipt in receipts {
            guard
                let responder = try? Aci.parseFrom(serviceIdBinary: receipt.responderAci),
                isValidReceiptResponder(responder, requestRecord: requestRecord, tx: tx)
            else {
                try ParticipantDeleteDeviceReceiptRecord
                    .filter(Column("requestId") == receipt.requestId)
                    .filter(Column("responderAci") == receipt.responderAci)
                    .filter(Column("responderDeviceId") == receipt.responderDeviceId)
                    .deleteAll(tx.database)
                continue
            }
        }
    }

    private func insertPending(
        _ validated: ValidatedRequest,
        trustedServerTimestamp: UInt64?,
        tx: DBWriteTransaction,
    ) throws {
        let now = Date.ows_millisecondTimestamp()
        try PendingParticipantDeleteRecord
            .filter(Column("expiresAt") <= Int64(now))
            .deleteAll(tx.database)

        let matchingPendingCount = try PendingParticipantDeleteRecord
            .filter(Column("stableConversationId") == validated.stableConversationId)
            .filter(Column("targetAuthorAci") == validated.request.targetAuthor.serviceIdBinary)
            .filter(Column("targetSentTimestamp") == Int64(validated.request.targetSentTimestamp))
            .fetchCount(tx.database)
        if matchingPendingCount > 0 {
            return
        }

        let globalCount = try PendingParticipantDeleteRecord.fetchCount(tx.database)
        let requesterCount = try PendingParticipantDeleteRecord
            .filter(Column("requesterAci") == validated.requester.serviceIdBinary)
            .fetchCount(tx.database)
        let conversationCount = try PendingParticipantDeleteRecord
            .filter(Column("stableConversationId") == validated.stableConversationId)
            .fetchCount(tx.database)
        guard
            globalCount < ParticipantDeleteConfiguration.maximumPendingGlobally,
            requesterCount < ParticipantDeleteConfiguration.maximumPendingPerRequester,
            conversationCount < ParticipantDeleteConfiguration.maximumPendingPerConversation
        else { throw ParticipantDeleteError.pendingLimitExceeded }

        try PendingParticipantDeleteRecord(
            firstRequestId: validated.request.requestId,
            stableConversationId: validated.stableConversationId,
            localThreadUniqueId: validated.localThreadUniqueId,
            targetAuthorAci: validated.request.targetAuthor.serviceIdBinary,
            targetSentTimestamp: Int64(validated.request.targetSentTimestamp),
            requesterAci: validated.requester.serviceIdBinary,
            requesterDeviceId: validated.requesterDeviceId.map { Int64($0.rawValue) },
            requestServerTimestamp: Int64(trustedServerTimestamp ?? now),
            conversationScope: Int(validated.request.scope.rawValue),
            groupRevision: validated.request.groupRevision.map(Int64.init),
            expiresAt: Int64(now + ParticipantDeleteConfiguration.pendingLifetime),
            protocolVersion: Int(validated.request.version),
        ).insert(tx.database)
    }

    private func insertTombstone(
        stableConversationId: Data,
        threadUniqueId: String,
        targetAuthor: Aci,
        targetSentTimestamp: UInt64,
        interactionId: Int64?,
        firstRequestId: Data,
        requester: Aci,
        tx: DBWriteTransaction,
    ) throws {
        try ParticipantDeleteTombstoneRecord(
            stableConversationId: stableConversationId,
            localThreadUniqueId: threadUniqueId,
            targetAuthorAci: targetAuthor.serviceIdBinary,
            targetSentTimestamp: Int64(targetSentTimestamp),
            interactionId: interactionId,
            firstRequestId: firstRequestId,
            requesterAci: requester.serviceIdBinary,
            appliedAt: Int64(Date.ows_millisecondTimestamp()),
            protocolVersion: Int(ParticipantDeleteConfiguration.protocolVersion),
        ).insert(tx.database)

        guard
            let interactionId,
            interactionId > 0
        else { return }
        try insertAuthorMetadata(interactionId: interactionId, requester: requester, tx: tx)
    }

    private func insertAuthorMetadata(
        interactionId: Int64?,
        requester: Aci,
        tx: DBWriteTransaction,
    ) throws {
        guard
            let interactionId,
            let recipientId = recipientDatabaseTable.fetchRecipient(serviceId: requester, transaction: tx)?.id
        else { return }
        try ParticipantDeleteAuthorRecord(interactionId: interactionId, deleteAuthorId: recipientId).insert(tx.database)
    }

    private func rejectPendingDelete(
        _ pending: PendingParticipantDeleteRecord,
        localAci: Aci,
        tx: DBWriteTransaction,
    ) {
        failIfThrows {
            let requestRecords = try ParticipantDeleteRequestRecord
                .filter(Column("stableConversationId") == pending.stableConversationId)
                .filter(Column("targetAuthorAci") == pending.targetAuthorAci)
                .filter(Column("targetSentTimestamp") == pending.targetSentTimestamp)
                .fetchAll(tx.database)
            for requestRecord in requestRecords {
                try tx.database.execute(
                    sql: "UPDATE ParticipantDeleteRequest SET processingResult = ? WHERE requestId = ?",
                    arguments: [
                        SSKProtoDataMessageParticipantDeleteReceiptResult.rejectedInvalidTarget.rawValue,
                        requestRecord.requestId,
                    ],
                )
                if
                    requestRecord.requesterAci != localAci.serviceIdBinary,
                    let requester = try? Aci.parseFrom(serviceIdBinary: requestRecord.requesterAci)
                {
                    queueReceipt(
                        requestId: requestRecord.requestId,
                        result: .rejectedInvalidTarget,
                        recipient: requester,
                        tx: tx,
                    )
                }
            }
            try PendingParticipantDeleteRecord
                .filter(Column("stableConversationId") == pending.stableConversationId)
                .filter(Column("targetAuthorAci") == pending.targetAuthorAci)
                .filter(Column("targetSentTimestamp") == pending.targetSentTimestamp)
                .deleteAll(tx.database)
        }
    }

    private func queueReceipt(
        requestId: Data,
        result: SSKProtoDataMessageParticipantDeleteReceiptResult,
        recipient: Aci,
        tx: DBWriteTransaction,
    ) {
        let thread = TSContactThread.getOrCreateThread(
            withContactAddress: SignalServiceAddress(recipient),
            transaction: tx,
        )
        let message = OutgoingParticipantDeleteReceiptMessage(
            thread: thread,
            requestId: requestId,
            result: result,
            tx: tx,
        )
        let preparedMessage = PreparedOutgoingMessage.preprepared(transientMessageWithoutAttachments: message)
        SSKEnvironment.shared.messageSenderJobQueueRef.add(message: preparedMessage, transaction: tx)
    }
}
