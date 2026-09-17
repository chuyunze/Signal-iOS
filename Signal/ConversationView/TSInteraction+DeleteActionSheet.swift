//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient
public import SignalServiceKit
import SignalUI
public import UIKit

public extension TSInteraction {
    func presentDeletionActionSheet(from fromViewController: UIViewController, forceDarkTheme: Bool = false) {
        let (
            associatedThread,
            hasLinkedDevices,
        ): (
            TSThread?,
            Bool,
        ) = SSKEnvironment.shared.databaseStorageRef.read { tx in
            return (
                thread(tx: tx),
                DependenciesBridge.shared.deviceStore.hasLinkedDevices(tx: tx),
            )
        }

        guard let associatedThread else { return }

        if associatedThread.isNoteToSelf {
            presentDeletionActionSheetForNoteToSelf(
                fromViewController: fromViewController,
                thread: associatedThread,
                hasLinkedDevices: hasLinkedDevices,
                forceDarkTheme: forceDarkTheme,
            )
        } else {
            presentDeletionActionSheetForNotNoteToSelf(
                fromViewController: fromViewController,
                thread: associatedThread,
                forceDarkTheme: forceDarkTheme,
            )
        }
    }

    private func presentDeletionActionSheetForNoteToSelf(
        fromViewController: UIViewController,
        thread: TSThread,
        hasLinkedDevices: Bool,
        forceDarkTheme: Bool,
    ) {
        let deleteMessageHeaderText = OWSLocalizedString(
            "DELETE_FOR_ME_NOTE_TO_SELF_ACTION_SHEET_HEADER",
            comment: "Header text for an action sheet confirming deleting a message in Note to Self.",
        )
        let deleteActionSheetButtonTitle = OWSLocalizedString(
            "DELETE_FOR_ME_NOTE_TO_SELF_ACTION_SHEET_BUTTON_TITLE",
            comment: "Title for an action sheet button explaining that a message will be deleted.",
        )
        let (title, message, deleteActionTitle): (String?, String, String) = if hasLinkedDevices {
            (
                deleteMessageHeaderText,
                OWSLocalizedString(
                    "DELETE_FOR_ME_NOTE_TO_SELF_LINKED_DEVICES_PRESENT_ACTION_SHEET_SUBHEADER",
                    comment: "Subheader for an action sheet explaining that a Note to Self deleted on this device will be deleted on the user's other devices as well.",
                ),
                deleteActionSheetButtonTitle,
            )
        } else {
            (
                nil,
                deleteMessageHeaderText,
                deleteActionSheetButtonTitle,
            )
        }

        let actionSheet = ActionSheetController(
            title: title,
            message: message,
        )
        if forceDarkTheme {
            actionSheet.overrideUserInterfaceStyle = .dark
        }
        actionSheet.addAction(deleteForMeAction(
            title: deleteActionTitle,
            thread: thread,
        ))
        actionSheet.addAction(.cancel)

        fromViewController.presentActionSheet(actionSheet)
    }

    class func buildDeleteMessage(
        thread: TSThread,
        message: TSMessage,
        localIdentifiers: LocalIdentifiers,
        canAdminDelete _: Bool,
        tx: DBReadTransaction,
    ) -> TransientOutgoingMessage? {
        guard DependenciesBridge.shared.participantDeleteManager.canParticipantDelete(
            message: message,
            thread: thread,
            tx: tx,
        ) else { return nil }
        return OutgoingParticipantDeleteMessage(
            thread: thread,
            message: message,
            localIdentifiers: localIdentifiers,
            tx: tx,
        )
    }

