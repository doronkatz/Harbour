//
//  PortainerStore.swift
//  Harbour
//
//  Created by royal on 23/07/2022.
//

import Foundation
import os.log
import CoreData
import PortainerKit
import KeychainKit

// MARK: - PortainerStore

/// Main store for Portainer-related data.
public final class PortainerStore: ObservableObject {

	/// Singleton for `PortainerStore`
	static let shared = PortainerStore()

	// MARK: Private properties

	// swiftlint:disable:next force_unwrapping
	private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "PortainerStore")
	private let keychain = Keychain(accessGroup: Bundle.main.groupIdentifier)

	private let portainer: Portainer

	// MARK: Public properties

	/// Currently selected server URL
	public var serverURL: URL? {
		portainer.url
	}

	/// URLs with stored tokens
	public var savedURLs: [URL] {
		(try? keychain.getURLs()) ?? []
	}

	/// Task for `PortainerStore` setup
	public private(set) var setupTask: Task<Void, Never>?

	/// Task for `endpoints` refresh
	public private(set) var endpointsTask: Task<[Endpoint], Error>?

	/// Task for `containers` refresh
	public private(set) var containersTask: Task<[Container], Error>?

	/// Is `PortainerStore` setup?
	@Published private(set) var isSetup = false

	/// Currently selected endpoint's ID
	@Published private(set) var selectedEndpointID: Endpoint.ID? = Preferences.shared.selectedEndpointID {
		didSet { onSelectedEndpointIDChange(selectedEndpointID) }
	}

	/// Endpoints
	@Published private(set) var endpoints: [Endpoint] = [] {
		didSet { onEndpointsChange(endpoints) }
	}

	/// Containers of `selectedEndpoint`
	@Published private(set) var containers: [Container] = [] {
		didSet { onContainersChange(containers) }
	}

	// MARK: init

	private init() {
		portainer = Portainer()
		portainer.session.configuration.shouldUseExtendedBackgroundIdleMode = true
		portainer.session.configuration.sessionSendsLaunchEvents = true

		logger.debug("Initialized, loading stored containers... [\(String.debugInfo(), privacy: .public)]")
		self.isSetup = setupIfStored()
		setupTask = Task { @MainActor in
			let storedContainers = loadStoredContainers()
			if containers.isEmpty {
				self.containers = storedContainers
			}

			setupTask?.cancel()
		}
	}

	// MARK: Public Functions

	@Sendable @MainActor
	public func login(url: URL, token: String) async throws {
		logger.info("Setting up, URL: \(url.absoluteString, privacy: .sensitive(mask: .hash))... [\(String.debugInfo(), privacy: .public)]")

		do {
			isSetup = false

			portainer.setup(url: url, token: token)

			logger.debug("Getting endpoints for setup... [\(String.debugInfo(), privacy: .public)]")

			let endpointsTask = refreshEndpoints()
			_ = try await endpointsTask.value

//			let endpoints = try await portainer.fetchEndpoints()
//			logger.debug("Got \(endpoints.count, privacy: .public) endpoints. [\(String.debugInfo(), privacy: .public)]")
//			self.endpoints = endpoints

			isSetup = true

			Preferences.shared.selectedServer = url.absoluteString

			do {
				try keychain.saveToken(for: url, token: token)
			} catch {
				logger.error("Unable to save token to Keychain: \(error.localizedDescription, privacy: .public) [\(String.debugInfo(), privacy: .public)]")
			}

			logger.debug("Setup with URL: \"\(url.absoluteString, privacy: .sensitive)\" sucessfully! [\(String.debugInfo(), privacy: .public)]")
		} catch {
			logger.error("Failed to setup: \(error, privacy: .public) [\(String.debugInfo(), privacy: .public)]")
			throw error
		}
	}

	@MainActor
	public func selectEndpoint(_ endpoint: Endpoint?) {
		logger.info("Selected endpoint: \"\(endpoint?.name ?? "<none>", privacy: .sensitive)\" (\(endpoint?.id.description ?? "<none>")) [\(String.debugInfo(), privacy: .public)]")
		self.selectedEndpointID = endpoint?.id

		if endpoint != nil {
			refreshContainers()
		} else {
			containersTask?.cancel()
			containersTask = Task {
				containers = []
				containersTask?.cancel()
				return []
			}
		}
	}

	@Sendable
	public func inspectContainer(_ containerID: Container.ID) async throws -> ContainerDetails {
		logger.debug("Getting details for containerID: \"\(containerID, privacy: .public)\"... [\(String.debugInfo(), privacy: .public)]")
		do {
			let (portainer, endpointID) = try getPortainerAndEndpoint()
			let details = try await portainer.inspectContainer(containerID, endpointID: endpointID)
			logger.debug("Got details for containerID: \(containerID, privacy: .public). [\(String.debugInfo(), privacy: .public)]")
			return details
		} catch {
			logger.error("Failed to get container details: \(error, privacy: .public) [\(String.debugInfo(), privacy: .public)]")
			throw error
		}
	}

}

