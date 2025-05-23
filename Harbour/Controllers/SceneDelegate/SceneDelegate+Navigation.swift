//
//  SceneDelegate+Navigation.swift
//  Harbour
//
//  Created by royal on 26/03/2024.
//  Copyright © 2024 shameful. All rights reserved.
//

import Navigation
import SwiftUI

// MARK: - SceneDelegate+DeeplinkHandlable

extension SceneDelegate: DeeplinkHandlable {
	@MainActor
	func resetSheets() {
		isLandingSheetPresented = false
		isSettingsSheetPresented = false
		isCreateStackSheetPresented = false
		isContainerChangesSheetPresented = false
	}

	@MainActor
	func navigate<each Destination: NavigableItem>(to tab: ViewTab, with navigationItems: repeat each Destination, removingPrevious removePreviousItems: Bool = true) {
		activeTab = tab

		switch tab {
		case .containers:
			if removePreviousItems {
				navigationState.containers.removeLast(navigationState.containers.count)
			}

			for navigationItem in repeat each navigationItems {
				navigationState.containers.append(navigationItem)
			}
		case .stacks:
			if removePreviousItems {
				navigationState.stacks.removeLast(navigationState.stacks.count)
			}

			for navigationItem in repeat each navigationItems {
				navigationState.stacks.append(navigationItem)
			}
		}
	}

	@MainActor
	func handleURL(_ url: URL) {
		logger.notice("Opening from URL: \"\(url.absoluteString)\"")

		guard let destination = Deeplink.destination(from: url) else {
			logger.warning("Failed to create Deeplink.Destination from URL: \"\(url.absoluteString)\"")
			return
		}

		resetSheets()

		// swiftlint:disable force_cast
		switch destination.host {
		case .containers:
			navigate(to: .containers)
		case .containerDetails:
			typealias DestinationView = ContainerDetailsView
			navigate(to: .containers)
			DestinationView.handleNavigation(&navigationState.containers, with: destination as! DestinationView.DeeplinkDestination)
		case .stacks:
			navigate(to: .stacks)
		case .stackDetails:
			typealias DestinationView = StackDetailsView
			navigate(to: .stacks)
			DestinationView.handleNavigation(&navigationState.stacks, with: destination as! DestinationView.DeeplinkDestination)
		case .settings:
			isSettingsSheetPresented = true
		}
		// swiftlint:enable force_cast
	}
}

// MARK: - SceneDelegate+NavigationState

extension SceneDelegate {
	struct NavigationState {
		var containers = NavigationPath()
		var stacks = NavigationPath()
	}
}
