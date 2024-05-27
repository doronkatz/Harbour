//
//  SceneDelegate+Errors.swift
//  Harbour
//
//  Created by royal on 19/12/2022.
//  Copyright © 2023 shameful. All rights reserved.
//

import CommonFoundation
import CommonHaptics
import Foundation

extension SceneDelegate {
	@MainActor
	func handleError(_ error: Error, showIndicator: Bool = true) {
		guard !error.isCancellationError else {
			logger.debug("Cancelled error: \(error, privacy: .public)")
			return
		}

//		logger.error("Error: \(error, privacy: .public)")

		Haptics.generateIfEnabled(.error)
		if showIndicator {
			presentIndicator(.error(error))
		}
	}
}
