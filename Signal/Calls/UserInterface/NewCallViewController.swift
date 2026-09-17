//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalServiceKit
import SignalUI

protocol NewCallViewControllerDelegate: AnyObject {
    func goToChat(for thread: TSThread)
}

class NewCallViewController: RecipientPickerContainerViewController {
    weak var delegate: (any NewCallViewControllerDelegate)?

    override func viewDidLoad() {
        super.viewDidLoad()

        title = OWSLocalizedString(
            "NEW_CALL_TITLE",
            comment: "Title for the contact picker that allows new calls to be started",
        )

        recipientPicker.allowsAddByAddress = true
        recipientPicker.shouldShowInvites = true
        recipientPicker.groupsToShow = BuildFlags.videoCalling ? .groupsThatUserIsMemberOfWhenSearching : .noGroups
        recipientPicker.delegate = self

        addRecipientPicker()

        navigationItem.rightBarButtonItem = .cancelButton(dismissingFrom: self)
    }

    private var callStarterContext: CallStarter.Context {
        .init(
            blockingManager: SSKEnvironment.shared.blockingManagerRef,
            databaseStorage: SSKEnvironment.shared.databaseStorageRef,
            callService: AppEnvironment.shared.callService,
        )
    }

    private func startIndividualCall(thread: TSContactThread, withVideo: Bool) {
        self.startCall(callStarter: CallStarter(
            contactThread: thread,
            withVideo: withVideo,
            context: self.callStarterContext,
        ))

    }

    private func startGroupCall(groupId: GroupIdentifier) {
        self.startCall(callStarter: CallStarter(
            groupId: groupId,
            context: self.callStarterContext,
        ))
    }

    private func startCall(callStarter: CallStarter) {
        let startCallResult = callStarter.startCall(from: self)
        if startCallResult.callDidStartOrResume {
            self.dismiss(animated: false)
        }
    }
}

// MARK: - RecipientContextMenuHelperDelegate

extension NewCallViewController: RecipientContextMenuHelperDelegate {
    private func goToChatAction(thread: TSThread) -> UIAction {
        UIAction(
            title: OWSLocalizedString(
                "NEW_CALL_MESSAGE_ACTION_TITLE",
                comment: "Title for a long-press context menu action to message a given recipient or group, triggered from a recipient in the New Call contact picker",
            ),
            image: Theme.iconImage(.contextMenuMessage),
        ) { [weak self] _ in
            self?.delegate?.goToChat(for: thread)
        }
    }

    private func startVoiceCallAction(thread: TSContactThread) -> UIAction {
        UIAction(
            title: OWSLocalizedString(
                "NEW_CALL_VOICE_CALL_ACTION_TITLE",
                comment: "Title for a long-press context menu action to start a voice call, triggered from a recipient in the New Call contact picker",
            ),
            image: Theme.iconImage(.contextMenuVoiceCall),
        ) { [weak self] _ in
            self?.startIndividualCall(thread: thread, withVideo: false)
        }
    }

    func additionalActions(for address: SignalServiceAddress) -> [UIAction] {
        let thread = TSContactThread.getOrCreateThread(contactAddress: address)
        return [
            goToChatAction(thread: thread),
            startVoiceCallAction(thread: thread),
        ]
    }

    func additionalActions(for groupThread: TSGroupThread) -> [UIAction] {
        [goToChatAction(thread: groupThread)]
    }
}

// MARK: - RecipientPickerDelegate

extension NewCallViewController: RecipientPickerDelegate, UsernameLinkScanDelegate {

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        selectionStyleForRecipient recipient: PickedRecipient,
        transaction: DBReadTransaction,
    ) -> UITableViewCell.SelectionStyle {
        return .default
    }

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        didSelectRecipient recipient: PickedRecipient,
    ) {
        switch recipient.identifier {
        case let .address(address):
            let thread = TSContactThread.getOrCreateThread(contactAddress: address)
            startIndividualCall(thread: thread, withVideo: false)
        case let .group(groupThread):
            guard BuildFlags.videoCalling else { return }
            startGroupCall(groupId: try! groupThread.groupIdentifier)
        }
    }

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        contactCellAccessoryForRecipient recipient: PickedRecipient,
        transaction: DBReadTransaction,
    ) -> ContactCellView.Accessory? {

        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.spacing = 20
        stackView.tintColor = Theme.primaryTextColor

        switch recipient.identifier {
        case .address:
            // This doesn't actually need to be hooked up to any action
            // since tapping the row already starts a voice call.
            let voiceCallImageView = UIImageView(image: Theme.iconImage(.buttonVoiceCall))
            stackView.addArrangedSubview(voiceCallImageView)
        case .group:
            return nil
        }

        return .init(accessoryView: stackView, size: .init(width: 24, height: 24))
    }

    func recipientPicker(_ recipientPickerViewController: RecipientPickerViewController, shouldAllowUserInteractionForRecipient recipient: PickedRecipient, transaction: DBReadTransaction) -> Bool {
        true
    }
}
