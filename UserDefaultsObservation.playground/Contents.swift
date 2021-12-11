import Foundation

// MARK: - LocalDatabaseObservationToken

protocol LocalDatabaseObservationToken {
	func invalidate()
}

extension UserDefaults {

	func observe<T: Any>(key: String, callback: @escaping (T) -> Void) -> Observable {
		let result = KeyValueObserver<T>.observeNew(object: self, keyPath: key) {
			callback($0)
		}
		return result
	}

}

// MARK: - KeyValueObserver

final class KeyValueObserver<ValueType: Any>: NSObject, Observable {

	typealias ChangeCallback = (KeyValueObserverResult<ValueType>) -> Void

	// MARK: Properties

	private var context = 0 // Value don't really matter. Only address is important.
	private var object: NSObject
	private var keyPath: String
	private var callback: ChangeCallback

	var isSuspended = false

	// MARK: Life Cycle

	init(
		object: NSObject,
		keyPath: String,
		options: NSKeyValueObservingOptions = .new,
		callback: @escaping ChangeCallback
	) {
		self.object = object
		self.keyPath = keyPath
		self.callback = callback
		super.init()
		object.addObserver(self, forKeyPath: keyPath, options: options, context: &context)
	}

	deinit {
		invalidate()
	}

	// MARK: Observation

	func invalidate() {
		object.removeObserver(self, forKeyPath: keyPath, context: &context)
	}

	// swiftlint:disable block_based_kvo
	override func observeValue(
		forKeyPath keyPath: String?,
		of object: Any?,
		change: [NSKeyValueChangeKey: Any]?,
		context: UnsafeMutableRawPointer?
	) {
		if context == &self.context, keyPath == self.keyPath {
			if !isSuspended,
			   let change = change,
			   let result = KeyValueObserverResult<ValueType>(change: change)
			{
				callback(result)
			}
		} else {
			super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
		}
	}

	// swiftlint:enable block_based_kvo

	static func observeNew<T>(
		object: NSObject, keyPath: String,
		callback: @escaping (T) -> Void
	) -> Observable {
		let observer = KeyValueObserver<T>(object: object, keyPath: keyPath, options: .new) { result in
			if let value = result.valueNew {
				callback(value)
			}
		}
		return observer
	}
}

// MARK: - KeyValueObserverResult

struct KeyValueObserverResult<T: Any> {

	// MARK: Properties

	// Stored
	private(set) var change: [NSKeyValueChangeKey: Any]
	private(set) var kind: NSKeyValueChange

	// Computed
	var valueNew: T? {
		change[.newKey] as? T
	}

	var valueOld: T? {
		change[.oldKey] as? T
	}

	var isPrior: Bool {
		(change[.notificationIsPriorKey] as? NSNumber)?.boolValue ?? false
	}

	var indexes: NSIndexSet? {
		change[.indexesKey] as? NSIndexSet
	}

	// MARK: Life Cycle

	init?(change: [NSKeyValueChangeKey: Any]) {
		self.change = change
		guard
			let changeKindNumberValue = change[.kindKey] as? NSNumber,
			let changeKindEnumValue = NSKeyValueChange(rawValue: changeKindNumberValue.uintValue) else
		{
			return nil
		}
		kind = changeKindEnumValue
	}
}

// MARK: - Observable

protocol Observable: LocalDatabaseObservationToken {
	var isSuspended: Bool { get set }
	func invalidate()
}

extension Array where Element == Observable {

	func suspend() {
		forEach {
			var observer = $0
			observer.isSuspended = true
		}
	}

	func resume() {
		forEach {
			var observer = $0
			observer.isSuspended = false
		}
	}
}

let token = UserDefaults.standard.observe(key: "demo_value") { value in
	print(value)
}

UserDefaults.standard.setValue("Hello world", forKey: "demo_value")
UserDefaults.standard.setValue("Hello world 2", forKey: "demo_value")
UserDefaults.standard.setValue("Hello world 3", forKey: "demo_value")
UserDefaults.standard.setValue("Hello world 4", forKey: "demo_value")

DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
	UserDefaults.standard.setValue("Hello world 5", forKey: "demo_value")
	token.invalidate()
}

DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
	UserDefaults.standard.setValue("Hello world 6", forKey: "demo_value")
}
