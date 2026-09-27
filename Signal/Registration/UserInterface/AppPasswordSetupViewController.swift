//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LocalAuthentication
import SignalServiceKit
import SignalUI

final class AppPasswordSetupViewController: OWSViewController {
    private let completion: () -> Void
    private let requiresCurrentPassword: Bool
    private let currentPasswordField = UITextField()
    private let passwordField = UITextField()
    private let confirmationField = UITextField()
    private let biometricSwitch = UISwitch()
    private let saveButton = UIButton(type: .system)

    init(requiresCurrentPassword: Bool = false, completion: @escaping () -> Void) {
        self.requiresCurrentPassword = requiresCurrentPassword
        self.completion = completion
        super.init()
        title = "设置应用密码"
        navigationItem.hidesBackButton = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.background

        let titleLabel = UILabel.titleLabelForRegistration(text: "保护当前设备")
        let explanation = UILabel.explanationLabelForRegistration(
            text: "应用密码用于解锁本机 Signal，不能恢复账户。进入后台后会立即锁定。忘记密码只能清除本机数据，再使用 Account ID 和 Recovery Key 恢复账户。"
        )
        configurePasswordField(currentPasswordField, placeholder: "当前应用密码")
        configurePasswordField(passwordField, placeholder: "应用密码（至少 8 位）")
        configurePasswordField(confirmationField, placeholder: "再次输入应用密码")

        let biometricLabel = UILabel()
        biometricLabel.text = biometricTitle
        biometricLabel.textColor = .Signal.label
        biometricLabel.numberOfLines = 0
        let biometricRow = UIStackView(arrangedSubviews: [biometricLabel, biometricSwitch])
        biometricRow.axis = .horizontal
        biometricRow.alignment = .center
        biometricRow.spacing = 12
        biometricSwitch.isEnabled = canUseBiometrics
        biometricSwitch.isOn = AppPasswordLock.shared.isConfigured
            ? AppPasswordLock.shared.isBiometricUnlockEnabled
            : canUseBiometrics

        saveButton.configuration = .largePrimary(title: "设置并继续")
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)

        var arrangedSubviews: [UIView] = [
            titleLabel,
            explanation,
        ]
        if requiresCurrentPassword {
            arrangedSubviews.append(currentPasswordField)
        }
        arrangedSubviews.append(contentsOf: [passwordField, confirmationField, biometricRow, saveButton])
        let stack = UIStackView(arrangedSubviews: arrangedSubviews)
        stack.axis = .vertical
        stack.spacing = 18
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func configurePasswordField(_ field: UITextField, placeholder: String) {
        field.borderStyle = .roundedRect
        field.placeholder = placeholder
        field.isSecureTextEntry = true
        field.textContentType = .newPassword
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
    }

    private var canUseBiometrics: Bool {
        let context = DeviceOwnerAuthenticationType.localAuthenticationContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    private var biometricTitle: String {
        switch DeviceOwnerAuthenticationType.current {
        case .faceId: return "使用 Face ID 快捷解锁"
        case .touchId: return "使用 Touch ID 快捷解锁"
        case .opticId: return "使用 Optic ID 快捷解锁"
        case .unknown, .passcode: return "此设备没有可用的生物识别"
        }
    }

    @objc private func save() {
        if requiresCurrentPassword {
            switch AppPasswordLock.shared.verify(currentPasswordField.text ?? "") {
            case .success:
                break
            case .invalid(let remaining):
                showError("当前应用密码不正确。再错误 \(remaining) 次后将暂时锁定。")
                return
            case .delayed(let until):
                let seconds = max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
                showError("尝试次数过多，请在 \(seconds) 秒后重试。")
                return
            case .notConfigured:
                showError("当前设备尚未设置应用密码。")
                return
            }
        }
        guard let password = passwordField.text, password.count >= 8 else {
            showError("应用密码至少需要 8 个字符。")
            return
        }
        guard password == confirmationField.text else {
            showError("两次输入的应用密码不一致。")
            return
        }

        saveButton.isEnabled = false
        do {
            try AppPasswordLock.shared.setPassword(password, enableBiometrics: biometricSwitch.isOn)
            currentPasswordField.text = nil
            passwordField.text = nil
            confirmationField.text = nil
            completion()
        } catch {
            saveButton.isEnabled = true
            showError("无法保存应用密码，请重试。")
        }
    }

    private func showError(_ message: String) {
        let sheet = ActionSheetController(title: "无法设置应用密码", message: message)
        sheet.addAction(ActionSheetAction(title: CommonStrings.okButton, style: .default))
        present(sheet, animated: true)
    }
}