    private func buildDeleteForEveryoneAction(thread: TSThread) -> ActionSheetAction? {
        let participantDeleteManager = DependenciesBridge.shared.participantDeleteManager
        let db = DependenciesBridge.shared.db

        guard let message = self as? TSMessage else {
            return nil
        }

        let canParticipantDelete = db.read { tx in
            participantDeleteManager.canParticipantDelete(message: message, thread: thread, tx: tx)
        }
        if canParticipantDelete {
            return ActionSheetAction(
                title: CommonStrings.deleteForEveryoneButton,
                style: .destructive,
            ) { [weak self] _ in
                guard self != nil else { return }

                Self.showDeleteForEveryoneConfirmationIfNecessary(
                    deleteType: .regular,
                    completion: {
                        SSKEnvironment.shared.databaseStorageRef.write { tx in
                            let latestMessage = TSMessage.fetchMessageViaCache(
                                uniqueId: message.uniqueId,
                                transaction: tx,
                            )
                            guard let latestMessage else {
                                ToastViewHelper.presentToastOnFrontmostViewController(
                                    text: OWSLocalizedString(
                                        "REMOTE_DELETE_DISAPPEARED_MESSAGE_TOAST",
                                        comment: "Toast that appears when local user tried to delete a message that has disappeared",
                                    ),
                                )
                                Logger.warn("User tried to delete a message that no longer exists")
                                return
                            }
                            guard let latestThread = latestMessage.thread(tx: tx) else {
                                // We can't reach this point in the UI if a message doesn't have a thread.
                                return owsFailDebug("Trying to delete a message without a thread.")
                            }
                            guard let localIdentifiers = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx) else {
                                return owsFailDebug("LocalIdentifiers missing during message deletion.")
                            }

                            guard let deleteMessage = Self.buildDeleteMessage(
                                    thread: latestThread,
                                    message: latestMessage,
                                    localIdentifiers: localIdentifiers,
                                    canAdminDelete: false,
                                    tx: tx,
                                ) as? OutgoingParticipantDeleteMessage else {
                                return owsFailDebug("Failure to build outgoing delete for everyone.")
                            }
                            // Reset the sending states, so we can render the sending state of the
                            // deleted message. OutgoingDeleteMessage will automatically pass through
                            // it's send state to the message record that it is deleting.
                            // TODO: support sending state animation for incoming messages.
                            (latestMessage as? TSOutgoingMessage)?.updateWithRecipientAddressStates(deleteMessage.recipientAddressStates, tx: tx)

                            do {
                                try participantDeleteManager.processLocalInitiation(
                                    requestId: deleteMessage.requestId,
                                    targetAuthor: deleteMessage.targetAuthor,
                                    targetSentTimestamp: deleteMessage.targetSentTimestamp,
                                    scope: deleteMessage.participantScope,
                                    groupRevision: deleteMessage.groupRevision,
                                    thread: latestThread,
                                    localAci: localIdentifiers.aci,
                                    tx: tx,
                                )
                            } catch {
                                return owsFailDebug("Unable to participant-delete message: \(error)")
                            }

                            let preparedMessage = PreparedOutgoingMessage.preprepared(
                                transientMessageWithoutAttachments: deleteMessage,
                            )

                            SSKEnvironment.shared.messageSenderJobQueueRef.add(message: preparedMessage, transaction: tx)
                        }
                    },
                )
            }
        }
        return nil
    }

    private func presentDeletionActionSheetForNotNoteToSelf(
        fromViewController: UIViewController,
        thread: TSThread,
        forceDarkTheme: Bool,
    ) {
        let actionSheetController = ActionSheetController(
            message: OWSLocalizedString(
                "MESSAGE_ACTION_DELETE_FOR_TITLE",
                comment: "The title for the action sheet asking who the user wants to delete the message for.",
            ),
        )
        if forceDarkTheme {
            actionSheetController.overrideUserInterfaceStyle = .dark
        }

        actionSheetController.addAction(deleteForMeAction(
            title: CommonStrings.deleteForMeButton,
            thread: thread,
        ))

        if let deleteForEveryoneAction = buildDeleteForEveryoneAction(thread: thread) {
            actionSheetController.addAction(deleteForEveryoneAction)
        }

        actionSheetController.addAction(OWSActionSheets.cancelAction)

        fromViewController.presentActionSheet(actionSheetController)
    }

    static func showDeleteForEveryoneConfirmationIfNecessary(deleteType _: AdminDeleteManager.DeleteType, completion: @escaping () -> Void) {
        OWSActionSheets.showConfirmationAlert(
            title: OWSLocalizedString(
                "PARTICIPANT_DELETE_CONFIRMATION_TITLE",
                comment: "Title confirming a cooperative delete request for all compatible conversation devices.",
            ),
            message: OWSLocalizedString(
                "PARTICIPANT_DELETE_CONFIRMATION_MESSAGE",
                comment: "Explains that participant delete is best-effort and only affects compatible devices.",
            ),
            proceedTitle: CommonStrings.deleteForEveryoneButton,
            proceedStyle: .destructive,
        ) { _ in
            completion()
        }
    }

    private func deleteForMeAction(
        title: String,
        thread: TSThread,
    ) -> ActionSheetAction {
        let db = DependenciesBridge.shared.db
        let interactionDeleteManager = DependenciesBridge.shared.interactionDeleteManager

        return ActionSheetAction(
            title: CommonStrings.deleteForMeButton,
            style: .destructive,
        ) { [weak self] _ in
            guard let self else { return }

            db.asyncWrite { tx in
                guard
                    let freshSelf = TSInteraction.fetchViaCache(uniqueId: self.uniqueId, transaction: tx),
                    let freshThread = TSThread.fetchViaCache(uniqueId: thread.uniqueId, transaction: tx)
                else { return }

                interactionDeleteManager.delete(
                    interactions: [freshSelf],
                    sideEffects: .custom(
                        deleteForMeSyncMessage: .sendSyncMessage(interactionsThread: freshThread),
                    ),
                    tx: tx,
                )
            }
        }
    }
}

extension CommonStrings {
    public static var deleteForEveryoneButton: String {
        OWSLocalizedString(
            "MESSAGE_ACTION_DELETE_FOR_EVERYONE",
            comment: "The title for the action that deletes a message for all users in the conversation.",
        )
    }
}
