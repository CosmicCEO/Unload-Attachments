import SwiftUI
import AppKit
import ServiceManagement

@main
struct Unload_AttachmentsApp: App {
    @State private var monitor = MailMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(monitor: monitor)
        } label: {
            MenuBarIcon(badged: monitor.unseenCount > 0)
        }

        Settings {
            AccountSettingsView()
        }
    }
}

/// Menu bar icon with an optional green "new activity" dot. The badged
/// variant must be a non-template image: the menu bar renders template
/// images monochrome, which would turn the dot gray.
struct MenuBarIcon: View {
    let badged: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: badged ? Self.badgedImage(dark: colorScheme == .dark) : Self.plainImage)
    }

    private static let plainImage: NSImage = {
        let image = NSImage(systemSymbolName: "tray.and.arrow.down",
                            accessibilityDescription: "Unload Attachments")!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    private static func badgedImage(dark: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 17)
        let glyphColor: NSColor = dark ? .white : .black
        let image = NSImage(size: size, flipped: false) { rect in
            if let symbol = NSImage(systemSymbolName: "tray.and.arrow.down",
                                    accessibilityDescription: "Unload Attachments — new files")?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                        .applying(.init(paletteColors: [glyphColor]))) {
                symbol.draw(in: NSRect(x: 0, y: 0, width: 17, height: 15))
            }
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 7.5, y: rect.maxY - 7.5, width: 7, height: 7)).fill()
            return true
        }
        image.isTemplate = false
        return image
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
            // Menu-style content is instantiated on each open, so this fires
            // exactly when the user opens the menu — clearing the green dot.
            .onAppear { monitor.markSeen() }

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
