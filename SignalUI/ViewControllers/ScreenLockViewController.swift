//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

@MainActor
public protocol ScreenLockViewDelegate: AnyObject {
    func unlockButtonWasTapped()
    func applicationPasswordWasSubmitted(_ password: String)
    func forgotApplicationPasswordWasTapped()
}

open class ScreenLockViewController: UIViewController {

    public enum UIState: CustomStringConvertible {
        case none
        case screenProtection // Shown while app is inactive or background, if enabled.
        case screenLock // Shown while app is active, if enabled.

        public var description: String {
            switch self {
            case .none:
                return "ScreenLockUIStateNone"
            case .screenProtection:
                return "ScreenLockUIStateScreenProtection"
            case .screenLock:
                return "ScreenLockUIStateScreenLock"
            }
        }
    }

    public weak var delegate: ScreenLockViewDelegate?

    // MARK: - UI

    private lazy var imageViewLogo = UIImageView(image: UIImage(named: "signal-logo-128-launch-screen"))
    private static var buttonHeight: CGFloat { 40 }
    private lazy var buttonUnlockUI = UIButton(
        configuration: .largePrimary(title: OWSLocalizedString(
            "SCREEN_LOCK_UNLOCK_SIGNAL",
            comment: "Label for button on lock screen that lets users unlock Signal.",
        )),
        primaryAction: UIAction { [weak self] _ in
            self?.unlockUIButtonTapped()
        },
    )
    private lazy var passwordField: UITextField = {
        let field = UITextField()
        field.borderStyle = .roundedRect
        field.placeholder = "应用密码"
        field.isSecureTextEntry = true
        field.textContentType = .password
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.returnKeyType = .go
        field.addTarget(self, action: #selector(submitPassword), for: .editingDidEndOnExit)
        return field
    }()
    private lazy var passwordUnlockButton = UIButton(
        configuration: .largePrimary(title: "使用应用密码解锁"),
        primaryAction: UIAction { [weak self] _ in self?.submitPassword() },
    )
    private lazy var forgotPasswordButton = UIButton(
        configuration: .plain(title: "忘记应用密码"),
        primaryAction: UIAction { [weak self] _ in self?.delegate?.forgotApplicationPasswordWasTapped() },
    )

    override open func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor.Signal.background

        view.addSubview(imageViewLogo)
        imageViewLogo.autoHCenterInSuperview()
        imageViewLogo.autoVCenterInSuperview()
        imageViewLogo.autoSetDimensions(to: .square(128))

        buttonUnlockUI.configuration?.title = "使用 Face ID / Touch ID 解锁"
        buttonUnlockUI.configuration?.baseForegroundColor = .Signal.label
        buttonUnlockUI.configuration?.baseBackgroundColor = .Signal.tertiaryFill
        let unlockStack = UIStackView(arrangedSubviews: [
            passwordField,
            passwordUnlockButton,
            buttonUnlockUI,
            forgotPasswordButton,
        ])
        unlockStack.axis = .vertical
        unlockStack.spacing = 12
        view.addSubview(unlockStack)
        unlockStack.autoPinWidthToSuperview(withMargin: 50)
        unlockStack.autoPinBottomToSuperviewMargin(withInset: 65)

        updateUIWithState(.screenProtection)
    }

    // The "screen blocking" window has three possible states:
    //
    // * "Just a logo". Used when app is launching and in app switcher. Must
    // match the "Launch Screen" storyboard pixel-for-pixel.
    //
    // * "Screen Lock, local auth UI presented".
    //
    // * "Screen Lock, local auth UI not presented". Show "unlock" button.
    public func updateUIWithState(_ uiState: UIState) {
        AssertIsOnMainThread()

        guard isViewLoaded else { return }

        let shouldShowBlockWindow = uiState != .none
        let shouldHaveScreenLock = uiState == .screenLock

        imageViewLogo.isHidden = !shouldShowBlockWindow
        passwordField.isHidden = !shouldHaveScreenLock
        passwordUnlockButton.isHidden = !shouldHaveScreenLock
        buttonUnlockUI.isHidden = !shouldHaveScreenLock || !AppPasswordLock.shared.isBiometricUnlockEnabled
        forgotPasswordButton.isHidden = !shouldHaveScreenLock
    }

    override open var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.defaultSupportedOrientations
    }

    private func unlockUIButtonTapped() {
        delegate?.unlockButtonWasTapped()
    }

    @objc private func submitPassword() {
        guard let password = passwordField.text, !password.isEmpty else {
            passwordField.becomeFirstResponder()
            return
        }
        passwordField.text = nil
        delegate?.applicationPasswordWasSubmitted(password)
    }
}

#if DEBUG

@available(iOS 17, *)
#Preview("State: none") {
    let vc = ScreenLockViewController()
    vc.view.isHidden = false // force view to load
    vc.updateUIWithState(.none)
    return vc
}

@available(iOS 17, *)
#Preview("State: screenProtection") {
    let vc = ScreenLockViewController()
    vc.view.isHidden = false // force view to load
    vc.updateUIWithState(.screenLock)
    return vc
}

@available(iOS 17, *)
#Preview("State: screenLock") {
    let vc = ScreenLockViewController()
    vc.view.isHidden = false // force view to load
    vc.updateUIWithState(.screenProtection)
    return vc
}

#endif
