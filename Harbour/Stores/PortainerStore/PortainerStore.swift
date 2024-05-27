//
//  PortainerStore.swift
//  Harbour
//
//  Created by royal on 23/07/2022.
//  Copyright © 2023 shameful. All rights reserved.
//

import Combine
import CommonFoundation
import CommonOSLog
import KeychainKit
import OSLog
import PortainerKit
import SwiftData

// MARK: - PortainerStore

/// Main store for Portainer-related data.
public final class PortainerStore: ObservableObject, @unchecked Sendable {

	/// Singleton for `PortainerStore`
	static let shared = PortainerStore()

	// MARK: Private properties

	internal let logger = Logger(.custom(PortainerStore.self))
	internal let keychain = Keychain.shared
	internal let preferences = Preferences.shared
	internal let portainer: PortainerClient

	// MARK: Public properties

	/// Currently selected server URL
	var serverURL: URL? {
		portainer.serverURL
	}

	/// URLs with stored tokens
	var savedURLs: [URL] {
		(try? keychain.getSavedURLs()) ?? []
	}

	/// Persistence model context
	var modelContext: ModelContext?

	/// Task for global refresh
	var refreshTask: Task<Void, Error>?

	/// Task for `endpoints` refresh
	var endpointsTask: Task<[Endpoint], Error>?

	/// Task for `containers` refresh
	var containersTask: Task<[Container], Error>?

	/// Task for `stacks` refresh
	var stacksTask: Task<[Stack], Error>?

	/// Is `PortainerStore` setup?
	@Published
	var isSetup = false

	/// Currently selected endpoint's ID
	@Published
	var selectedEndpoint: Endpoint? {
		didSet { onSelectedEndpointChange(selectedEndpoint) }
	}

	/// Endpoints
	@Published
	var endpoints: [Endpoint] = []

	/// Containers
	@Published
	var containers: [Container] = []

	@Published
	var stacks: [Stack] = []

	@Published
	var attachedContainer: AttachedContainer?

	@Published
	var removedContainerIDs: Set<Container.ID> = []

	@Published
	var loadingStackIDs: Set<Stack.ID> = []

	@Published
	var removedStackIDs: Set<Stack.ID> = []

	var isRefreshing: Bool {
		!(refreshTask?.isCancelled ?? true) || !(endpointsTask?.isCancelled ?? true) || !(containersTask?.isCancelled ?? true) || !(stacksTask?.isCancelled ?? true)
	}

	// MARK: init

	/// Initializes `PortainerStore` with provided ModelContext and URLSession configuration.
	/// - Parameter urlSessionConfiguration: `URLSessionConfiguration`, `.app` if none
	init(urlSessionConfiguration: URLSessionConfiguration = .app) {
//		urlSessionConfiguration.shouldUseExtendedBackgroundIdleMode = true
//		urlSessionConfiguration.sessionSendsLaunchEvents = true
		self.portainer = PortainerClient(urlSessionConfiguration: urlSessionConfiguration)

		do {
			let container = try ModelContainer.default()
			self.modelContext = ModelContext(container)
		} catch {
			logger.warning("Failed to create `ModelContainer`!")
		}
	}
}

// MARK: PortainerStore+State

public extension PortainerStore {
	/// Sets up Portainer with provided credentials.
	/// - Parameters:
	///   - url: Server URL
	///   - token: Authorization token (if `nil`, it's searched in the keychain)
	///   - saveToken: Should the token be saved to the keychain?
	///   - checkAuth: Should we check authorization state?
	@MainActor
	func setup(url: URL, token: String? = nil, saveToken: Bool = true) throws {
		logger.notice("Setting up, URL: \"\(url.absoluteString, privacy: .sensitive(mask: .hash))\"...")

		do {
			let _token = try (token ?? keychain.getString(for: url))
			portainer.serverURL = url
			portainer.token = _token

			preferences.selectedServer = url.absoluteString

			if saveToken {
				do {
					try keychain.setString(_token, for: url, itemDescription: Keychain.tokenItemDescription)
				} catch {
					logger.error("Unable to save token to Keychain: \(error, privacy: .public)")
				}
			}

			isSetup = true

//			logger.info("Setup with URL: \"\(url.absoluteString, privacy: .sensitive(mask: .hash))\" sucessfully!")
		} catch {
			logger.error("Failed to setup: \(error, privacy: .public)")
			throw error
		}
	}

