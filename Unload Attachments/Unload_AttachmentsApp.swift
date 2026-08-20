import SwiftUI
import AppKit
import ServiceManagement

@main
struct Unload_AttachmentsApp: App {
    @State private var monitor = MailMonitor()

    var body: some Scene {
        MenuBarExtra("Unload Attachments", systemImage: "tray.and.arrow.down") {
            MenuContentView(monitor: monitor)
        }

        Settings {
            AccountSettingsView()
        }
    }
}

struct MenuContentView: View {
    @Bindable var monitor: MailMonitor

    @AppStorage(SettingsKeys.pollInterval) private var pollInterval = 30.0
    @AppStorage(SettingsKeys.folderScheme) private var folderScheme = FolderScheme.byYear.rawValue
    @AppStorage(SettingsKeys.flagProcessedMessages) private var flagProcessedMessages = true
    @AppStorage(SettingsKeys.originalsPolicy) private var originalsPolicy = OriginalMessagePolicy.archive.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Monitor for New Mail", isOn: $monitor.isMonitoring)

        Button("Process Inbox Now") {
            Task { await monitor.processNow() }
        }
        .disabled(monitor.isProcessing)

        Divider()

        if monitor.activity.isEmpty {
            Text("No attachments unloaded yet")
        } else {
            ForEach(monitor.activity.prefix(5)) { entry in
                Text("\(entry.date.formatted(date: .omitted, time: .shortened)) — \(entry.text)")
            }
        }

        Divider()

        Picker("Check Every", selection: $pollInterval) {
            Text("15 seconds").tag(15.0)
            Text("30 seconds").tag(30.0)
            Text("1 minute").tag(60.0)
            Text("5 minutes").tag(300.0)
        }

        Picker("Organize Files", selection: $folderScheme) {
            ForEach(FolderScheme.allCases) { scheme in
                Text(scheme.label).tag(scheme.rawValue)
            }
        }

        Toggle("Flag Processed Emails", isOn: $flagProcessedMessages)

        Picker("Originals", selection: $originalsPolicy) {
            ForEach(OriginalMessagePolicy.allCases) { policy in
                Text(policy.label).tag(policy.rawValue)
            }
        }

        Button("Open Save Folder") {
            _ = try? AttachmentUnloader.ensureFoldersExist()
            NSWorkspace.shared.open(AttachmentUnloader.parentFolder)
        }

        Button("Choose Save Folder…") {
            chooseParentFolder()
        }

        Divider()

        SettingsLink {
            Text("Mail Account…")
        }

        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }

        Divider()

        Button("Quit Unload Attachments") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func chooseParentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Attachments will be saved into year or type subfolders of the chosen folder."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: SettingsKeys.parentFolderOverride)
            _ = try? AttachmentUnloader.ensureFoldersExist()
        }
    }
}
