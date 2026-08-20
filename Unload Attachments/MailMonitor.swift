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

    init() {
        // Only mail received after the first launch is ever processed.
        if UserDefaults.standard.object(forKey: SettingsKeys.lastProcessedDate) == nil {
            UserDefaults.standard.set(Date().timeIntervalSinceReferenceDate,
                                      forKey: SettingsKeys.lastProcessedDate)
        }
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
        guard MailBridge.isMailRunning else { return }
        isProcessing = true
        defer { isProcessing = false }

        // Look back a little past the checkpoint so a message that arrived
        // while a previous poll was running is not missed; the processed-ID
        // list prevents double handling.
        let since = lastProcessedDate.addingTimeInterval(-120)
        let messages = MailBridge.inboxMessages(receivedAfter: since)

        for message in messages {
            guard !processedMessageIDs.contains(message.messageID) else { continue }

            let hasOffice = message.attachments.contains {
                AttachmentUnloader.officeExtensions.contains($0.fileExtension)
            }
            if hasOffice {
                let result = await AttachmentUnloader.process(message)
                var text = "\(result.savedCount) attachment(s) unloaded from “\(result.subject)”"
                if result.failedCount > 0 { text += " (\(result.failedCount) failed)" }
                log(text)
                for reason in result.failureReasons {
                    log("⚠ \(reason)")
                }
                notify(about: result)
            }

            processedMessageIDs.append(message.messageID)
            if message.dateReceived > lastProcessedDate {
                lastProcessedDate = message.dateReceived
            }
        }
    }

    // MARK: - Checkpoint

    private var lastProcessedDate: Date {
        get { Date(timeIntervalSinceReferenceDate: UserDefaults.standard.double(forKey: SettingsKeys.lastProcessedDate)) }
        set { UserDefaults.standard.set(newValue.timeIntervalSinceReferenceDate, forKey: SettingsKeys.lastProcessedDate) }
    }

    private var processedMessageIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: SettingsKeys.processedMessageIDs) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(500)), forKey: SettingsKeys.processedMessageIDs) }
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
