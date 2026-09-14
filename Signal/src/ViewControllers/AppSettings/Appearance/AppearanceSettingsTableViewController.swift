//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

final class AppearanceSettingsTableViewController: OWSTableViewController2 {
    override func viewDidLoad() {
        super.viewDidLoad()

        title = OWSLocalizedString("SETTINGS_APPEARANCE_TITLE", comment: "The title for the appearance settings.")

        updateTableContents()
    }

    override func themeDidChange() {
        super.themeDidChange()

        updateTableContents()
    }

    private func updateTableContents() {
        let contents = OWSTableContents()

        let firstSection = OWSTableSection()
        firstSection.add(OWSTableItem.disclosureItem(
            withText: OWSLocalizedString(
                "SETTINGS_APPEARANCE_THEME_TITLE",
                comment: "The title for the theme section in the appearance settings.",
            ),
            accessoryText: ThemeSettingsTableViewController.currentThemeName,
        ) { [weak self] in
            guard let self else { return }
            let vc = ThemeSettingsTableViewController()
            self.navigationController?.pushViewController(vc, animated: true)
        })
        firstSection.add(OWSTableItem.disclosureItem(
            withText: OWSLocalizedString(
                "SETTINGS_ITEM_COLOR_AND_WALLPAPER",
                comment: "Label for settings view that allows user to change the chat color and wallpaper.",
            ),
        ) { [weak self] in
            guard let self else { return }
            let vc = ColorAndWallpaperSettingsViewController()
            self.navigationController?.pushViewController(vc, animated: true)
        })
        // Self-host debrand: official alternate app-icon picker hidden.
        contents.add(firstSection)

        // TODO iOS 13 – maybe expose the preferred language settings here to match android
        // It not longer seems to exist in iOS 13.1 so not sure if Apple got rid of it
        // or it has just temporarily been disabled.

        self.contents = contents
    }

}

