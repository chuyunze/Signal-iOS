//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalServiceKit
import SignalUI

struct NumberlessRecoveryInput {
    let accountId: Aci
    let accountEntropyPool: AccountEntropyPool
    let totp: UInt32?
}

protocol NumberlessRecoveryPresenter: AnyObject {
    func recoverNumberlessAccount(
        _ input: NumberlessRecoveryInput,
        from viewController: NumberlessRecoveryViewController,
    )
}

final class NumberlessRecoveryViewController: OWSViewController {
    private weak var presenter: NumberlessRecoveryPresenter?
    private let accountIdField = UITextField()
    private let recoveryKeyField = UITextField()
    private let totpField = UITextField()
    private let submitButton = UIButton(type: .system)

    init(presenter: NumberlessRecoveryPresenter) {
        self.presenter = presenter
        super.init()
        title = "恢复已有账户"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.background

        let titleLabel = UILabel.titleLabelForRegistration(text: "恢复无手机号账户")
        let explanation = UILabel.explanationLabelForRegistration(
            text: "请输入注册时保存的 Account ID 和 Recovery Key。恢复过程不需要邀请码。"
        )
        configure(
            accountIdField,
            placeholder: "Account ID",
            contentType: .username,
            keyboardType: .asciiCapable,
        )
        configure(
            recoveryKeyField,
            placeholder: "Recovery Key",
            contentType: .password,
            keyboardType: .asciiCapable,
        )
        recoveryKeyField.autocapitalizationType = .allCharacters
        configure(
            totpField,
            placeholder: "二次验证码（如已启用）",
            contentType: .oneTimeCode,
            keyboardType: .numberPad,
        )

        var pasteButtonConfiguration = UIButton.Configuration.plain()
        pasteButtonConfiguration.title = "从剪贴板粘贴 Recovery Key"
        let pasteButton = UIButton(
            configuration: pasteButtonConfiguration,
            primaryAction: UIAction { [weak self] _ in
                self?.recoveryKeyField.text = UIPasteboard.general.string
            }
        )
        submitButton.configuration = .largePrimary(title: "恢复账户")
        submitButton.addTarget(self, action: #selector(submit), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            explanation,
            accountIdField,
            recoveryKeyField,
            pasteButton,
            totpField,
            submitButton,
        ])
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

    private func configure(
        _ field: UITextField,
        placeholder: String,
        contentType: UITextContentType,
        keyboardType: UIKeyboardType,
    ) {
        field.borderStyle = .roundedRect
        field.placeholder = placeholder
        field.textContentType = contentType
        field.keyboardType = keyboardType
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
    }

    @objc private func submit() {
        guard
            let accountIdValue = accountIdField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            let accountId = Aci.parseFrom(aciString: accountIdValue)
        else {
            showError("Account ID 格式不正确。")
            return
        }
        guard
            let recoveryKeyValue = recoveryKeyField.text,
            let displayableKey = try? DisplayableAccountEntropyPool(displayString: recoveryKeyValue)
        else {
            showError("Recovery Key 格式不正确。")
            return
        }

        let totp: UInt32?
        if let value = totpField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            guard value.count == 6, let parsed = UInt32(value) else {
                showError("二次验证码应为 6 位数字。")
                return
            }
            totp = parsed
        } else {
            totp = nil
        }

        submitButton.isEnabled = false
        presenter?.recoverNumberlessAccount(
            NumberlessRecoveryInput(
                accountId: accountId,
                accountEntropyPool: displayableKey.rawValue,
                totp: totp,
            ),
            from: self,
        )
    }

    func recoveryFailed(message: String, focusTotp: Bool = false) {
        submitButton.isEnabled = true
        if focusTotp {
            totpField.becomeFirstResponder()
        }
        showError(message)
    }

    private func showError(_ message: String) {
        let sheet = ActionSheetController(title: "无法恢复账户", message: message)
        sheet.addAction(ActionSheetAction(title: CommonStrings.okButton, style: .default))
        present(sheet, animated: true)
    }
}

final class NumberlessRecoveryCompleteViewController: OWSViewController {
    private let accountId: String
    private let username: String?
    private let completion: () -> Void
    private let usernameSetup: (UIViewController, String?) -> Void

    init(
        accountId: String,
        username: String?,
        completion: @escaping () -> Void,
        usernameSetup: @escaping (UIViewController, String?) -> Void,
    ) {
        self.accountId = accountId
        self.username = username
        self.completion = completion
        self.usernameSetup = usernameSetup
        super.init()
        navigationItem.hidesBackButton = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.background

        let titleLabel = UILabel.titleLabelForRegistration(text: "账户身份已恢复")
        let explanation = UILabel.explanationLabelForRegistration(
            text: "账户身份已经恢复。为保护隐私，历史消息、附件和通话记录不会导出或恢复。"
        )
        let accountLabel = UILabel.explanationLabelForRegistration(text: "Account ID\n\(accountId)")
        accountLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        let usernameLabel = UILabel.explanationLabelForRegistration(
            text: username.map { "已保留 Username：\($0)" } ?? "此账户尚未设置 Username。"
        )
        let usernameButton = UIButton(
            configuration: .largeSecondary(title: username == nil ? "创建 Username" : "检查或重新设置 Username"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.usernameSetup(self, self.username)
            }
        )
        let finishButton = UIButton(
            configuration: .largePrimary(title: "设置应用密码并继续"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                let passwordController = AppPasswordSetupViewController { [completion] in completion() }
                self.navigationController?.pushViewController(passwordController, animated: true)
            }
        )
        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            explanation,
            accountLabel,
            usernameLabel,
            usernameButton,
            finishButton,
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
}
