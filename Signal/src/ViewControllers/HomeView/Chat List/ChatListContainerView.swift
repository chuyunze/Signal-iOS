//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

private import PureLayout
private import SignalServiceKit
import UIKit

final class ChatListContainerView: UIView {
    let tableView: CLVTableView

    /// Set an extra padding on both sides of the table view.
    /// This is used when chat list is displayed in split view controller's "sidebar".
    var tableViewHorizontalInset: CGFloat = 0 {
        didSet {
            guard oldValue != tableViewHorizontalInset else { return }
            tableViewHorizontalEdgeConstraints.forEach { $0.constant = tableViewHorizontalInset }
        }
    }

    private var tableViewHorizontalEdgeConstraints: [NSLayoutConstraint] = []

    init(tableView: CLVTableView, searchBar: UISearchBar) {
        searchBar.disableAiWritingTools()

        self.tableView = tableView
        super.init(frame: .zero)

        addSubview(tableView)
        tableView.autoPinHeight(toHeightOf: self)
        tableViewHorizontalEdgeConstraints = [
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: tableViewHorizontalInset),
            trailingAnchor.constraint(equalTo: tableView.trailingAnchor, constant: tableViewHorizontalInset),
        ]
        NSLayoutConstraint.activate(tableViewHorizontalEdgeConstraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
