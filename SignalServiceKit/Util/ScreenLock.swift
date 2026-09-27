//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LocalAuthentication
import CommonCrypto
import Security

public class ScreenLock: NSObject {

    public enum Outcome {
        case success
        case cancel
        case failure(error: String)
        case unexpectedFailure(error: String)
    }

    public static let screenLockTimeoutDefault: TimeInterval = 15 * .minute

    public let screenLockTimeouts: [TimeInterval] = [
        1 * .minute,
        5 * .minute,
        15 * .minute,
        30 * .minute,
        1 * .hour,
        0,
    ]

    public static let ScreenLockDidChange = Notification.Name("ScreenLockDidChange")

    private static let OWSScreenLock_Key_IsScreenLockEnabled = "OWSScreenLock_Key_IsScreenLockEnabled"
    private static let OWSScreenLock_Key_ScreenLockTimeoutSeconds = "OWSScreenLock_Key_ScreenLockTimeoutSeconds"

    // MARK: - Singleton class

    public static let shared = ScreenLock()

    override private init() {
        super.init()

    }

    // MARK: - KV Store

    public let keyValueStore = KeyValueStore(collection: "OWSScreenLock_Collection")

    // MARK: - Properties

    public func isScreenLockEnabled() -> Bool {
        AssertIsOnMainThread()

        return SSKEnvironment.shared.databaseStorageRef.read { transaction in
            return isScreenLockEnabled(tx: transaction)
        }
    }

    public func isScreenLockEnabled(tx: DBReadTransaction) -> Bool {
        if AppPasswordLock.shared.isConfigured {
            return true
        }
        return self.keyValueStore.getBool(
            ScreenLock.OWSScreenLock_Key_IsScreenLockEnabled,
            defaultValue: false,
            transaction: tx,
        )
    }

    public func setIsScreenLockEnabled(_ value: Bool) {
        AssertIsOnMainThread()

        SSKEnvironment.shared.databaseStorageRef.write { transaction in
            setIsScreenLockEnabled(value, tx: transaction)
        }

        NotificationCenter.default.postOnMainThread(name: ScreenLock.ScreenLockDidChange, object: nil)
    }

    public func setIsScreenLockEnabled(_ value: Bool, tx: DBWriteTransaction) {
        guard !AppPasswordLock.shared.isConfigured || value else {
            Logger.warn("Ignoring attempt to disable mandatory application password lock")
            return
        }
        self.keyValueStore.setBool(
            value,
            key: ScreenLock.OWSScreenLock_Key_IsScreenLockEnabled,
            transaction: tx,
        )
    }

    public func screenLockTimeout() -> TimeInterval {
        AssertIsOnMainThread()

        return SSKEnvironment.shared.databaseStorageRef.read { transaction in
            return screenLockTimeout(tx: transaction)
        }
    }

    public func screenLockTimeout(tx: DBReadTransaction) -> TimeInterval {
        if AppPasswordLock.shared.isConfigured {
            return 0
        }
        return self.keyValueStore.getDouble(
            ScreenLock.OWSScreenLock_Key_ScreenLockTimeoutSeconds,
            defaultValue: ScreenLock.screenLockTimeoutDefault,
            transaction: tx,
        )
    }

    public func setScreenLockTimeout(_ value: TimeInterval) {
        AssertIsOnMainThread()

        SSKEnvironment.shared.databaseStorageRef.write { transaction in
            setScreenLockTimeout(value, tx: transaction)
        }

        NotificationCenter.default.postOnMainThread(name: ScreenLock.ScreenLockDidChange, object: nil)
    }

    public func setScreenLockTimeout(_ value: TimeInterval, tx: DBWriteTransaction) {
        self.keyValueStore.setDouble(
            value,
            key: ScreenLock.OWSScreenLock_Key_ScreenLockTimeoutSeconds,
            transaction: tx,
        )
    }

    // MARK: - Methods

    // This method should only be called:
    //
    // * On the main thread.
    //
    // Exactly one of these completions will be performed:
    //
    // * Asynchronously.
    // * On the main thread.
    public func tryToUnlockScreenLock(
        success: @escaping (() -> Void),
        failure: @escaping ((Error) -> Void),
        unexpectedFailure: @escaping ((Error) -> Void),
        cancel: @escaping (() -> Void),
    ) {
        AssertIsOnMainThread()

        tryToVerifyLocalAuthentication(
            localizedReason: OWSLocalizedString(
                "SCREEN_LOCK_REASON_UNLOCK_SCREEN_LOCK",
                comment: "Description of how and why Signal iOS uses Touch ID/Face ID/Phone Passcode to unlock 'screen lock'.",
            ),
            completion: { (outcome: Outcome) in
                AssertIsOnMainThread()

                switch outcome {
                case .failure(let error):
                    Logger.error("local authentication failed with error: \(error)")
                    failure(self.authenticationError(errorDescription: error))
                case .unexpectedFailure(let error):
                    Logger.error("local authentication failed with unexpected error: \(error)")
                    unexpectedFailure(self.authenticationError(errorDescription: error))
                case .success:
                    success()
                case .cancel:
                    cancel()
                }
            },
        )
    }

