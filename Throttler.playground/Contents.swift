import Foundation

// MARK: - Throttler

final class Throttler {

	// MARK: Properties

	private var workItem = DispatchWorkItem(block: {})
	private var previousRun = Date.distantPast
	private let queue: DispatchQueue
	private let minimumDelay: TimeInterval

	// MARK: Life Cycle

	init(
		minimumDelay: TimeInterval,
		queue: DispatchQueue = DispatchQueue.main
	) {
		self.minimumDelay = minimumDelay
		self.queue = queue
	}

	// MARK: Methods

	func throttle(_ block: @escaping () -> Void) {
		workItem.cancel()
		workItem = DispatchWorkItem { [weak self] in
			self?.previousRun = Date()
			block()
		}
		let delay = previousRun.timeIntervalSinceNow > minimumDelay ? 0 : minimumDelay
		queue.asyncAfter(deadline: .now() + Double(delay), execute: workItem)
	}

}

// MARK: - Main

let throttler = Throttler(minimumDelay: 0.5, queue: .main)
throttler.throttle { print("1") }
throttler.throttle { print("2") }
throttler.throttle { print("3") }

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
	throttler.throttle { print("4") }
}
