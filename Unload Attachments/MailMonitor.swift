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
    /// Attachments saved since the user last opened the menu (drives the
    /// green dot on the menu bar icon).
    private(set) var unseenCount = 0
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
                guard !Task.isCancelled else { break }
                // Prefer server push: IDLE suspends until new mail arrives
                // (re-issued within the 29-minute protocol limit). When push
                // isn't available, fall back to interval polling.
                let pushed = await MailWorker.shared.waitForNewMail(window: 25 * 60)
                if !pushed {
                    try? await Task.sleep(for: .seconds(AppSettings.pollInterval))
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        // Unblock a task suspended inside IDLE so it can observe cancellation.
        Task { await MailWorker.shared.wakeIdle() }
    }

    /// The user opened the menu — the green dot has served its purpose.
    func markSeen() {
        unseenCount = 0
    }

    /// Menu action: check immediately, whether the loop is idling or stopped.
    func processNow() async {
        if isMonitoring {
            await MailWorker.shared.wakeIdle()
            // If the loop was between polls rather than idling, run directly.
            if !isProcessing { await pollOnce() }
        } else {
            await pollOnce()
        }
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
                if result.savedCount > 0 { unseenCount += result.savedCount }
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
