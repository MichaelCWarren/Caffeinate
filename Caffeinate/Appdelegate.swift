//
//  Appdelegate.swift
//  Caffeinate
//
//  Created by Lennard on 26.10.22.
//

import Foundation
import AppKit
import IOKit.pwr_mgt

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusBarItem: NSStatusItem?
    var hasCoffee = false
    var configHandler = ConfigHandler()
    // One IOPMAssertion per active caffeinate-style flag, keyed by assertion type.
    var activeAssertions: [String: IOPMAssertionID] = [:]

    // Menu items whose checkmarks we sync with the current state.
    private var menu: NSMenu!
    private var activeItem: NSMenuItem!
    private var displayItem: NSMenuItem!
    private var idleItem: NSMenuItem!
    private var diskItem: NSMenuItem!
    private var systemItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = buildMenu()
        // Left-click toggles active; right-click opens the menu. We deliberately
        // don't assign statusBarItem.menu, otherwise any click would open it.
        statusBarItem?.button?.action = #selector(statusItemClicked(_:))
        statusBarItem?.button?.target = self
        statusBarItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusButton()
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // Temporarily attach the menu so the status item pops it up, then
            // detach so the next left-click fires the action again.
            statusBarItem?.menu = menu
            statusBarItem?.button?.performClick(nil)
            statusBarItem?.menu = nil
        } else {
            toggleActive()
        }
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false // we manage enabled/checkmark state ourselves

        activeItem = addItem(to: menu, title: "Active", action: #selector(toggleActive))

        menu.addItem(.separator())

        let header = NSMenuItem(title: "Keep Awake", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        displayItem = addFlagItem(to: menu, title: "Prevent display sleep", action: #selector(toggleDisplay))
        idleItem = addFlagItem(to: menu, title: "Prevent system idle sleep", action: #selector(toggleIdle))
        diskItem = addFlagItem(to: menu, title: "Prevent disk idle sleep", action: #selector(toggleDisk))
        systemItem = addFlagItem(to: menu, title: "Prevent system sleep (on AC power)", action: #selector(toggleSystem))

        menu.addItem(.separator())

        loginItem = addItem(to: menu, title: "Start at login", action: #selector(toggleLogin))

        menu.addItem(.separator())

        _ = addItem(to: menu, title: "About Caffeinate", action: #selector(showAbout))
        let quit = addItem(to: menu, title: "Quit Caffeinate", action: #selector(quit))
        quit.keyEquivalent = "q"

        return menu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func addFlagItem(to menu: NSMenu, title: String, action: Selector) -> NSMenuItem {
        let item = addItem(to: menu, title: title, action: action)
        item.indentationLevel = 1
        return item
    }

    // Sync checkmarks/enabled state whenever the menu is about to open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let conf = configHandler.conf
        activeItem.state = hasCoffee ? .on : .off
        displayItem.state = conf.preventDisplaySleep ? .on : .off
        idleItem.state = conf.preventIdleSleep ? .on : .off
        diskItem.state = conf.preventDiskIdle ? .on : .off
        systemItem.state = conf.preventSystemSleep ? .on : .off
        loginItem.state = conf.atLogin ? .on : .off
        loginItem.isEnabled = configHandler.macOS13
    }

    // MARK: - Actions

    @objc private func toggleActive() {
        setActive(!hasCoffee)
    }

    private func setActive(_ active: Bool) {
        if active {
            hasCoffee = createAssertions(reason: "Caffeinate")
        } else {
            _ = releaseAssertions()
            hasCoffee = false
        }
        updateStatusButton()
    }

    // Flag toggles update the persisted config and re-apply live when active.
    @objc private func toggleDisplay() { flip { $0.preventDisplaySleep.toggle() } }
    @objc private func toggleIdle()    { flip { $0.preventIdleSleep.toggle() } }
    @objc private func toggleDisk()    { flip { $0.preventDiskIdle.toggle() } }
    @objc private func toggleSystem()  { flip { $0.preventSystemSleep.toggle() } }

    private func flip(_ change: (ConfigData) -> Void) {
        configHandler.mutateConfig(change)
        if hasCoffee {
            // Re-apply so the change takes effect immediately. If nothing is
            // selected anymore, we end up inactive.
            hasCoffee = createAssertions(reason: "Caffeinate")
            updateStatusButton()
        }
    }

    @objc private func toggleLogin() {
        let desired = !configHandler.conf.atLogin
        switch configHandler.setAtLogin(desired) {
        case .ok, .unsupported:
            break
        case .requiresApproval:
            showLoginAlert("Caffeinate needs your approval to start at login. Enable it under System Settings → General → Login Items.")
        case .failed(let error):
            showLoginAlert("Couldn't update the login item: \(error.localizedDescription)")
        }
    }

    private func showLoginAlert(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Start at Login"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        configHandler.quitApp()
    }

    private func updateStatusButton() {
        let symbol = hasCoffee ? "cup.and.saucer.fill" : "cup.and.saucer"
        statusBarItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusBarItem?.button?.toolTip = hasCoffee ? "Caffeinate is active" : "Caffeinate is not active"
    }

    // MARK: - Power assertions (mirrors caffeinate(8))

    // The enabled flags map onto IOKit power-management assertion types.
    private func selectedAssertionTypes() -> [String] {
        let conf = configHandler.conf
        var types: [String] = []
        if conf.preventDisplaySleep { types.append(kIOPMAssertionTypePreventUserIdleDisplaySleep as String) } // -d
        if conf.preventIdleSleep { types.append(kIOPMAssertionTypePreventUserIdleSystemSleep as String) }     // -i
        if conf.preventDiskIdle { types.append(kIOPMAssertPreventDiskIdle as String) }                        // -m
        if conf.preventSystemSleep { types.append(kIOPMAssertionTypePreventSystemSleep as String) }           // -s
        return types
    }

    // Creates one assertion per selected flag. Returns true if at least one is
    // held. Any previously held assertions are released first.
    @discardableResult
    func createAssertions(reason: String = "Unknown reason") -> Bool {
        _ = releaseAssertions()
        for type in selectedAssertionTypes() {
            var assertionID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(type as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     reason as CFString,
                                                     &assertionID)
            if result == kIOReturnSuccess {
                activeAssertions[type] = assertionID
            }
        }
        return !activeAssertions.isEmpty
    }

    @discardableResult
    func releaseAssertions() -> Bool {
        guard !activeAssertions.isEmpty else { return false }
        for (_, assertionID) in activeAssertions {
            _ = IOPMAssertionRelease(assertionID)
        }
        activeAssertions.removeAll()
        return true
    }
}