    // This method should only be called:
    //
    // * On the main thread.
    //
    // completionParam will be performed:
    //
    // * Asynchronously.
    // * On the main thread.
    private func tryToVerifyLocalAuthentication(
        localizedReason: String,
        completion completionParam: @escaping ((Outcome) -> Void),
    ) {
        AssertIsOnMainThread()

        let defaultErrorDescription = DeviceAuthenticationErrorMessage.unknownError

        // Ensure completion is always called on the main thread.
        let completion = { (outcome: Outcome) in
            DispatchQueue.main.async {
                completionParam(outcome)
            }
        }

        let context = DeviceOwnerAuthenticationType.localAuthenticationContext()

        var authError: NSError?
        guard AppPasswordLock.shared.isBiometricUnlockEnabled else {
            completion(.cancel)
            return
        }
        let canEvaluatePolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError)
        if !canEvaluatePolicy || authError != nil {
            Logger.error("could not determine if local authentication is supported: \(String(describing: authError))")

            let outcome = self.outcomeForLAError(
                errorParam: authError,
                defaultErrorDescription: defaultErrorDescription,
            )
            switch outcome {
            case .success:
                owsFailDebug("local authentication unexpected success")
                completion(.failure(error: defaultErrorDescription))
            case .cancel, .failure, .unexpectedFailure:
                completion(outcome)
            }
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: localizedReason) { success, evaluateError in

            if success {
                Logger.info("local authentication succeeded.")
                completion(.success)
            } else {
                let outcome = self.outcomeForLAError(
                    errorParam: evaluateError,
                    defaultErrorDescription: defaultErrorDescription,
                )
                switch outcome {
                case .success:
                    owsFailDebug("local authentication unexpected success")
                    completion(.failure(error: defaultErrorDescription))
                case .cancel, .failure, .unexpectedFailure:
                    completion(outcome)
                }
            }
        }
    }

    // MARK: - Outcome

    private func outcomeForLAError(errorParam: Error?, defaultErrorDescription: String) -> Outcome {
        if let error = errorParam {
            guard let laError = error as? LAError else {
                return .failure(error: defaultErrorDescription)
            }

            switch laError.code {
            case .biometryNotAvailable:
                Logger.error("local authentication error: biometryNotAvailable.")
                return .failure(error: ScreenLock.ErrorMessage.authenticationNotAvailable)
            case .biometryNotEnrolled:
                Logger.error("local authentication error: biometryNotEnrolled.")
                return .failure(error: ScreenLock.ErrorMessage.authenticationNotEnrolled)
            case .biometryLockout:
                Logger.error("local authentication error: biometryLockout.")
                return .failure(error: DeviceAuthenticationErrorMessage.lockout)
            default:
                // Fall through to second switch
                break
            }

            switch laError.code {
            case .authenticationFailed:
                Logger.error("local authentication error: authenticationFailed.")
                return .failure(error: DeviceAuthenticationErrorMessage.authenticationFailed)
            case .userCancel, .userFallback, .systemCancel, .appCancel:
                Logger.info("local authentication cancelled.")
                return .cancel
            case .passcodeNotSet:
                Logger.error("local authentication error: passcodeNotSet.")
                return .failure(error: ScreenLock.ErrorMessage.passcodeNotSet)
            case .touchIDNotAvailable:
                Logger.error("local authentication error: touchIDNotAvailable.")
                return .failure(error: ScreenLock.ErrorMessage.authenticationNotAvailable)
            case .touchIDNotEnrolled:
                Logger.error("local authentication error: touchIDNotEnrolled.")
                return .failure(error: ScreenLock.ErrorMessage.authenticationNotEnrolled)
            case .touchIDLockout:
                Logger.error("local authentication error: touchIDLockout.")
                return .failure(error: DeviceAuthenticationErrorMessage.lockout)
            case .invalidContext:
                owsFailDebug("context not valid.")
                return .unexpectedFailure(error: defaultErrorDescription)
            case .notInteractive:
                owsFailDebug("context not interactive.")
                return .unexpectedFailure(error: defaultErrorDescription)
            case .companionNotAvailable:
                owsFailDebug("companion device not available.")
                return .unexpectedFailure(error: defaultErrorDescription)
            @unknown default:
                owsFailDebug("Unexpected enum value.")
                return .unexpectedFailure(error: defaultErrorDescription)
            }
        }
        return .failure(error: defaultErrorDescription)
    }

    private func authenticationError(errorDescription: String) -> Error {
        return OWSError(
            error: .localAuthenticationError,
            description: errorDescription,
            isRetryable: false,
        )
    }
}

