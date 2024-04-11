//
//  SceneState+Errors.swift
//  Harbour
//
//  Created by royal on 19/12/2022.
//  Copyright © 2023 shameful. All rights reserved.
//

import CommonFoundation
import CommonHaptics
import Foundation

extension SceneState {
	@MainActor
	func handleError(_ error: Error, _debugInfo: String = ._debugInfo()) {
		guard !error.isCancellationError else {
			logger.debug("Cancelled error: \(error, privacy: .public)")
			return
		}

		logger.error("Error: \(error, privacy: .public)")

		Haptics.generateIfEnabled(.error)
		presentIndicator(.error(error))
	}
}