// MARK: - PortainerStore+Refresh

extension PortainerStore {

	@discardableResult @MainActor
	/// Refreshes endpoints and containers, storing the task and handling errors.
	/// Used as user-accessible method of refreshing central data.
	/// - Parameters:
	///   - errorHandler: `SceneState.ErrorHandler` used to notify the user of errors
	/// - Returns: `Task<Void, Error>` of refresh
	func refresh(errorHandler: SceneState.ErrorHandler? = nil, _debugInfo: String = .debugInfo()) -> Task<Void, Error> {
		let task = Task {
			do {
				await setupTask?.value

				let endpointsTask = refreshEndpoints(errorHandler: errorHandler, _debugInfo: _debugInfo)
				_ = try await endpointsTask.value
				if selectedEndpointID != nil {
					let containersTask = refreshContainers(errorHandler: errorHandler, _debugInfo: _debugInfo)
					_ = try await containersTask.value
				}
			} catch {
				errorHandler?(error, _debugInfo)
				throw error
			}
		}
		return task
	}

	@discardableResult @MainActor
	/// Refreshes endpoints, storing the task and handling errors.
	/// Used as user-accessible method of refreshing central data.
	/// - Parameters:
	///   - errorHandler: `SceneState.ErrorHandler` used to notify the user of errors
	/// - Returns: `Task<[Endpoint], Error>` of refresh
	func refreshEndpoints(errorHandler: SceneState.ErrorHandler? = nil, _debugInfo: String = .debugInfo()) -> Task<[Endpoint], Error> {
		endpointsTask?.cancel()
		let task: Task<[Endpoint], Error> = Task {
			do {
				let endpoints = try await getEndpoints()
				self.endpoints = endpoints
				endpointsTask?.cancel()
				return endpoints
			} catch {
				if Task.isCancelled { return self.endpoints }
				errorHandler?(error, _debugInfo)
				throw error
			}
		}
		endpointsTask = task
		return task
	}

	@discardableResult @MainActor
	/// Refreshes containers, storing the task and handling errors.
	/// Used as user-accessible method of refreshing central data.
	/// - Parameters:
	///   - errorHandler: `SceneState.ErrorHandler` used to notify the user of errors
	/// - Returns: `Task<[Container], Error>` of refresh
	func refreshContainers(errorHandler: SceneState.ErrorHandler? = nil, _debugInfo: String = .debugInfo()) -> Task<[Container], Error> {
		containersTask?.cancel()
		let task: Task<[Container], Error> = Task {
			do {
				let containers = try await getContainers()
				self.containers = containers
				containersTask?.cancel()
				return containers
			} catch {
				if Task.isCancelled { return self.containers }
				errorHandler?(error, _debugInfo)
				throw error
			}
		}
		containersTask = task
		return task
	}

}

// MARK: - PortainerStore+Private

private extension PortainerStore {

	@Sendable
	func getEndpoints() async throws -> [Endpoint] {
		logger.debug("Getting endpoints... [\(String.debugInfo(), privacy: .public)]")
		do {
			let endpoints = try await portainer.fetchEndpoints()
			logger.debug("Got \(endpoints.count, privacy: .public) endpoints. [\(String.debugInfo(), privacy: .public)]")
			return endpoints.sorted()
		} catch {
			logger.error("Failed to get endpoints: \(error, privacy: .public) [\(String.debugInfo(), privacy: .public)]")
			throw error
		}
	}

	@Sendable
	func getContainers() async throws -> [Container] {
		logger.debug("Getting containers... [\(String.debugInfo(), privacy: .public)]")
		do {
			let (portainer, endpointID) = try getPortainerAndEndpoint()
			let containers = try await portainer.fetchContainers(for: endpointID)
			logger.debug("Got \(containers.count, privacy: .public) containers. [\(String.debugInfo(), privacy: .public)]")
			return containers.sorted()
		} catch {
			logger.error("Failed to get containers: \(error, privacy: .public) [\(String.debugInfo(), privacy: .public)]")
			throw error
		}
	}

}

// MARK: - PortainerStore+Helpers

private extension PortainerStore {