// MARK: - Mandatory independent application password

public final class AppPasswordLock {
    public enum VerificationResult: Equatable {
        case success
        case invalid(remainingAttemptsBeforeDelay: Int)
        case delayed(until: Date)
        case notConfigured
    }

    public static let shared = AppPasswordLock()

    private enum Constants {
        static let service = "org.signal.private.app-password.v1"
        static let salt = "salt"
        static let verifier = "verifier"
        static let biometricEnabled = "biometric-enabled"
        static let biometricDomainState = "biometric-domain-state"
        static let failureState = "failure-state"
        static let iterations: UInt32 = 310_000
        static let minimumLength = 8
        static let attemptsBeforeDelay = 5
        static let maximumDelay: TimeInterval = 60 * 60
    }

    private struct FailureState: Codable {
        var count: Int
        var delayedUntil: Date?
    }

    private let keychain = KeychainStorageImpl(isUsingProductionService: TSConstants.isUsingProductionService)
    private let lock = NSLock()

    private init() {}

    public var isConfigured: Bool {
        (try? keychain.dataValue(service: Constants.service, key: Constants.verifier)) != nil
    }

    public var isBiometricUnlockEnabled: Bool {
        guard isConfigured else { return false }
        guard (try? keychain.dataValue(service: Constants.service, key: Constants.biometricEnabled)) == Data([1]) else {
            return false
        }
        return biometricDomainStateIsCurrent()
    }

