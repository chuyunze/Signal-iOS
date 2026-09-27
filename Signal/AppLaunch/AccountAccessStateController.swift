//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

@MainActor
final class AccountAccessStateController {
    static let shared = AccountAccessStateController()

    fileprivate enum Status: String, Codable {
        case active = "ACTIVE"
        case suspended = "SUSPENDED"
        case disabled = "DISABLED"
        case purged = "PURGED"
    }

    private struct StatusResponse: Decodable {
        let status: Status
        let version: UInt64
        let updatedAt: Date?
    }

    private weak var restrictedViewController: AccountRestrictedViewController?
    private var refreshTask: Task<Void, Never>?
    private var onReactivated: (@MainActor () -> Void)?
    private var onRestricted: (@MainActor () -> Void)?

    private static let cachedStatusKey = "AccountAccessStateController.cachedStatus"

    private init() {}

    func refresh(
        onRestricted: @escaping @MainActor () -> Void,
        onReactivated: @escaping @MainActor () -> Void,
    ) {
        self.onRestricted = onRestricted
        self.onReactivated = onReactivated

        if let cachedStatus, cachedStatus != .active {
            presentRestrictedState(cachedStatus)
            onRestricted()
        }

        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            var request = TSRequest(
                url: URL(string: "v1/accounts/status")!,
                method: "GET",
                parameters: [:],
            )
            request.auth = .identified(.implicit())

            do {
                let response = try await SSKEnvironment.shared.networkManagerRef.asyncRequest(
                    request,
                    retryPolicy: .doNotRetry,
                )
                guard response.responseStatusCode == 200 else { return }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let state = try decoder.decode(StatusResponse.self, from: response.responseBodyData ?? Data())
                apply(state: state)
            } catch {
                // Network failures and invalid credentials are not enough to conclude that
                // an account is restricted. Existing chat authentication handles those paths.
                Logger.warn("Unable to refresh account access state: \(error)")
            }
        }
    }

    private var cachedStatus: Status? {
        get {
            CurrentAppContext().appUserDefaults().string(forKey: Self.cachedStatusKey).flatMap(Status.init(rawValue:))
        }
        set {
            CurrentAppContext().appUserDefaults().set(newValue?.rawValue, forKey: Self.cachedStatusKey)
        }
    }

    private func apply(state: StatusResponse) {
        let wasRestricted = cachedStatus.map { $0 != .active } ?? false
        cachedStatus = state.status
        switch state.status {
        case .active:
            if let restrictedViewController {
                restrictedViewController.dismiss(animated: true)
                self.restrictedViewController = nil
            }
            if wasRestricted {
                onReactivated?()
            }
        case .suspended, .disabled, .purged:
            onRestricted?()
            presentRestrictedState(state.status)
        }
    }

    private func presentRestrictedState(_ status: Status) {
        if let restrictedViewController {
            restrictedViewController.update(status: status)
            return
        }
        guard let presentingViewController = CurrentAppContext().frontmostViewController() else { return }
        let controller = AccountRestrictedViewController(status: status) { [weak self] in
            guard
                let self,
                let onRestricted = self.onRestricted,
                let onReactivated = self.onReactivated
            else { return }
            self.refresh(onRestricted: onRestricted, onReactivated: onReactivated)
        }
        controller.modalPresentationStyle = .fullScreen
        controller.isModalInPresentation = true
        restrictedViewController = controller
        presentingViewController.present(controller, animated: true)
    }
}

@MainActor
private final class AccountRestrictedViewController: OWSViewController {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let retry: () -> Void

    init(status: AccountAccessStateController.Status, retry: @escaping () -> Void) {
        self.retry = retry
        super.init()
        update(status: status)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.background
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.textAlignment = .center
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        let retryButton = UIButton(
            configuration: .largePrimary(title: "重新检查账户状态"),
            primaryAction: UIAction { [retry] _ in retry() },
        )
        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel, retryButton])
        stack.axis = .vertical
        stack.spacing = 24
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    func update(status: AccountAccessStateController.Status) {
        switch status {
        case .suspended:
            titleLabel.text = "账户已暂停"
            detailLabel.text = "该账户暂时无法连接服务、发送或接收消息。账户身份和本机数据没有被删除。"
        case .disabled:
            titleLabel.text = "账户已停用"
            detailLabel.text = "该账户当前不可使用。重新启用后，Account ID、Recovery Key 和 Username 保持不变。"
        case .purged:
            titleLabel.text = "账户已删除"
            detailLabel.text = "该账户已经永久删除，不能重新启用。"
        case .active:
            break
        }
    }
}