	/// Checks if `portainer` is setup, unwraps `selectedEndpoint`, returns both, or throws an error if there's none.
	/// - Returns: Unwrapped `(Portainer, Endpoint.ID)`
	func getPortainerAndEndpoint() throws -> (Portainer, Endpoint.ID) {
		guard portainer.isSetup else {
			throw PortainerError.notSetup
		}
		guard let selectedEndpointID else {
			throw PortainerError.noSelectedEndpoint
		}
		return (portainer, selectedEndpointID)
	}

}

// MARK: - PortainerStore+OnDidChange

private extension PortainerStore {

	func onSelectedEndpointIDChange(_ selectedEndpointID: Endpoint.ID?) {
		Preferences.shared.selectedEndpointID = selectedEndpointID
	}

	func onEndpointsChange(_ endpoints: [Endpoint]) {
		if endpoints.isEmpty {
			containers = []
			selectedEndpointID = nil
		} else if endpoints.count == 1 {
			selectedEndpointID = endpoints.first?.id
		} else {
			let storedEndpointID = Preferences.shared.selectedEndpointID
			if endpoints.contains(where: { $0.id == storedEndpointID }) {
				selectedEndpointID = storedEndpointID
			}
		}
	}

	func onContainersChange(_ containers: [Container]) {
		storeContainers(containers)
	}

}

// MARK: - PortainerStore+Persistence

private extension PortainerStore {

	/// Loads authorization token for saved server and initializes `Portainer` with it.
	func setupIfStored() -> Bool {
		logger.debug("Looking for token... [\(String.debugInfo(), privacy: .public)]")
		do {
			guard let selectedServer = Preferences.shared.selectedServer,
				  let selectedServerURL = URL(string: selectedServer) else {
				logger.debug("No selectedServer. [\(String.debugInfo(), privacy: .public)]")
				return false
			}

			let token = try keychain.getToken(for: selectedServerURL)
			portainer.setup(url: selectedServerURL, token: token)

			logger.info("Got token for URL: \"\(selectedServerURL.absoluteString, privacy: .sensitive)\" :) [\(String.debugInfo(), privacy: .public)]")
			return true
		} catch {
			logger.warning("Failed to load token: \(error.localizedDescription, privacy: .public) [\(String.debugInfo(), privacy: .public)]")
			return false
		}
	}

	/// Stores containers to CoreData store.
	/// - Parameter containers: Containers to store
	func storeContainers(_ containers: [Container]) {
		logger.debug("Saving \(containers.count, privacy: .public) containers... [\(String.debugInfo(), privacy: .public)]")

		do {
			let context = PersistenceController.shared.backgroundContext

			let fetchRequest: NSFetchRequest<NSFetchRequestResult> = StoredContainer.fetchRequest()

			let newContainersIDs = containers.map(\.id)
			fetchRequest.predicate = NSPredicate(format: "NOT (id IN %@)", newContainersIDs)

			let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
			_ = try? context.execute(deleteRequest)

			containers.forEach { container in
				let storedContainer = StoredContainer(context: context)
				storedContainer.id = container.id
				storedContainer.name = container.displayName
				storedContainer.lastState = container.state?.rawValue
			}

			let saved = try context.saveIfNeeded()
			logger.info("Inserted \(self.containers.count, privacy: .public) containers, needed to save: \(saved, privacy: .public). [\(String.debugInfo(), privacy: .public)]")
		} catch {
			logger.error("Failed to store containers: \(error, privacy: .public) [\(String.debugInfo(), privacy: .public)]")
		}
	}

	/// Fetches stored containers and returns them.
	/// - Returns: Mapped [Container] from CoreData store.
	func loadStoredContainers() -> [Container] {
		logger.debug("Loading stored containers... [\(String.debugInfo(), privacy: .public)]")

		do {
			let context = PersistenceController.shared.backgroundContext
			let fetchRequest = StoredContainer.fetchRequest()
			let storedContainers = try context.fetch(fetchRequest)
			let containers = storedContainers
				.map {
					let names: [String]?
					if let name = $0.name {
						names = [name]
					} else {
						names = nil
					}
					return Container(id: $0.id ?? "", names: names, state: ContainerState(rawValue: $0.lastState ?? ""))
				}
				.sorted()

			logger.info("Got \(containers.count, privacy: .public) containers. [\(String.debugInfo(), privacy: .public)]")
			return containers
		} catch {
			logger.warning("Failed to fetch stored containers: \(error, privacy: .public) [\(String.debugInfo(), privacy: .public)]")
			return []
		}
	}

}
