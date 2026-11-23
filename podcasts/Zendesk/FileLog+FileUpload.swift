import AutomatticEncryptedLogs
import Foundation
import PocketCastsUtils
import SwiftUI

struct EventLoggingDataProvider: EventLoggingDataSource {
    let loggingEncryptionKey = ApiCredentials.loggingEncryptionKey
    let loggingAuthenticationToken = ApiCredentials.dotcomSecret
    let logUploadFile: URL?

    func logFilePath(forErrorLevel: EventLoggingErrorType, at date: Date) -> URL? {
        logUploadFile
    }
}

/// Lets a caller wait for a queued log upload to finish, keyed by the log's UUID.
///
/// An upload is registered with `expect` before it's queued, so a result that arrives before `wait` starts isn't lost.
/// Results for uploads nobody is expecting, such as a duplicate or one that arrives after the wait timed out, are dropped.
final class LogUploadWaiters: @unchecked Sendable {
    static let shared = LogUploadWaiters()

    private enum State {
        case expected
        case finished(succeeded: Bool)
        case waiting(CheckedContinuation<Bool, Never>)
    }

    private let lock = NSLock()
    private var uploads: [String: State] = [:]

    func expect(_ uuid: String) {
        lock.lock()
        uploads[uuid] = .expected
        lock.unlock()
    }

    func forget(_ uuid: String) {
        lock.lock()
        uploads[uuid] = nil
        lock.unlock()
    }

    /// Returns `true` once the upload finishes, or `false` if it fails, doesn't finish within `timeout`, or was never expected.
    func wait(for uuid: String, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            switch uploads[uuid] {
            case .finished(let succeeded):
                uploads[uuid] = nil
                lock.unlock()
                continuation.resume(returning: succeeded)
            case .expected:
                uploads[uuid] = .waiting(continuation)
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.complete(uuid, succeeded: false)
                }
            case .waiting, nil:
                lock.unlock()
                continuation.resume(returning: false)
            }
        }
    }

    func uploadFinished(_ uuid: String, succeeded: Bool) {
        complete(uuid, succeeded: succeeded)
    }

    private func complete(_ uuid: String, succeeded: Bool) {
        lock.lock()
        switch uploads[uuid] {
        case .expected:
            uploads[uuid] = .finished(succeeded: succeeded)
            lock.unlock()
        case .waiting(let continuation):
            uploads[uuid] = nil
            lock.unlock()
            continuation.resume(returning: succeeded)
        case .finished, nil:
            lock.unlock()
        }
    }
}

extension FileLog: @retroactive EventLoggingDelegate {
    static let genericErrorMessage = "No log file uploaded: Error generating logs"

    static let noWearableLogsAvailable = "No wearable logs were available"

    /// The refusal lives here, taking the key it will actually seal with, so a control can drive
    /// it with an unusable key without needing real credentials in the test build.
    static func assertUsableEncryptionKey(_ key: String) throws {
        guard LogUploadCredentials.isUsableEncryptionKey(key) else {
            FileLog.shared.addMessage("Log upload skipped: no usable log encryption key configured")
            throw LogError.logGenerationFailed
        }
    }

    fileprivate func queueFileUpload(_ filePath: String) throws -> String {
        let logFilePath = URL(fileURLWithPath: filePath)
        let dataProvider = EventLoggingDataProvider(logUploadFile: logFilePath)
        // Refuse before the encryptor's force-unwrap: an empty or wrong-length key would trap.
        try Self.assertUsableEncryptionKey(dataProvider.loggingEncryptionKey)
        let logFile = LogFile(url: logFilePath)
        LogUploadWaiters.shared.expect(logFile.uuid)
        do {
            let eventLogging = EventLogging(dataSource: dataProvider, delegate: self)
            try eventLogging.enqueueLogForUpload(log: logFile)
        } catch {
            LogUploadWaiters.shared.forget(logFile.uuid)
            addMessage("FileLog: failed to queue \(logFilePath.lastPathComponent) for upload: \(error)")
            throw LogError.logGenerationFailed
        }

        addMessage("FileLog: queued \(logFilePath.lastPathComponent) for upload as \(logFile.uuid)")
        return logFile.uuid
    }

    /// Queues the file for encrypted upload and waits for it to finish. Returns the log's UUID, or `nil` if it
    /// couldn't be queued, the upload failed, or it didn't finish within `timeout`.
    func uploadLog(atPath filePath: String, timeout: TimeInterval) async -> String? {
        guard let uuid = try? queueFileUpload(filePath) else {
            return nil
        }

        guard await LogUploadWaiters.shared.wait(for: uuid, timeout: timeout) else {
            addMessage("FileLog: log \(uuid) wasn't uploaded: the upload failed or took longer than \(Int(timeout))s")
            return nil
        }
        return uuid
    }

    /// Uploads the app's debug log and waits for it to finish, as `uploadLog(atPath:timeout:)`.
    func uploadDebugLog(timeout: TimeInterval) async -> String? {
        do {
            // Refuse before generating: merging the logs is work whose result would be discarded,
            // and it leaves the merged file behind for a build that can never upload it.
            try Self.assertUsableEncryptionKey(ApiCredentials.loggingEncryptionKey)
            return try queueFileUpload(try await logFileForUpload())
        } catch {
            addMessage("FileLog: failed to generate the log for upload: \(error)")
            return nil
        }
    }

    /// Writes the watchOS log to a file to be enqueued for upload, returning the path it was written
    /// to, or `nil` if the watch had no logs to give.
    func watchLogFileForUpload() async throws -> String? {
        guard let wearableLog = await WatchManager.shared.requestLogFile() else {
            return nil
        }

        let file = LogFilePaths.watchUploadLog
        do {
            try wearableLog.write(toFile: file, atomically: true, encoding: .utf8)
        } catch {
            throw LogError.logGenerationFailed
        }

        return file
    }

    /// Returns the watchOS log contents as a string, using the same flow as support uploads
    func watchLogFileAsString() async -> String? {
        await WatchManager.shared.requestLogFile()
    }

    public func encryptedWatchLogUUID() async -> String {
        do {
            // Same reason: do not ask the watch for its log if it cannot be uploaded.
            try Self.assertUsableEncryptionKey(ApiCredentials.loggingEncryptionKey)
            guard let filePath = try await watchLogFileForUpload() else {
                return Self.noWearableLogsAvailable
            }

            return try queueFileUpload(filePath)
        } catch {
            return FileLog.genericErrorMessage
        }
    }

    // MARK: - EventLoggingDelegate

    public var shouldUploadLogFiles: Bool {
        FileManager.default.fileExists(atPath: LogFilePaths.debugUploadLog) || FileManager.default.fileExists(atPath: LogFilePaths.watchUploadLog)
    }

    public func didFinishUploadingLog(_ log: LogFile) {
        addMessage("FileLog: uploaded log \(log.uuid)")
        LogUploadWaiters.shared.uploadFinished(log.uuid, succeeded: true)
        try? FileManager.default.removeItem(at: log.url)
    }

    public func uploadFailed(_ log: LogFile) {
        addMessage("FileLog: failed to upload log \(log.uuid)")
        LogUploadWaiters.shared.uploadFinished(log.uuid, succeeded: false)
        try? FileManager.default.removeItem(at: log.url)
    }

    public func logError(_ error: Error, userInfo: [String: Any]?) {
        addMessage("FileLog: log upload error: \(error)")
    }
}
