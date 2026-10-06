import AppKit
import Combine
import CoreAudio
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model: MicModel
    private let meter: LevelMeter
    private let usage: UsageMonitor
    private let login: LoginItem
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var scrollMonitor: Any?
    private var subscription: AnyCancellable?

    override init() {
        model = MicModel(mode: .app)
        meter = LevelMeter()
        usage = UsageMonitor()
        login = LoginItem()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "MicVolume"
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        }
        statusItem = item

        popover.behavior = .transient
        popover.delegate = self
        let actions = PanelActions(
            openSoundSettings: { [weak self] in self?.openSettings(Self.soundSettings) },
            openPrivacySettings: { [weak self] in self?.openSettings(Self.privacySettings) },
            quit: { NSApp.terminate(nil) })
        let controller = NSHostingController(rootView: PopoverView(
            model: model, usage: usage, login: login, meter: meter, actions: actions))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller

        model.onDefaultDeviceChange = { [weak self] in self?.meter.restartSoon() }
        subscription = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatusItem() }
            }
        updateStatusItem()

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleScroll(event) ?? false }
            return handled ? nil : event
        }

        if !UserDefaults.standard.bool(forKey: "didFirstRun") {
            UserDefaults.standard.set(true, forKey: "didFirstRun")
            login.set(true)
        }
        logger.notice("Started. Default input: \(self.model.current?.name ?? "none", privacy: .public). Open at login: \(self.login.statusDescription, privacy: .public)")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    // MARK: Status item

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        guard let device = model.current else {
            button.image = symbol("mic", "No microphone")
            button.title = ""
            button.toolTip = "Mic Volume: no microphone connected"
            return
        }
        if model.muted {
            button.image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Microphone muted")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
            button.image?.isTemplate = false
            button.title = ""
            button.toolTip = "\(device.name): muted"
        } else {
            button.image = symbol("mic.fill", "Microphone")
            button.title = device.canSetVolume ? percent(model.volume) : ""
            button.toolTip = device.canSetVolume
                ? "\(device.name): \(percent(model.volume))\(model.lockTarget != nil ? " (locked)" : "")"
                : "\(device.name): fixed volume"
        }
    }

    private func symbol(_ name: String, _ description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if event?.modifierFlags.contains(.option) == true {
            model.toggleMute()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        guard let statusItem else { return }
        popover.performClose(nil)
        let menu = NSMenu()
        menu.autoenablesItems = false

        let device = model.current
        let mute = item(model.muted ? "Unmute" : "Mute", #selector(menuToggleMute))
        mute.isEnabled = device?.canMute ?? false
        menu.addItem(mute)
        let lock = item("Lock Volume", #selector(menuToggleLock))
        lock.state = model.lockTarget != nil ? .on : .off
        lock.isEnabled = device?.canSetVolume ?? false
        menu.addItem(lock)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Input Device"))
        for input in model.devices {
            let entry = item(input.name, #selector(menuSelectDevice(_:)))
            entry.tag = Int(input.id)
            entry.state = input.id == device?.id ? .on : .off
            entry.image = NSImage(systemSymbolName: input.symbol, accessibilityDescription: nil)
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        menu.addItem(item("Sound Settings…", #selector(menuSoundSettings)))
        menu.addItem(item("Quit Mic Volume", #selector(menuQuit), key: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func menuToggleMute() { model.toggleMute() }
    @objc private func menuToggleLock() { model.setLocked(model.lockTarget == nil) }
    @objc private func menuSelectDevice(_ sender: NSMenuItem) { model.selectDevice(AudioDeviceID(sender.tag)) }
    @objc private func menuSoundSettings() { openSettings(Self.soundSettings) }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    /// Scroll over the icon: up (physically) raises the volume, down lowers it.
    private func handleScroll(_ event: NSEvent) -> Bool {
        guard let button = statusItem?.button, let window = button.window, event.window === window else { return false }
        guard event.momentumPhase.isEmpty, let device = model.current, device.canSetVolume else { return true }
        var delta = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { delta = -delta }
        guard delta != 0 else { return true }
        if model.muted {
            if delta > 0 { model.toggleMute() }
            return true
        }
        let step = event.hasPreciseScrollingDeltas ? Float(delta) * 0.004 : (delta > 0 ? 0.03 : -0.03)
        model.setVolume(model.volume + max(-0.1, min(0.1, step)))
        return true
    }

    // MARK: Popover lifecycle

    func popoverDidShow(_ notification: Notification) {
        login.refresh()
        usage.start()
        meter.start()
    }

    func popoverDidClose(_ notification: Notification) {
        meter.stop()
        usage.stop()
    }

    // MARK: Settings

    private static let soundSettings = "x-apple.systempreferences:com.apple.Sound-Settings.extension"
    private static let privacySettings = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    private func openSettings(_ url: String) {
        popover.performClose(nil)
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
