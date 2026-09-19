import Foundation
import SwiftData

struct AudioHistoryFile: Equatable {
    let id: UUID
    let timestamp: Date
    let size: Int64
    let isProtected: Bool
}

enum AudioHistoryCleanupPlanner {
    static func deletionIDs(
        files: [AudioHistoryFile],
        now: Date,
        retentionDays: Int,
        maximumBytes: Int64
    ) -> Set<UUID> {
        let sorted = files.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
        let cutoff = now.addingTimeInterval(-TimeInterval(max(1, retentionDays) * 86_400))
        var deleted = Set(sorted.filter { !$0.isProtected && $0.timestamp < cutoff }.map(\.id))
        var retainedBytes = sorted.reduce(Int64(0)) { total, file in
            deleted.contains(file.id) ? total : total + max(0, file.size)
        }

        for file in sorted where retainedBytes > max(1, maximumBytes) {
            guard !file.isProtected, !deleted.contains(file.id) else { continue }
            deleted.insert(file.id)
            retainedBytes -= max(0, file.size)
        }
        return deleted
    }
}

/// A utility class that manages automatic cleanup of audio files while preserving transcript data
@MainActor
final class AudioCleanupManager {
    static let shared = AudioCleanupManager()

    private var cleanupTimer: Timer?
    private var modelContext: ModelContext?
    private let cleanupCheckInterval: TimeInterval = 86400  // Check once per day (in seconds)

    private init() {}

