//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import LibSignalClient

public final class OutgoingAdminDeleteMessage: TransientOutgoingMessage {
    let originalMessageTimestamp: UInt64
    let originalMessageAuthor: Aci?
    let originalMessageUniqueId: String

    public init(
        thread: TSThread,
        message: TSMessage,
        localIdentifiers: LocalIdentifiers,
        tx: DBReadTransaction,
    ) {
        owsAssertDebug(thread.uniqueId == message.uniqueThreadId)

        self.originalMessageTimestamp = message.timestamp

        if let incomingMessage = message as? TSIncomingMessage {
            self.originalMessageAuthor = incomingMessage.authorAddress.aci
        } else {
            self.originalMessageAuthor = localIdentifiers.aci
        }

        self.originalMessageUniqueId = message.uniqueId

        super.init(
            outgoingMessageWith: TSOutgoingMessageBuilder.outgoingMessageBuilder(thread: thread),
            additionalRecipients: [],
            explicitRecipients: [],
            skippedRecipients: [],
            transaction: tx,
        )
    }

    override public class var supportsSecureCoding: Bool { true }

    override public func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(NSNumber(value: self.originalMessageTimestamp), forKey: "originalMessageTimestamp")
        if let originalMessageAuthor {
            coder.encode(originalMessageAuthor.serviceIdBinary, forKey: "originalMessageAuthorBinary")
        }
        coder.encode(originalMessageUniqueId, forKey: "originalMessageUniqueId")
    }

    public required init?(coder: NSCoder) {
        guard
            let originalMessageTimestamp = coder.decodeObject(of: NSNumber.self, forKey: "originalMessageTimestamp"),
            let originalMessageAuthorBinary = coder.decodeObject(of: NSData.self, forKey: "originalMessageAuthorBinary") as Data?,
            let originalMessageUniqueId = coder.decodeObject(of: NSString.self, forKey: "originalMessageUniqueId") as String?
        else {
            return nil
        }
        self.originalMessageTimestamp = originalMessageTimestamp.uint64Value
        self.originalMessageAuthor = try? Aci.parseFrom(serviceIdBinary: originalMessageAuthorBinary)
        self.originalMessageUniqueId = originalMessageUniqueId
        super.init(coder: coder)
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(super.hash)
        hasher.combine(self.originalMessageTimestamp)
        hasher.combine(self.originalMessageAuthor)
        hasher.combine(self.originalMessageUniqueId)
        return hasher.finalize()
    }

    override public func isEqual(_ object: Any?) -> Bool {
        guard let object = object as? Self else { return false }
        guard super.isEqual(object) else { return false }
        guard self.originalMessageTimestamp == object.originalMessageTimestamp else { return false }
        guard self.originalMessageAuthor == object.originalMessageAuthor else { return false }
        guard self.originalMessageUniqueId == object.originalMessageUniqueId else { return false }
        return true
    }

    override public func dataMessageBuilder(with thread: TSThread, transaction: DBReadTransaction) -> SSKProtoDataMessageBuilder? {
        guard let originalMessageAuthor else {
            return nil
        }

        let adminDeleteBuilder = SSKProtoDataMessageAdminDelete.builder()
        adminDeleteBuilder.setTargetAuthorAciBinary(originalMessageAuthor.serviceIdBinary)
        adminDeleteBuilder.setTargetSentTimestamp(originalMessageTimestamp)

        let builder = super.dataMessageBuilder(with: thread, transaction: transaction)
        builder?.setTimestamp(self.timestamp)
        builder?.setAdminDelete(adminDeleteBuilder.buildInfallibly())
        return builder
    }

    override public func anyUpdateOutgoingMessage(transaction: DBWriteTransaction, block: (TSOutgoingMessage) -> Void) {
        super.anyUpdateOutgoingMessage(transaction: transaction, block: block)

        let deletedMessage = TSMessage.fetchMessageViaCache(
            uniqueId: originalMessageUniqueId,
            transaction: transaction,
        )
        if let outgoingDeletedMessage = deletedMessage as? TSOutgoingMessage {
            outgoingDeletedMessage.updateWithRecipientAddressStates(self.recipientAddressStates, tx: transaction)
        }

        if let deletedMessage {
            AdminDeleteManager.updateRecipientStatesAdminDelete(recipientAddressStates: self.recipientAddressStates, interactionId: deletedMessage.sqliteRowId!, tx: transaction)

            DependenciesBridge.shared.db.touch(interaction: deletedMessage, shouldReindex: false, tx: transaction)
        }
    }

    override public var relatedUniqueIds: Set<String> {
        return super.relatedUniqueIds.union([self.originalMessageUniqueId].compacted())
    }
}

