import BarkVisorCore
import GRDB
import Vapor

struct AppDatabaseKey: StorageKey {
    typealias Value = AppDatabase
}

extension Vapor.Application {
    var database: AppDatabase {
        get {
            guard let db = storage[AppDatabaseKey.self] else {
                fatalError("AppDatabase not configured on application")
            }
            return db
        }
        set { storage[AppDatabaseKey.self] = newValue }
    }
}

extension Vapor.Request {
    var database: AppDatabase {
        application.database
    }
    var db: DatabasePool {
        database.pool
    }
}
