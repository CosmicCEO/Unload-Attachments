import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class MailMonitor {

    struct ActivityEntry: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
    }

    var isMonitoring: Bool {
        didSet {
            UserDefaults.standard.set(isMonitoring, forKey: SettingsKeys.monitoringEnabled)
            if isMonitoring { startPolling() } else { stopPolling() }
        }
    }

    private(set) var activity: [ActivityEntry] = []
    private(set) var isProcessing = false
    private var pollTask: Task<Void, Never>?
    private var lastLoggedError: String?

    init() {
        isMonitoring = UserDefaults.standard.object(forKey: SettingsKeys.monitoringEnabled) as? Bool ?? true

        do {
            try AttachmentUnloader.ensureFoldersExist()
        } catch {
            log("Could not create save folder: \(error.localizedDescription)")
        }

        if isMonitoring { startPolling() }
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(AppSettings.pollInterval))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func pollOnce() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        do {
            let results = try await MailWorker.shared.checkNewMail()
            lastLoggedError = nil
            for result in results {
                var text = "\(result.savedCount) attachment(s) unloaded from “\(result.subject)”"
                if result.failedCount > 0 { text += " (\(result.failedCount) failed)" }
                log(text)
                for file in result.savedFiles {
                    log("↳ \(file.lastPathComponent)")
                }
                for reason in result.failureReasons {
                    log("⚠ \(reason)")
                }
                notify(about: result)
            }
        } catch {
            // Log connection/configuration problems once, not every poll.
            let text = error.localizedDescription
            if text != lastLoggedError {
                log("⚠ \(text)")
                lastLoggedError = text
            }
        }
    }

    // MARK: - Feedback

    private func log(_ text: String) {
        activity.insert(ActivityEntry(date: .now, text: text), at: 0)
        if activity.count > 20 { activity.removeLast(activity.count - 20) }
    }

    private func notify(about result: ProcessResult) {
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "Unload Attachments"
            content.subtitle = result.subject
            content.body = "\(result.savedCount) attachment(s) saved"
                + (result.failedCount > 0 ? ", \(result.failedCount) failed" : "")
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                                        content: content, trigger: nil))
        }
    }
}