// MARK: - Participant Delete

public final class OutgoingParticipantDeleteMessage: TransientOutgoingMessage {
    public let requestId: Data
    public let targetAuthor: Aci
    public let targetSentTimestamp: UInt64
    public let participantScope: SSKProtoDataMessageParticipantDeleteScope
    public let groupRevision: UInt32?
    private let clientRequestedAt: UInt64
    private let originalMessageUniqueId: String

    public init?(
        thread: TSThread,
        message: TSMessage,
        localIdentifiers: LocalIdentifiers,
        requestId: Data = UUID().data,
        tx: DBReadTransaction,
    ) {
        guard requestId.count == 16 else { return nil }
        guard message.uniqueThreadId == thread.uniqueId else { return nil }
        guard message.timestamp > 0, SDS.fitsInInt64(message.timestamp) else { return nil }
        guard let targetAuthor = ParticipantDeleteManager.authorAci(for: message, localAci: localIdentifiers.aci) else {
            return nil
        }

        let participantScope: SSKProtoDataMessageParticipantDeleteScope
        let groupRevision: UInt32?
        if thread is TSContactThread {
            participantScope = .directChatBothAccounts
            groupRevision = nil
        } else if
            let groupThread = thread as? TSGroupThread,
            let groupModel = groupThread.groupModel as? TSGroupModelV2
        {
            participantScope = .groupAllCurrentMembers
            groupRevision = groupModel.revision
        } else {
            return nil
        }

        self.requestId = requestId
        self.targetAuthor = targetAuthor
        self.targetSentTimestamp = message.timestamp
        self.participantScope = participantScope
        self.groupRevision = groupRevision
        self.clientRequestedAt = Date.ows_millisecondTimestamp()
        self.originalMessageUniqueId = message.uniqueId

        super.init(
            outgoingMessageWith: TSOutgoingMessageBuilder.outgoingMessageBuilder(thread: thread),
            additionalRecipients: [],
            explicitRecipients: [],
            skippedRecipients: [],
            transaction: tx,
        )
    }

    override public class var supportsSecureCoding: Bool { true }

