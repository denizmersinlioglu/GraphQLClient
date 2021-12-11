import Combine
import Foundation
import SwiftyJSON

// MARK: - JSONEncodable

protocol JSONEncodable: Equatable {
	init?(_ json: JSON)
}

// MARK: - Serializable

protocol Serializable {
	func serialize() -> Data?
	func toDict() -> [String: Any]
}

extension Serializable where Self: Encodable {
	func serialize() -> Data? {
		let encoder = JSONEncoder()
		return try? encoder.encode(self)
	}

	func toDict() -> [String: Any] {
		do {
			guard let serialized = serialize() else { return [:] }
			return try JSONSerialization.jsonObject(with: serialized, options: []) as? [String: Any] ?? [:]
		} catch {
			print("Can't convert to dictionary")
			return [:]
		}
	}
}

// MARK: - LocalDatabaseObject

protocol LocalDatabaseObject: Identifiable & Serializable & JSONEncodable {}

// MARK: - LocalDatabaseMappable

protocol LocalDatabaseMappable {
	associatedtype DatabaseObject: LocalDatabaseObject
	var databaseObject: DatabaseObject { get }
	static func map(_ databaseObject: DatabaseObject) -> Self
}

// MARK: - DatabaseNotifierProtocol

protocol DatabaseNotifierProtocol {
	typealias Notification<T: Identifiable> = DatabaseNotifier.Notification<T>

	func post<T: LocalDatabaseObject>(
		_ type: T.Type,
		_ notification: Notification<T>
	)

	func register<T: LocalDatabaseObject, U: LocalDatabaseMappable>(
		_ type: U.Type,
		map: @escaping (_ databaseObject: T) -> U
	) -> AnyPublisher<Notification<U>, Never>
}

extension DatabaseNotifierProtocol {

	func register<T: LocalDatabaseMappable>(
		_ type: T.Type
	) -> AnyPublisher<Notification<T>, Never> {
		register(T.self, map: T.map).eraseToAnyPublisher()
	}

}

// MARK: - LocalDatabaseObservationToken

protocol LocalDatabaseObservationToken {
	func invalidate()
}

// MARK: - Notification.Name + Extensions

extension Notification.Name {
	static let localDatabaseObjectUpdate = Notification.Name("local_database_object_update")
}

// MARK: - DatabaseNotifier

final class DatabaseNotifier: DatabaseNotifierProtocol {

	// MARK: Properties

	private lazy var notificationCenter = NotificationCenter.default

	// MARK: Observation

	func post<T: LocalDatabaseObject>(
		_ type: T.Type,
		_ notification: Notification<T>
	) {
		notificationCenter.post(
			name: .localDatabaseObjectUpdate,
			object: notification,
			userInfo: nil
		)
	}

	func register<T: LocalDatabaseObject, U: LocalDatabaseMappable>(
		_ type: U.Type,
		map: @escaping (_ databaseObject: T) -> U
	) -> AnyPublisher<Notification<U>, Never> {
		NotificationCenter.Publisher(center: .default, name: .localDatabaseObjectUpdate, object: nil)
			.compactMap { $0.object as? Notification<T> }
			.compactMap { notification -> Notification<U>? in
				switch notification {
				case let .delete(id):
					if let id = id as? U.ID { return .delete(id) }
					else { return nil }
				case let .update(old, new):
					return .update(map(old), map(new))
				case let .add(new):
					return .add(map(new))
				}
			}
			.eraseToAnyPublisher()
	}

}

extension DatabaseNotifier {

	enum Notification<T: Identifiable> {
		case delete(_ id: T.ID)
		case update(_ old: T, _ new: T)
		case add(_ data: T)
	}

}

// MARK: - Item

struct Item: Identifiable, JSONEncodable, Codable {

	typealias ID = String

	// MARK: Properties

	var id: ID = ""
	var title: String = ""

	// MARK: Life Cycle

	init(id: ID, title: String) {
		self.id = id
		self.title = title
	}

	init?(_ json: JSON) {
		guard json["id"].string != nil else { return nil }
		id = json["id"].stringValue
		title = json["title"].stringValue
	}

	init(_ item: ItemDatabaseObject) {
		id = item.id
		title = item.title
	}

}

// MARK: - ItemDatabaseObject

struct ItemDatabaseObject: LocalDatabaseObject, Codable {

	// MARK: Properties

	var id: String = ""
	var title: String = ""

	// MARK: Life Cycle

	init?(_ json: JSON) {
		guard json["id"].string != nil else { return nil }
		id = json["id"].stringValue
		title = json["title"].stringValue
	}

	init(_ item: Item) {
		id = item.id
		title = item.title
	}

}

// MARK: - Item + LocalDatabaseMappable

extension Item: LocalDatabaseMappable {

	var databaseObject: ItemDatabaseObject {
		.init(self)
	}

	static func map(_ databaseObject: ItemDatabaseObject) -> Item {
		.init(databaseObject)
	}

}

// MARK: - LocalDatabase

protocol LocalDatabase {
	var notifier: DatabaseNotifierProtocol { get }

	func get<T: LocalDatabaseObject>(_ type: T.Type) -> [T]
	func get<T: LocalDatabaseObject, Key>(_ type: T.Type, primaryKey: Key) -> T?

	func add<T: LocalDatabaseObject>(_ objects: [T])
	func add<T: LocalDatabaseObject>(_ object: T)

	func delete<T: LocalDatabaseObject>(_ object: T)
	func delete<T: LocalDatabaseObject>(objects: [T])

	func flush()
	func log<T: LocalDatabaseObject>(type: T.Type)
}

// MARK: - UserDefaultsLocalDatabase

final class UserDefaultsLocalDatabase: LocalDatabase {

