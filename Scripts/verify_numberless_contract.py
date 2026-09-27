#!/usr/bin/env python3
"""Verify the source-level contract shared by Signal-iOS and Signal-Server.

This intentionally does not start either application. It catches accidental drift in
the small, security-sensitive protocol surface introduced for numberless accounts.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


def read(path: Path) -> str:
    if not path.is_file():
        raise AssertionError(f"missing source file: {path}")
    return path.read_text(encoding="utf-8")


def require(source: str, pattern: str, description: str) -> None:
    if re.search(pattern, source, re.MULTILINE | re.DOTALL) is None:
        raise AssertionError(description)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--server",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "Signal-Server",
        help="path to the Signal-Server checkout",
    )
    args = parser.parse_args()

    ios_root = Path(__file__).resolve().parents[1]
    server_root = args.server.resolve()

    request_factory = read(
        ios_root / "SignalServiceKit/Network/API/Requests/Registration/RegistrationRequestFactory.swift"
    )
    invitation_service = read(
        ios_root / "SignalServiceKit/Registration/Numberless/InvitationCredentialService.swift"
    )
    access_state = read(ios_root / "Signal/AppLaunch/AccountAccessStateController.swift")

    invitation_controller = read(
        server_root
        / "service/src/main/java/org/whispersystems/textsecuregcm/controllers/InvitationController.java"
    )
    registration_controller = read(
        server_root
        / "service/src/main/java/org/whispersystems/textsecuregcm/controllers/RegistrationController.java"
    )
    registration_request = read(
        server_root
        / "service/src/main/java/org/whispersystems/textsecuregcm/entities/RegistrationRequest.java"
    )
    status_controller = read(
        server_root
        / "service/src/main/java/org/whispersystems/textsecuregcm/controllers/AccountStatusController.java"
    )
    account_status = read(
        server_root
        / "service/src/main/java/org/whispersystems/textsecuregcm/storage/AccountStatus.java"
    )
    receipt_level = read(
        server_root
        / "service/src/main/java/org/whispersystems/textsecuregcm/subscriptions/ReceiptLevel.java"
    )

    checks = [
        (request_factory, r'URL\(string: "v1/invitations/claim"\)', "iOS invitation route drifted"),
        (invitation_controller, r'@Path\("/v1/invitations"\).*@Path\("/claim"\)', "server invitation route drifted"),
        (request_factory, r'"invitationCode"\s*:', "iOS invitationCode field is missing"),
        (request_factory, r'"receiptCredentialRequest"\s*:', "iOS receipt request field is missing"),
        (invitation_controller, r'record ClaimRequest\([^)]*String invitationCode[^)]*byte\[\] receiptCredentialRequest', "server invitation request fields drifted"),
        (request_factory, r'URL\(string: "v1/registration"\)', "iOS registration route drifted"),
        (registration_controller, r'@Path\("/v1/registration"\)', "server registration route drifted"),
        (request_factory, r'parameters\["receiptCredentialPresentation"\]', "iOS login receipt presentation is missing"),
        (request_factory, r'parameters\["recoveryPassword"\]', "iOS recovery password is missing"),
        (registration_request, r'byte\[\] recoveryPassword', "server recoveryPassword field is missing"),
        (registration_request, r'byte\[\] receiptCredentialPresentation', "server receipt presentation field is missing"),
        (access_state, r'URL\(string: "v1/accounts/status"\)', "iOS account-status route drifted"),
        (status_controller, r'@Path\("/v1/accounts/status"\)', "server account-status route drifted"),
        (invitation_service, r'loginReceiptLevel:\s*UInt64\s*=\s*300', "iOS LOGIN receipt level drifted"),
        (receipt_level, r'LOGIN\(300L\)', "server LOGIN receipt level drifted"),
    ]
    for source, pattern, description in checks:
        require(source, pattern, description)

    ios_statuses = set(re.findall(r'case\s+\w+\s*=\s*"(ACTIVE|SUSPENDED|DISABLED|PURGED)"', access_state))
    server_status_block = re.search(r'enum AccountStatus\s*\{(?P<body>.*?)\;', account_status, re.DOTALL)
    if server_status_block is None:
        raise AssertionError("cannot read server AccountStatus enum")
    server_statuses = set(re.findall(r'\b(ACTIVE|SUSPENDED|DISABLED|PURGED)\b', server_status_block.group("body")))
    expected_statuses = {"ACTIVE", "SUSPENDED", "DISABLED", "PURGED"}
    if ios_statuses != expected_statuses or server_statuses != expected_statuses:
        raise AssertionError(
            f"account status contract drifted: iOS={sorted(ios_statuses)}, server={sorted(server_statuses)}"
        )

    single_device_sources = [
        server_root / "service/src/main/java/org/whispersystems/textsecuregcm/auth/AccountAuthenticator.java",
        server_root / "service/src/main/java/org/whispersystems/textsecuregcm/controllers/DeviceController.java",
        server_root / "service/src/main/java/org/whispersystems/textsecuregcm/controllers/ProvisioningController.java",
    ]
    for path in single_device_sources:
        require(read(path), r'MULTI_DEVICE_ENABLED\s*=\s*false', f"single-device policy is not enforced in {path.name}")

    print("PASS: numberless registration contract is aligned across iOS and Server")
    print("  invitation claim: route, fields, LOGIN receipt level")
    print("  registration/recovery: route and credential fields")
    print("  account control: route and four-state enum")
    print("  device policy: authentication, device API, provisioning all deny multi-device")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