    override public func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(requestId, forKey: "participantDelete.requestId")
        coder.encode(targetAuthor.serviceIdBinary, forKey: "participantDelete.targetAuthor")
        coder.encode(NSNumber(value: targetSentTimestamp), forKey: "participantDelete.targetSentTimestamp")
        coder.encode(NSNumber(value: participantScope.rawValue), forKey: "participantDelete.scope")
        if let groupRevision {
            coder.encode(NSNumber(value: groupRevision), forKey: "participantDelete.groupRevision")
        }
        coder.encode(NSNumber(value: clientRequestedAt), forKey: "participantDelete.clientRequestedAt")
        coder.encode(originalMessageUniqueId, forKey: "participantDelete.originalMessageUniqueId")
    }

    public required init?(coder: NSCoder) {
        guard
            let requestId = coder.decodeObject(of: NSData.self, forKey: "participantDelete.requestId") as Data?,
            requestId.count == 16,
            let targetAuthorData = coder.decodeObject(of: NSData.self, forKey: "participantDelete.targetAuthor") as Data?,
            let targetAuthor = try? Aci.parseFrom(serviceIdBinary: targetAuthorData),
            let targetTimestamp = coder.decodeObject(of: NSNumber.self, forKey: "participantDelete.targetSentTimestamp"),
            targetTimestamp.uint64Value > 0,
            SDS.fitsInInt64(targetTimestamp.uint64Value),
            let scopeNumber = coder.decodeObject(of: NSNumber.self, forKey: "participantDelete.scope"),
            let scope = SSKProtoDataMessageParticipantDeleteScope(rawValue: scopeNumber.int32Value),
            scope != .unknown,
            let requestedAt = coder.decodeObject(of: NSNumber.self, forKey: "participantDelete.clientRequestedAt"),
            let originalMessageUniqueId = coder.decodeObject(of: NSString.self, forKey: "participantDelete.originalMessageUniqueId") as String?
        else { return nil }

        self.requestId = requestId
        self.targetAuthor = targetAuthor
        self.targetSentTimestamp = targetTimestamp.uint64Value
        self.participantScope = scope
        self.groupRevision = coder.decodeObject(of: NSNumber.self, forKey: "participantDelete.groupRevision")?.uint32Value
        self.clientRequestedAt = requestedAt.uint64Value
        self.originalMessageUniqueId = originalMessageUniqueId
        super.init(coder: coder)
    }

    override public func dataMessageBuilder(with thread: TSThread, transaction: DBReadTransaction) -> SSKProtoDataMessageBuilder? {
        let participantDeleteBuilder = SSKProtoDataMessageParticipantDelete.builder()
        participantDeleteBuilder.setVersion(ParticipantDeleteConfiguration.protocolVersion)
        participantDeleteBuilder.setTargetAuthorAciBinary(targetAuthor.serviceIdBinary)
        participantDeleteBuilder.setTargetSentTimestamp(targetSentTimestamp)
        participantDeleteBuilder.setRequestID(requestId)
        participantDeleteBuilder.setClientRequestedAt(clientRequestedAt)
        participantDeleteBuilder.setScope(participantScope)
        if let groupRevision {
            participantDeleteBuilder.setGroupRevision(groupRevision)
        }

        let builder = super.dataMessageBuilder(with: thread, transaction: transaction)
        builder?.setTimestamp(timestamp)
        builder?.setParticipantDelete(participantDeleteBuilder.buildInfallibly())
        return builder
    }

    override public func anyUpdateOutgoingMessage(transaction: DBWriteTransaction, block: (TSOutgoingMessage) -> Void) {
        super.anyUpdateOutgoingMessage(transaction: transaction, block: block)
        guard let deletedMessage = TSMessage.fetchMessageViaCache(uniqueId: originalMessageUniqueId, transaction: transaction) else {
            return
        }
        if let outgoingDeletedMessage = deletedMessage as? TSOutgoingMessage {
            outgoingDeletedMessage.updateWithRecipientAddressStates(recipientAddressStates, tx: transaction)
        }
        DependenciesBridge.shared.db.touch(interaction: deletedMessage, shouldReindex: false, tx: transaction)
    }

    override public var relatedUniqueIds: Set<String> {
        super.relatedUniqueIds.union([originalMessageUniqueId])
    }
}

// MARK: - Participant Delete Receipt

final class OutgoingParticipantDeleteReceiptMessage: TransientOutgoingMessage {
    private let requestId: Data
    private let result: SSKProtoDataMessageParticipantDeleteReceiptResult

    init(
        thread: TSContactThread,
        requestId: Data,
        result: SSKProtoDataMessageParticipantDeleteReceiptResult,
        tx: DBReadTransaction,
    ) {
        self.requestId = requestId
        self.result = result
        super.init(
            outgoingMessageWith: TSOutgoingMessageBuilder.outgoingMessageBuilder(thread: thread),
            additionalRecipients: [],
            explicitRecipients: [],
            skippedRecipients: [],
            transaction: tx,
        )
    }

    override class var supportsSecureCoding: Bool { true }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(requestId, forKey: "participantDeleteReceipt.requestId")
        coder.encode(NSNumber(value: result.rawValue), forKey: "participantDeleteReceipt.result")
    }

    required init?(coder: NSCoder) {
        guard
            let requestId = coder.decodeObject(of: NSData.self, forKey: "participantDeleteReceipt.requestId") as Data?,
            requestId.count == 16,
            let resultNumber = coder.decodeObject(of: NSNumber.self, forKey: "participantDeleteReceipt.result"),
            let result = SSKProtoDataMessageParticipantDeleteReceiptResult(rawValue: resultNumber.int32Value),
            result != .unknown
        else { return nil }
        self.requestId = requestId
        self.result = result
        super.init(coder: coder)
    }

    override func dataMessageBuilder(with thread: TSThread, transaction: DBReadTransaction) -> SSKProtoDataMessageBuilder? {
        let receiptBuilder = SSKProtoDataMessageParticipantDeleteReceipt.builder()
        receiptBuilder.setVersion(ParticipantDeleteConfiguration.protocolVersion)
        receiptBuilder.setRequestID(requestId)
        receiptBuilder.setResult(result)

        let builder = super.dataMessageBuilder(with: thread, transaction: transaction)
        builder?.setTimestamp(timestamp)
        builder?.setParticipantDeleteReceipt(receiptBuilder.buildInfallibly())
        return builder
    }

    override func shouldSyncTranscript() -> Bool { false }
}
