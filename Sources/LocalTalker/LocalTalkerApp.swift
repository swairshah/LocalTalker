import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct LocalTalkerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var conversationLoop: ConversationLoop!
    private var mainWindow: NSWindow?

    private var carbonEventHandler: EventHandlerRef?
    private var carbonStopHotKeyRef: EventHotKeyRef?
    private var carbonMuteHotKeyRef: EventHotKeyRef?
    private var carbonNewSessionHotKeyRef: EventHotKeyRef?
    private var carbonTTSHotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ProcessInfo.processInfo.disableAutomaticTermination("LocalTalker voice session active")

        // Set app icon from bundled .icns
        if let iconPath = Bundle.main.path(forResource: "LocalTalker", ofType: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOfFile: iconPath)
        } else {
            let execDir = Bundle.main.executableURL?.deletingLastPathComponent()
            let candidates = [
                execDir?.appendingPathComponent("LocalTalker.icns"),
                execDir?.appendingPathComponent("../Resources/LocalTalker.icns"),
                execDir?.appendingPathComponent("../../Resources/LocalTalker.icns"),
                URL(fileURLWithPath: "Resources/LocalTalker.icns"),
            ].compactMap { $0 }
            for url in candidates {
                if FileManager.default.fileExists(atPath: url.path),
                   let img = NSImage(contentsOf: url) {
                    NSApp.applicationIconImage = img
                    break
                }
            }
        }

        registerCarbonHotkeys()
        conversationLoop = ConversationLoop()
        showMainWindow()

        let models = ModelManager.shared
        if !models.sileroVADReady {
            Task {
                try? await models.downloadVADModels()
                models.checkModels()
                await conversationLoop.start()
            }
        } else {
            Task { await conversationLoop.start() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        conversationLoop?.stop()
        if let ref = carbonStopHotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = carbonMuteHotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = carbonNewSessionHotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = carbonTTSHotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = carbonEventHandler { RemoveEventHandler(handler) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func showMainWindow() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = MainWindowView(conversationLoop: conversationLoop)
            .preferredColorScheme(.dark)

        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = "LocalTalker"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 1120, height: 680))
        window.minSize = NSSize(width: 900, height: 540)
        window.center()
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
        window.isOpaque = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
    }

    private func registerCarbonHotkeys() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()

            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            DispatchQueue.main.async {
                switch hotKeyID.id {
                case 1:
                    appDelegate.conversationLoop?.stopSpeech()
                case 2:
                    appDelegate.conversationLoop?.isMuted.toggle()
                case 3:
                    appDelegate.conversationLoop?.startNewSession()
                case 4:
                    appDelegate.conversationLoop?.ttsEnabled.toggle()
                default:
                    break
                }
            }

            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            selfPtr,
            &carbonEventHandler
        )

        let signature = OSType(0x4C544C4B) // LTLK

        let stopID = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(47, UInt32(cmdKey), stopID, GetApplicationEventTarget(), 0, &carbonStopHotKeyRef) // Cmd+.

        let muteID = EventHotKeyID(signature: signature, id: 2)
        RegisterEventHotKey(44, UInt32(cmdKey), muteID, GetApplicationEventTarget(), 0, &carbonMuteHotKeyRef) // Cmd+/

        let sessionID = EventHotKeyID(signature: signature, id: 3)
        RegisterEventHotKey(45, UInt32(cmdKey | shiftKey), sessionID, GetApplicationEventTarget(), 0, &carbonNewSessionHotKeyRef) // Cmd+Shift+N

        let ttsID = EventHotKeyID(signature: signature, id: 4)
        RegisterEventHotKey(43, UInt32(cmdKey), ttsID, GetApplicationEventTarget(), 0, &carbonTTSHotKeyRef) // Cmd+,
    }
}
