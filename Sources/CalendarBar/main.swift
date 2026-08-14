import AppKit
import SwiftUI

/// Agent-mode menu bar app: status item + SwiftUI popover, no Dock icon and no main menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var store: CalendarStore!
    private var eventMonitor: Any?
    private var keyMonitor: Any?

    /// Constructed from top-level code, which is not main-actor isolated in Swift 5 mode;
    /// all the isolated setup happens in `applicationDidFinishLaunching`.
    nonisolated override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces alongside LSUIElement in Info.plist, so `swift run` also
        // behaves like an agent app.
        NSApp.setActivationPolicy(.accessory)

        ThemeManager.shared.applyAppearance()

        store = CalendarStore()
        popover = NSPopover()
        setUpStatusItem()
        setUpPopover()
        // Diagnostics. Reading the Keychain requires a GUI session, so the file-based
        // form exists to be launched with:
        //   open -n "/Applications/Calendar Bar.app" --args --diagnose /tmp/report.txt
        //
        // This runs *instead of* store.start(): starting the store would kick off its own
        // refresh concurrently with the diagnostic one, and the two would double-count.
        let arguments = CommandLine.arguments
        let diagnoseFile = arguments.firstIndex(of: "--diagnose").flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        }
        if diagnoseFile != nil || ProcessInfo.processInfo.environment["CALENDARBAR_DIAGNOSE"] == "1" {
            Task { [store] in
                let report = await store!.runDiagnostics() + "\n"
                if let diagnoseFile {
                    try? report.write(toFile: diagnoseFile, atomically: true, encoding: .utf8)
                } else {
                    FileHandle.standardOutput.write(Data(report.utf8))
                }
                exit(0)
            }
            return
        }

        store.start()

        if let path = DebugSnapshot.requestedPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [store] in
                DebugSnapshot.export(store: store!, to: path)
            }
            return
        }

        // Debug aid: open the popover immediately so it can be inspected/screenshotted.
        if ProcessInfo.processInfo.environment["CALENDARBAR_OPEN_AT_LAUNCH"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showPopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopEventMonitor()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = StatusItemIcon.make()
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Calendar Bar"
        }
    }

    private func setUpPopover() {
        popover.contentSize = NSSize(width: Theme.popoverWidth, height: Theme.popoverHeight)
        // Dismissal is handled manually (see startEventMonitor) so that opening the
        // header's native "..." menu does not count as an outside click.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverRootView(store: store))
    }

    // MARK: - Show / hide

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        store.goToToday()
        store.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Bring the popover forward without stealing focus permanently.
        popover.contentViewController?.view.window?.makeKey()
        startEventMonitor()
    }

    /// Closes the popover on a click in any other app (including the desktop) or on Escape.
    private func startEventMonitor() {
        if eventMonitor == nil {
            eventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.popover.isShown else { return event }
                if event.keyCode == 53 { // Escape
                    self.popover.performClose(nil)
                    return nil
                }
                return event
            }
        }
    }

    private func stopEventMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func popoverDidClose(_ notification: Notification) {
        stopEventMonitor()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
