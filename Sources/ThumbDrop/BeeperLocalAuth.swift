import Foundation
import SQLite3

/// Reads Beeper Desktop's local account database to recover the Matrix access token.
/// This is the third-party-blessed path: Beeper's own `bbctl` tool exposes this same
/// `--desktop-data-dir` flag and reads the SQLite at `~/Library/Application Support/BeeperTexts/account.db`.
///
/// Schema (per Beeper Desktop):
///   account(user_id TEXT PRIMARY KEY NOT NULL, device_id TEXT NOT NULL,
///           access_token TEXT NOT NULL, homeserver TEXT NOT NULL)
enum BeeperLocalAuth {
    struct Account: Equatable {
        let userId: String
        let deviceId: String
        let accessToken: String
        let homeserver: String
        let sourcePath: URL
    }

    /// Standard Beeper Desktop dir + the `BEEPER_PROFILE`-suffixed variants.
    private static var candidateDataDirs: [URL] {
        let support = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        var dirs: [URL] = [support.appendingPathComponent("BeeperTexts", isDirectory: true)]
        if let entries = try? FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: [.isDirectoryKey]) {
            for url in entries {
                let name = url.lastPathComponent
                if name.hasPrefix("BeeperTexts-") {
                    dirs.append(url)
                }
            }
        }
        return dirs
    }

    static func discoverAccounts() -> [Account] {
        var found: [Account] = []
        for dir in candidateDataDirs {
            let dbPath = dir.appendingPathComponent("account.db")
            guard FileManager.default.fileExists(atPath: dbPath.path) else { continue }
            if let acc = readAccount(at: dbPath) {
                found.append(acc)
            }
        }
        return found
    }

    private static func readAccount(at dbPath: URL) -> Account? {
        var db: OpaquePointer?
        // Open read-only; immutable=1 also avoids a stale -wal/-shm interfering.
        let uri = "file:\(dbPath.path)?mode=ro&immutable=1"
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(uri, &db, openFlags, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT user_id, device_id, access_token, homeserver FROM account LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        func col(_ i: Int32) -> String {
            guard let p = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: p)
        }
        let userId = col(0)
        let deviceId = col(1)
        let token = col(2)
        let homeserver = col(3)
        guard !userId.isEmpty, !token.isEmpty else { return nil }
        return Account(
            userId: userId,
            deviceId: deviceId,
            accessToken: token,
            homeserver: homeserver,
            sourcePath: dbPath
        )
    }
}