	@MainActor
	/// Sets up PortainerStore after init.
	func setupInitially() {
		if self.endpoints.isEmpty || self.endpoints.contains(where: \._isStored), let storedEndpoints = fetchStoredEndpoints() {
			self.endpoints = storedEndpoints

			if self.selectedEndpoint == nil {
				self.selectedEndpoint = storedEndpoints.first { $0.id == preferences.selectedEndpointID }
			}
		}

		if self.containers.isEmpty || self.containers.contains(where: \._isStored), let storedContainers = fetchStoredContainers() {
			self.containers = storedContainers
		}

		if self.stacks.isEmpty || self.stacks.contains(where: \._isStored), let storedStacks = fetchStoredStacks() {
			self.stacks = storedStacks
		}

		if let (url, token) = getStoredCredentials() {
			try? setup(url: url, token: token, saveToken: false)
		} else {
			Task { @MainActor in
				endpoints = []
				containers = []
			}
		}
	}

	/// Switches server to provided `serverURL`.
	/// - Parameter serverURL: Server URL to switch to
	@MainActor
	func switchServer(to serverURL: URL) throws {
		logger.notice("Switching to \"\(serverURL.absoluteString, privacy: .public)\"")

		do {
			reset()
			try setup(url: serverURL, saveToken: false)

			preferences.selectedServer = serverURL.absoluteString
			isSetup = true

			logger.notice("Switched successfully!")
		} catch {
			logger.error("Failed to switch: \(error, privacy: .public)")
			throw error
		}
	}

	/// Removes authorization data from Keychain for the provided server URL.
	/// - Parameter serverURL: Server URL to remove data for
	func removeServer(_ serverURL: URL) throws {
		logger.notice("Removing token for url: \"\(serverURL.absoluteString, privacy: .sensitive(mask: .hash))\"")
		do {
			try keychain.removeContent(for: serverURL)
//			logger.info("Removed token successfully!")
		} catch {
			logger.error("Failed to remove token: \(error, privacy: .public)")
			throw error
		}
	}

	/// Resets the `PortainerStore` state.
	@MainActor
	func reset() {
		logger.notice("Resetting state")

		isSetup = false

		portainer.serverURL = nil
		portainer.token = nil

		preferences.selectedEndpointID = nil
		preferences.selectedServer = nil

		selectedEndpoint = nil

		refreshTask?.cancel()

		endpointsTask?.cancel()
		setEndpoints(nil)

		containersTask?.cancel()
		setContainers(nil)

		stacksTask?.cancel()
		setStacks(nil)

		attachedContainer = nil
	}
}

// MARK: - PortainerStore+Set

extension PortainerStore {
	/// Selects the currently active endpoint.
	/// - Parameter endpoint: Endpoint to switch to
	@MainActor
	func setSelectedEndpoint(_ endpoint: Endpoint?) {
		logger.notice("Selected endpoint: \"\(endpoint?.name ?? "<none>", privacy: .sensitive(mask: .hash))\" (\(endpoint?.id.description ?? "<none>"))")
		self.selectedEndpoint = endpoint

		if endpoint != nil {
			refreshContainers()
		} else {
			containersTask?.cancel()
			setEndpoints(nil)
			setContainers(nil)
		}
	}

	@MainActor
	func setEndpoints(_ endpoints: [Endpoint]?) {
		self.endpoints = endpoints ?? []

		if let endpoints {
			if endpoints.count == 1 {
				selectedEndpoint = endpoints.first
			} else {
				selectedEndpoint = endpoints.first { $0.id == preferences.selectedEndpointID }
			}
		} else {
			containers = []
			selectedEndpoint = nil
		}

		storeEndpoints(endpoints)
	}

	@MainActor
	func setContainers(_ containers: [Container]?) {
		self.containers = containers ?? []
		storeContainers(containers)
	}

	@MainActor
	func setStacks(_ stacks: [Stack]?) {
		self.stacks = stacks ?? []
		storeStacks(stacks)
	}
}

// MARK: - PortainerStore+OnDidChange

extension PortainerStore {
	func onSelectedEndpointChange(_ selectedEndpoint: Endpoint?) {
		Task { @MainActor in
			guard let selectedEndpoint else {
				preferences.selectedEndpointID = nil
				return
			}
			preferences.selectedEndpointID = selectedEndpoint.id
		}
	}
}
