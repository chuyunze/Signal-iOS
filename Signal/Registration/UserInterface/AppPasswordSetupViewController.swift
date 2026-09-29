//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LocalAuthentication
import SignalServiceKit
import SignalUI

final class AppPasswordSetupViewController: OWSViewController, UITextFieldDelegate {
    private let completion: () -> Void
    private let requiresCurrentPassword: Bool
    private let scrollView = UIScrollView()
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

        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

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
        scrollView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 32),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil,
        )
    }

    private func configurePasswordField(_ field: UITextField, placeholder: String) {
        field.borderStyle = .roundedRect
        field.placeholder = placeholder
        field.isSecureTextEntry = true
        field.textContentType = .newPassword
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.delegate = self
        field.returnKeyType = field === confirmationField ? .done : .next
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        switch textField {
        case currentPasswordField:
            passwordField.becomeFirstResponder()
        case passwordField:
            confirmationField.becomeFirstResponder()
        case confirmationField:
            confirmationField.resignFirstResponder()
        default:
            textField.resignFirstResponder()
        }
        return true
    }

    @objc
    private func keyboardFrameWillChange(_ notification: Notification) {
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        let keyboardFrame = view.convert(endFrame, from: nil)
        let overlap = max(0, view.bounds.maxY - keyboardFrame.minY - view.safeAreaInsets.bottom)
        updateKeyboardInset(overlap, notification: notification)
    }

    @objc
    private func keyboardWillHide(_ notification: Notification) {
        updateKeyboardInset(0, notification: notification)
    }

    private func updateKeyboardInset(_ bottomInset: CGFloat, notification: Notification) {
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
        let curveValue = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        let options = UIView.AnimationOptions(rawValue: curveValue << 16)

        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.scrollView.contentInset.bottom = bottomInset
            self.scrollView.verticalScrollIndicatorInsets.bottom = bottomInset
            self.view.layoutIfNeeded()
        } completion: { _ in
            guard let firstResponder = [
                self.currentPasswordField,
                self.passwordField,
                self.confirmationField,
            ].first(where: { $0.isFirstResponder }) else {
                return
            }
            self.scrollView.scrollRectToVisible(
                firstResponder.convert(firstResponder.bounds, to: self.scrollView).insetBy(dx: 0, dy: -16),
                animated: true,
            )
        }
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