	// MARK: Properties

	let userDefaults = UserDefaults.standard
	let notifier: DatabaseNotifierProtocol = DatabaseNotifier()

	static let databaseKey = "local_database"
	static let normalizedKey = "local_database_normalized"

	private var databaseKey = UserDefaultsLocalDatabase.databaseKey
	private var normalizedKey = UserDefaultsLocalDatabase.normalizedKey

	private var storableEntityTypes: [String] {
		[
			String(describing: Item.self)
		]
	}

	// MARK: Read

	func get<T: LocalDatabaseObject>(_ type: T.Type = T.self) -> [T] {
		let key = databaseKey + "_" + String(describing: type)
		if let table = userDefaults.dictionary(forKey: key) as? [T.ID: [String: Any]] {
			return table.values.compactMap { T(JSON($0)) }
		} else {
			return []
		}
	}

	func get<T: LocalDatabaseObject, Key>(
		_ type: T.Type = T.self,
		primaryKey: Key
	) -> T? {
		let key = databaseKey + "_" + String(describing: type)
		if let table = userDefaults.dictionary(forKey: key) as? [T.ID: [String: Any]],
		   let primaryKey = primaryKey as? T.ID,
		   let data = table[primaryKey]
		{
			return T(JSON(data))
		} else {
			return nil
		}
	}

	// MARK: Add

	func add<T: LocalDatabaseObject>(_ objects: [T]) {
		let typeKey = String(describing: T.self)
		let key = databaseKey + "_" + typeKey
		var table = userDefaults.dictionary(forKey: key) as? [T.ID: [String: Any]] ?? [:]
		var oldMap: [T.ID: T] = [:]
		objects.forEach {
			oldMap[$0.id] = T(JSON(table[$0.id] ?? [:]))
			table[$0.id] = $0.toDict()
			userDefaults.setValue($0.toDict(), forKey: "\(normalizedKey).\(typeKey).\($0.id)")
			if let old = oldMap[$0.id] { notifier.post(T.self, .update(old, $0)) }
			else { notifier.post(T.self, .add($0)) }
		}
		userDefaults.setValue(table, forKey: key)
	}

	func add<T: LocalDatabaseObject>(_ object: T) {
		let typeKey = String(describing: T.self)
		let key = databaseKey + "_" + typeKey
		var table = userDefaults.dictionary(forKey: key) as? [T.ID: [String: Any]] ?? [:]
		let old = T(JSON(table[object.id] ?? [:]))
		table[object.id] = object.toDict()
		userDefaults.setValue(object.toDict(), forKey: "\(normalizedKey).\(typeKey).\(object.id)")
		userDefaults.setValue(table, forKey: key)

		if let old = old { notifier.post(T.self, .update(old, object)) }
		else { notifier.post(T.self, .add(object)) }
	}

	// MARK: Delete

	func delete<T: LocalDatabaseObject>(_ object: T) {
		let typeKey = String(describing: T.self)
		let key = databaseKey + "_" + typeKey
		var table = userDefaults.dictionary(forKey: key) as? [T.ID: [String: Any]] ?? [:]

		table[object.id] = nil
		userDefaults.removeObject(forKey: "\(normalizedKey).\(typeKey).\(object.id)")
		userDefaults.setValue(table, forKey: key)
		notifier.post(T.self, .delete(object.id))
	}

	func delete<T: LocalDatabaseObject>(objects: [T]) {
		let typeKey = String(describing: T.self)
		let key = databaseKey + "_" + typeKey
		var table = userDefaults.dictionary(forKey: key) as? [T.ID: [String: Any]] ?? [:]

		objects.forEach {
			table[$0.id] = nil
			userDefaults.removeObject(forKey: "\(normalizedKey).\(typeKey).\($0.id)")
		}
		userDefaults.setValue(table, forKey: key)
		objects.forEach { notifier.post(T.self, .delete($0.id)) }
	}

	// MARK: Helpers

	func flush() {
		UserDefaults.standard.dictionaryRepresentation().keys
			.filter { $0.contains(databaseKey) }
			.forEach { userDefaults.setValue([:], forKey: $0) }
	}

	func log<T: LocalDatabaseObject>(type: T.Type) {
		let typeKey = String(describing: T.self)
		let key = databaseKey + "_" + typeKey
		let table = userDefaults.dictionary(forKey: key) as? [T.ID: [String: Any]] ?? [:]
		let tableJSON = JSON(table)

		if let data = try? tableJSON.rawData(),
		   let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
		{
			let databasePath = directory.appendingPathComponent("user_defaults_\(typeKey).json")
			do { try data.write(to: databasePath) }
			catch { print(error) }
			print(databasePath)
		}

		print(JSON(table))
	}
}

// MARK: - Main

var bag: Set<AnyCancellable> = []
let localDatabase: LocalDatabase = UserDefaultsLocalDatabase()
let notifier: DatabaseNotifierProtocol = localDatabase.notifier

localDatabase.flush()
notifier.register(Item.self)
	.receive(on: DispatchQueue.main)
	.sink { item in print(item) }
	.store(in: &bag)

let item1 = Item(id: "1", title: "item1")
let item2 = Item(id: "2", title: "item2")
localDatabase.add(item1.databaseObject)
localDatabase.add(item2.databaseObject)

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
	let _item2 = Item(id: "2", title: "item2_updated")
	localDatabase.add(_item2.databaseObject)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
	let _item1 = Item(id: "1", title: "item1_updated")
	localDatabase.add(_item1.databaseObject)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
	if let databaseObject = localDatabase.get(ItemDatabaseObject.self, primaryKey: "1") {
		localDatabase.delete(databaseObject)
	}
}
