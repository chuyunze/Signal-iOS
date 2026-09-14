//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

final class HelpViewController: OWSTableViewController2 {

    override func viewDidLoad() {
        super.viewDidLoad()
        updateTableContents()
    }

    private func updateTableContents() {
        let helpTitle = CommonStrings.help

        let contents = OWSTableContents(title: helpTitle)

        // Self-host debrand: support center, contact support, debug log submission,
        // legal terms and the Signal nonprofit footer are hidden for test users.
        // Only the app version remains.
        let aboutSection = OWSTableSection()
        aboutSection.add(.copyableItem(
            label: OWSLocalizedString("SETTINGS_VERSION", comment: ""),
            value: AppVersionImpl.shared.prettyAppVersion,
        ))
        contents.add(aboutSection)

        self.contents = contents
    }
}

// MARK: -

#if DEBUG

@available(iOS 17, *)
#Preview {
    return HelpViewController()
}

#endif