    public func setPassword(_ password: String, enableBiometrics: Bool) throws {
        guard password.count >= Constants.minimumLength else {
            throw OWSAssertionError("Application password must contain at least eight characters")
        }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 16, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw KeychainError.unknownError(status)
        }
        let verifier = try Self.derive(password: password, salt: salt)
        try keychain.setDataValue(salt, service: Constants.service, key: Constants.salt)
        try keychain.setDataValue(verifier, service: Constants.service, key: Constants.verifier)
        if enableBiometrics {
            do {
                try setBiometricUnlockEnabled(true)
            } catch {
                Logger.warn("Biometric unlock could not be enabled; application password remains active")
                try setBiometricUnlockEnabled(false)
            }
        } else {
            try setBiometricUnlockEnabled(false)
        }
        try resetFailures()
        ScreenLock.shared.setIsScreenLockEnabled(true)
        ScreenLock.shared.setScreenLockTimeout(0)
    }

    public func verify(_ password: String, now: Date = Date()) -> VerificationResult {
        lock.lock()
        defer { lock.unlock() }

        guard
            let salt = try? keychain.dataValue(service: Constants.service, key: Constants.salt),
            let storedVerifier = try? keychain.dataValue(service: Constants.service, key: Constants.verifier)
        else {
            return .notConfigured
        }

        var failureState = loadFailureState()
        if let delayedUntil = failureState.delayedUntil, delayedUntil > now {
            return .delayed(until: delayedUntil)
        }

        guard let candidate = try? Self.derive(password: password, salt: salt) else {
            return .invalid(remainingAttemptsBeforeDelay: 0)
        }
        if candidate.ows_constantTimeIsEqual(to: storedVerifier) {
            try? resetFailures()
            return .success
        }

        failureState.count += 1
        let attemptsInWindow = failureState.count % Constants.attemptsBeforeDelay
        if attemptsInWindow == 0 {
            let delayRound = max(0, failureState.count / Constants.attemptsBeforeDelay - 1)
            let delay = min(Constants.maximumDelay, 30 * pow(2, Double(delayRound)))
            failureState.delayedUntil = now.addingTimeInterval(delay)
        } else {
            failureState.delayedUntil = nil
        }
        saveFailureState(failureState)
        if let delayedUntil = failureState.delayedUntil {
            return .delayed(until: delayedUntil)
        }
        return .invalid(remainingAttemptsBeforeDelay: Constants.attemptsBeforeDelay - attemptsInWindow)
    }

    public func setBiometricUnlockEnabled(_ enabled: Bool) throws {
        if enabled {
            let context = DeviceOwnerAuthenticationType.localAuthenticationContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
                throw error ?? OWSAssertionError("Biometric authentication is unavailable")
            }
            try keychain.setDataValue(Data([1]), service: Constants.service, key: Constants.biometricEnabled)
            if let domainState = context.evaluatedPolicyDomainState {
                try keychain.setDataValue(domainState, service: Constants.service, key: Constants.biometricDomainState)
            }
        } else {
            try keychain.setDataValue(Data([0]), service: Constants.service, key: Constants.biometricEnabled)
            try? keychain.removeValue(service: Constants.service, key: Constants.biometricDomainState)
        }
    }

    public func clearLocalCredential() throws {
        for key in [
            Constants.salt,
            Constants.verifier,
            Constants.biometricEnabled,
            Constants.biometricDomainState,
            Constants.failureState,
        ] {
            try keychain.removeValue(service: Constants.service, key: key)
        }
    }

    private func biometricDomainStateIsCurrent() -> Bool {
        let context = DeviceOwnerAuthenticationType.localAuthenticationContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return false }
        guard
            let currentState = context.evaluatedPolicyDomainState,
            let storedState = try? keychain.dataValue(service: Constants.service, key: Constants.biometricDomainState)
        else { return false }
        return currentState.ows_constantTimeIsEqual(to: storedState)
    }

    private func loadFailureState() -> FailureState {
        guard
            let data = try? keychain.dataValue(service: Constants.service, key: Constants.failureState),
            let state = try? JSONDecoder().decode(FailureState.self, from: data)
        else { return FailureState(count: 0, delayedUntil: nil) }
        return state
    }

    private func saveFailureState(_ state: FailureState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? keychain.setDataValue(data, service: Constants.service, key: Constants.failureState)
    }

    private func resetFailures() throws {
        try keychain.removeValue(service: Constants.service, key: Constants.failureState)
    }

    private static func derive(password: String, salt: Data) throws -> Data {
        var output = Data(count: 32)
        let normalizedPassword = password.precomposedStringWithCompatibilityMapping
        let passwordLength = normalizedPassword.lengthOfBytes(using: .utf8)
        let outputLength = output.count
        let result = normalizedPassword.withCString { passwordBytes in
            output.withUnsafeMutableBytes { outputBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes,
                        passwordLength,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        Constants.iterations,
                        outputBytes.bindMemory(to: UInt8.self).baseAddress,
                        outputLength,
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw OWSAssertionError("Unable to derive application password verifier")
        }
        return output
    }
}

// MARK: Error Messages

extension ScreenLock {
    private enum ErrorMessage {
        static let authenticationNotAvailable = OWSLocalizedString(
            "SCREEN_LOCK_ERROR_LOCAL_AUTHENTICATION_NOT_AVAILABLE",
            comment: "Indicates that Touch ID/Face ID/Phone Passcode are not available on this device.",
        )
        static let authenticationNotEnrolled = OWSLocalizedString(
            "SCREEN_LOCK_ERROR_LOCAL_AUTHENTICATION_NOT_ENROLLED",
            comment: "Indicates that Touch ID/Face ID/Phone Passcode is not configured on this device.",
        )
        static let passcodeNotSet = OWSLocalizedString(
            "SCREEN_LOCK_ERROR_LOCAL_AUTHENTICATION_PASSCODE_NOT_SET",
            comment: "Indicates that Touch ID/Face ID/Phone Passcode passcode is not set.",
        )
    }
}

public enum DeviceAuthenticationErrorMessage {
    public static let errorSheetTitle = OWSLocalizedString(
        "SCREEN_LOCK_UNLOCK_FAILED",
        comment: "Title for alert indicating that screen lock could not be unlocked.",
    )

    public static let unknownError = OWSLocalizedString(
        "SCREEN_LOCK_ENABLE_UNKNOWN_ERROR",
        comment: "Indicates that an unknown error occurred while using Touch ID/Face ID/Phone Passcode.",
    )

    public static let lockout = OWSLocalizedString(
        "SCREEN_LOCK_ERROR_LOCAL_AUTHENTICATION_LOCKOUT",
        comment: "Indicates that Touch ID/Face ID/Phone Passcode is 'locked out' on this device due to authentication failures.",
    )
    public static let authenticationFailed = OWSLocalizedString(
        "SCREEN_LOCK_ERROR_LOCAL_AUTHENTICATION_FAILED",
        comment: "Indicates that Touch ID/Face ID/Phone Passcode authentication failed.",
    )
}
