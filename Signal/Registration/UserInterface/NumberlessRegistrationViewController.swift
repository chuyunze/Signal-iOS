//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

protocol NumberlessRegistrationPresenter: AnyObject {
    func submitInvitationCode(_ code: String, from viewController: NumberlessRegistrationViewController)
}

final class NumberlessRegistrationViewController: OWSViewController {
    private weak var presenter: NumberlessRegistrationPresenter?
    private let invitationField = UITextField()
    private let submitButton = UIButton(type: .system)

    init(presenter: NumberlessRegistrationPresenter) {
        self.presenter = presenter
        super.init()
        title = "使用邀请码创建账户"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.background

        let titleLabel = UILabel.titleLabelForRegistration(text: "输入邀请码")
        let explanationLabel = UILabel.explanationLabelForRegistration(
            text: "邀请码只能使用一次。注册过程不需要手机号。"
        )
        invitationField.borderStyle = .roundedRect
        invitationField.placeholder = "邀请码"
        invitationField.autocapitalizationType = .none
        invitationField.autocorrectionType = .no
        invitationField.textContentType = .oneTimeCode
        invitationField.accessibilityIdentifier = "numberless.registration.invitation"

        submitButton.configuration = .largePrimary(title: "继续")
        submitButton.addTarget(self, action: #selector(submit), for: .touchUpInside)

        var pasteButtonConfiguration = UIButton.Configuration.plain()
        pasteButtonConfiguration.title = "从剪贴板粘贴"
        let pasteButton = UIButton(
            configuration: pasteButtonConfiguration,
            primaryAction: UIAction { [weak self] _ in
                self?.invitationField.text = UIPasteboard.general.string
            }
        )
        var scanButtonConfiguration = UIButton.Configuration.plain()
        scanButtonConfiguration.title = "扫描邀请码二维码"
        let scanButton = UIButton(
            configuration: scanButtonConfiguration,
            primaryAction: UIAction { [weak self] _ in
                self?.openScanner()
            }
        )
        let stack = UIStackView(arrangedSubviews: [titleLabel, explanationLabel, invitationField, pasteButton, scanButton, submitButton])
        stack.axis = .vertical
        stack.spacing = 16
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func submit() {
        guard let rawValue = invitationField.text, let code = Self.invitationCode(from: rawValue) else {
            invitationField.becomeFirstResponder()
            return
        }
        submitButton.isEnabled = false
        presenter?.submitInvitationCode(code, from: self)
    }

    private func openScanner() {
        let scanner = QRCodeScanViewController(appearance: .framed)
        scanner.delegate = self
        navigationController?.pushViewController(scanner, animated: true)
    }

    private static func invitationCode(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed),
           let code = components.queryItems?.first(where: { $0.name == "invite" })?.value,
           !code.isEmpty
        {
            return code
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    func registrationFailed(message: String) {
        submitButton.isEnabled = true
        let sheet = ActionSheetController(title: "无法注册", message: message)
        sheet.addAction(ActionSheetAction(title: CommonStrings.okButton, style: .default))
        present(sheet, animated: true)
    }
}

extension NumberlessRegistrationViewController: QRCodeScanDelegate {
    func qrCodeScanViewScanned(qrCodeData: Data?, qrCodeString: String?) -> QRCodeScanOutcome {
        guard let value = qrCodeString, let code = Self.invitationCode(from: value) else {
            return .continueScanning
        }
        invitationField.text = code
        navigationController?.popViewController(animated: true)
        return .stopScanning
    }

    func qrCodeScanViewDismiss(_ qrCodeScanViewController: QRCodeScanViewController) {
        navigationController?.popViewController(animated: true)
    }
}

final class NumberlessRegistrationCompleteViewController: OWSViewController {
    private let accountId: String
    private let recoveryKey: String
    private let completion: (OWSUserProfile.NameComponent) -> Void
    private let usernameSetup: (UIViewController) -> Void
    private let nicknameField = UITextField()
    private let confirmationField = UITextField()

    init(
        accountId: String,
        recoveryKey: String,
        completion: @escaping (OWSUserProfile.NameComponent) -> Void,
        usernameSetup: @escaping (UIViewController) -> Void,
    ) {
        self.accountId = accountId
        self.recoveryKey = recoveryKey
        self.completion = completion
        self.usernameSetup = usernameSetup
        super.init()
        navigationItem.hidesBackButton = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.background
        let titleLabel = UILabel.titleLabelForRegistration(text: "保存账户恢复信息")
        let explanation = UILabel.explanationLabelForRegistration(
            text: "恢复账户时必须同时提供 Account ID 和 Recovery Key。服务器无法替你找回 Recovery Key。"
        )
        let accountLabel = selectableLabel(title: "Account ID", value: accountId)
        let recoveryLabel = selectableLabel(title: "Recovery Key", value: recoveryKey)
        nicknameField.borderStyle = .roundedRect
        nicknameField.placeholder = "昵称（必填）"
        nicknameField.autocapitalizationType = .words
        nicknameField.autocorrectionType = .yes
        nicknameField.textContentType = .name
        confirmationField.borderStyle = .roundedRect
        confirmationField.placeholder = "再次输入 Recovery Key 以确认"
        confirmationField.autocapitalizationType = .allCharacters
        confirmationField.autocorrectionType = .no
        let usernameButton = UIButton(
            configuration: .largeSecondary(title: "创建 Username（可选）"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.usernameSetup(self)
            }
        )
        let confirmButton = UIButton(
            configuration: .largePrimary(title: "我已安全保存"),
            primaryAction: UIAction { [weak self] _ in self?.confirmRecoveryKey() }
        )
        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            explanation,
            accountLabel,
            recoveryLabel,
            nicknameField,
            usernameButton,
            confirmationField,
            confirmButton,
        ])
        stack.axis = .vertical
        stack.spacing = 20
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func selectableLabel(title: String, value: String) -> UIButton {
        let button = UIButton(
            configuration: .largeSecondary(title: "\(title)\n\(value)\n点击复制"),
            primaryAction: UIAction { _ in
                UIPasteboard.general.string = value
            }
        )
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        return button
    }

    private func confirmRecoveryKey() {
        guard let nickname = OWSUserProfile.NameComponent(truncating: nicknameField.text ?? "") else {
            nicknameField.becomeFirstResponder()
            return
        }
        let entered = confirmationField.text?.filter { !$0.isWhitespace }.uppercased()
        let expected = recoveryKey.filter { !$0.isWhitespace }.uppercased()
        guard entered == expected else {
            let sheet = ActionSheetController(title: "Recovery Key 不一致", message: "请重新核对并完整输入 Recovery Key。")
            sheet.addAction(ActionSheetAction(title: CommonStrings.okButton, style: .default))
            present(sheet, animated: true)
            return
        }
        let passwordController = AppPasswordSetupViewController { [completion] in
            completion(nickname)
        }
        navigationController?.pushViewController(passwordController, animated: true)
    }
}