    /// Start the automatic cleanup schedule.
    func startAutomaticCleanup(modelContext: ModelContext) {
        // Cancel any existing timer
        cleanupTimer?.invalidate()
        self.modelContext = modelContext

        // Schedule regular cleanup
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: cleanupCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let modelContext = self.modelContext else { return }
                await self.runAutomaticCleanupIfNeeded(modelContext: modelContext)
            }
        }
    }

    /// Run automatic cleanup once if it is due. This is safe to call on app/window appear.
    func runAutomaticCleanupIfNeeded(modelContext: ModelContext) async {
        guard AudioHistorySettings.isEnabled,
            !UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled),
            shouldRunAutomaticCleanup()
        else {
            return
        }

        await performCleanup(modelContext: modelContext)
        UserDefaults.standard.set(Date(), forKey: CleanupSettingsKeys.lastAutomaticAudioCleanupDate)
    }

    /// Stop the automatic cleanup process
    func stopAutomaticCleanup() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        modelContext = nil
    }

    /// Get information about the files that would be cleaned up
    func getCleanupInfo(modelContext: ModelContext) async -> (
        fileCount: Int, totalSize: Int64, transcriptions: [Transcription]
    ) {
        do {
            return try { () throws -> (Int, Int64, [Transcription]) in
                let transcriptions = try modelContext.fetch(FetchDescriptor<Transcription>())
                var fileCount = 0
                var totalSize: Int64 = 0
                var available: [(transcription: Transcription, file: AudioHistoryFile)] = []

                for transcription in transcriptions {
                    if let urlString = transcription.audioFileURL,
                        let url = URL(string: urlString),
                        FileManager.default.fileExists(atPath: url.path)
                    {
                        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                            let fileSize = attributes[.size] as? Int64
                        {
                            available.append((
                                transcription,
                                AudioHistoryFile(
                                    id: transcription.id,
                                    timestamp: transcription.timestamp,
                                    size: fileSize,
                                    isProtected: transcription.transcriptionStatus == TranscriptionStatus.pending.rawValue
                                )
                            ))
                        }
                    }
                }

                let deletionIDs = AudioHistoryCleanupPlanner.deletionIDs(
                    files: available.map(\.file),
                    now: Date(),
                    retentionDays: AudioHistorySettings.retentionDays,
                    maximumBytes: AudioHistorySettings.maximumBytes
                )
                let eligibleTranscriptions = available.compactMap { entry in
                    deletionIDs.contains(entry.file.id) ? entry.transcription : nil
                }
                for entry in available where deletionIDs.contains(entry.file.id) {
                    fileCount += 1
                    totalSize += entry.file.size
                }

                return (fileCount, totalSize, eligibleTranscriptions)
            }()
        } catch {
            return (0, 0, [])
        }
    }

    /// Perform the cleanup operation
    private func performCleanup(modelContext: ModelContext) async {
        guard AudioHistorySettings.isEnabled else { return }

        do {
            try { () throws -> Void in
                let cleanupInfo = try cleanupCandidates(modelContext: modelContext)
                var deletedCount = 0

                for transcription in cleanupInfo.transcriptions {
                    if let urlString = transcription.audioFileURL,
                        let url = URL(string: urlString),
                        FileManager.default.fileExists(atPath: url.path)
                    {
                        do {
                            try FileManager.default.removeItem(at: url)
                            transcription.audioFileURL = nil
                            deletedCount += 1
                        } catch {
                            // Skip this file - don't update audioFileURL if deletion failed
                        }
                    }
                }

                if deletedCount > 0 {
                    try modelContext.save()
                }
            }()
        } catch {
            // Silently fail - cleanup is non-critical
        }
    }

    private func cleanupCandidates(modelContext: ModelContext) throws -> (
        fileCount: Int, totalSize: Int64, transcriptions: [Transcription]
    ) {
        let transcriptions = try modelContext.fetch(FetchDescriptor<Transcription>())
        var available: [(Transcription, AudioHistoryFile)] = []
        for transcription in transcriptions {
            guard let urlString = transcription.audioFileURL,
                let url = URL(string: urlString),
                FileManager.default.fileExists(atPath: url.path),
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                let fileSize = attributes[.size] as? Int64
            else { continue }
            available.append((
                transcription,
                AudioHistoryFile(
                    id: transcription.id,
                    timestamp: transcription.timestamp,
                    size: fileSize,
                    isProtected: transcription.transcriptionStatus == TranscriptionStatus.pending.rawValue
                )
            ))
        }
        let ids = AudioHistoryCleanupPlanner.deletionIDs(
            files: available.map(\.1),
            now: Date(),
            retentionDays: AudioHistorySettings.retentionDays,
            maximumBytes: AudioHistorySettings.maximumBytes
        )
        let selected = available.filter { ids.contains($0.1.id) }
        return (
            selected.count,
            selected.reduce(Int64(0)) { $0 + $1.1.size },
            selected.map(\.0)
        )
    }

    func getAllAudioInfo(modelContext: ModelContext) -> (
        fileCount: Int, totalSize: Int64, transcriptions: [Transcription]
    ) {
        let transcriptions = (try? modelContext.fetch(FetchDescriptor<Transcription>())) ?? []
        var selected: [Transcription] = []
        var totalSize: Int64 = 0
        for transcription in transcriptions where transcription.transcriptionStatus != TranscriptionStatus.pending.rawValue {
            guard let value = transcription.audioFileURL,
                let url = URL(string: value),
                FileManager.default.fileExists(atPath: url.path)
            else { continue }
            selected.append(transcription)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                let size = attributes[.size] as? Int64
            {
                totalSize += size
            }
        }
        return (selected.count, totalSize, selected)
    }

    /// Run cleanup manually - can be called from settings
    func runManualCleanup(modelContext: ModelContext) async {
        await performCleanup(modelContext: modelContext)
    }

    private func shouldRunAutomaticCleanup() -> Bool {
        guard
            let lastCleanupDate = UserDefaults.standard.object(
                forKey: CleanupSettingsKeys.lastAutomaticAudioCleanupDate) as? Date
        else {
            return true
        }

        return Date().timeIntervalSince(lastCleanupDate) >= cleanupCheckInterval
    }

    /// Run cleanup on the specified transcriptions
    func runCleanupForTranscriptions(modelContext: ModelContext, transcriptions: [Transcription]) async -> (
        deletedCount: Int, errorCount: Int
    ) {
        var deletedCount = 0
        var errorCount = 0

        for transcription in transcriptions {
            if let urlString = transcription.audioFileURL,
                let url = URL(string: urlString),
                FileManager.default.fileExists(atPath: url.path)
            {
                do {
                    try FileManager.default.removeItem(at: url)
                    transcription.audioFileURL = nil
                    deletedCount += 1
                } catch {
                    errorCount += 1
                }
            }
        }

        if deletedCount > 0 || errorCount > 0 {
            try? modelContext.save()
        }

        return (deletedCount, errorCount)
    }

    /// Format file size in human-readable form
    func formatFileSize(_ size: Int64) -> String {
        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.allowedUnits = [.useKB, .useMB, .useGB]
        byteCountFormatter.countStyle = .file
        return byteCountFormatter.string(fromByteCount: size)
    }
}
