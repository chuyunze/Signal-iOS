//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Security

/// A simplified version of AFNetworking's AFSecurityPolicy.
public struct HttpSecurityPolicy {
    /// 自建服务器: 信任所有证书(仅用于开发测试场景)。
    /// 对应 Android BlacklistingTrustManager.TrustAllManager。
    /// 生产部署应改回 signalCaPinned 并嵌入自签 CA 证书。
    public static let signalCaPinned: HttpSecurityPolicy = .init(pinnedCertificates: [Certificates.load("signal-messenger", extension: "cer")], trustAll: true)
    public static let systemDefault: HttpSecurityPolicy = .init()

    private let pinnedCertificates: [SecCertificate]?
    private let trustAll: Bool

    public init(pinnedCertificates: [SecCertificate]? = nil, trustAll: Bool = false) {
        self.pinnedCertificates = pinnedCertificates
        self.trustAll = trustAll
    }

    public func evaluate(serverTrust: SecTrust, domain: String?) -> Bool {
        // 自建服务器: 跳过证书校验,信任所有证书
        if trustAll {
            return true
        }

        let policies = [SecPolicyCreateSSL(true, domain as CFString?)]

        guard SecTrustSetPolicies(serverTrust, policies as CFArray) == errSecSuccess else {
            Logger.error("the trust policy could not be set")
            return false
        }

        // use the default anchors if none were prvided in pinnedCertificates
        if let pinnedCertificates, !pinnedCertificates.isEmpty {
            guard SecTrustSetAnchorCertificates(serverTrust, pinnedCertificates as CFArray) == errSecSuccess else {
                Logger.error("the anchor certificates could not be set")
                return false
            }
        }

        return Self.isValid(serverTrust: serverTrust)
    }

    private static func isValid(serverTrust: SecTrust) -> Bool {
        guard SecTrustEvaluateWithError(serverTrust, nil) else {
            return false
        }
        var result: SecTrustResultType = .otherError // initialize to a value that would fail if SecTrustGetTrustResult doesn't overwrite it
        guard SecTrustGetTrustResult(serverTrust, &result) == errSecSuccess else {
            return false
        }
        return result == .unspecified || result == .proceed
    }
}
