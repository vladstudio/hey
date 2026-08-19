import Cocoa
import UserNotifications
import MacAppKit

private struct HeyEvent: Codable {
    let id: Int
    let title: String
    let message: String
    let created: Int
}

@MainActor class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    private let baseURL = URL(string: "https://hey.vlad.studio")!
    private let pollInterval: UInt64 = 15

    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!      // disabled line showing connection state
    private var loginItem: NSMenuItem!

    private var token: String = UserDefaults.standard.string(forKey: "token") ?? ""
    private var lastSeenId: Int = UserDefaults.standard.integer(forKey: "lastSeenId")
    private var pollTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ n: Notification) {
        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            if let url = Bundle.main.url(forResource: "menubar", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = true
                b.image = img
            } else {
                b.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "hey")
                b.image?.isTemplate = true
            }
        }

        let menu = NSMenu()
        menu.delegate = self

        statusLine = NSMenuItem(title: "starting…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open hey.vlad.studio", action: #selector(openSite), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let tokenItem = NSMenuItem(title: "Set Token…", action: #selector(setToken), keyEquivalent: "")
        tokenItem.target = self
        menu.addItem(tokenItem)
        menu.addItem(NSMenuItem.separator())

        loginItem = NSMenuItem(title: "Start on Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkUpdate), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit Hey", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu

        UNUserNotificationCenter.current().delegate = self
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }

        if token.isEmpty { promptToken() }
        UpdateChecker.check(repo: "vladstudio/hey", appName: "Hey")
        startPolling()
    }

    // MARK: - Menu actions

    @objc private func openSite() { NSWorkspace.shared.open(baseURL) }

    @objc private func setToken() { promptToken() }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        LoginItem.toggle()
        sender.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func checkUpdate() { UpdateChecker.check(repo: "vladstudio/hey-mac", appName: "Hey", manual: true) }

    // Minimal main menu so Cmd+X/C/V/A reach the modal text field (accessory
    // apps have no main menu by default, so key equivalents don't route).
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Hey")
        appMenu.addItem(withTitle: "About Hey", action: #selector(NSApp.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Hey", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    func menuWillOpen(_ menu: NSMenu) { loginItem.state = LoginItem.isEnabled ? .on : .off }

    // MARK: - Token prompt

    private func promptToken() {
        let alert = NSAlert()
        alert.messageText = "Hey"
        alert.informativeText = "Enter your Hey token"
        alert.alertStyle = .informational
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = token
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        token = t
        UserDefaults.standard.set(t, forKey: "token")
        lastSeenId = 0
        UserDefaults.standard.set(0, forKey: "lastSeenId")
        startPolling()
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 15))
            }
        }
    }

    private func poll() async {
        guard !token.isEmpty else { setStatus("no token — set token…"); return }
        var req = URLRequest(url: baseURL.appendingPathComponent("recent"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { setStatus("error"); return }
            if http.statusCode == 401 { setStatus("bad token"); return }
            guard http.statusCode == 200 else { setStatus("error \(http.statusCode)"); return }
            let events = try JSONDecoder().decode([HeyEvent].self, from: data) // newest first
            if lastSeenId == 0 {
                lastSeenId = events.first?.id ?? 0
                UserDefaults.standard.set(lastSeenId, forKey: "lastSeenId")
                setStatus("ready")
                return
            }
            for ev in events.filter({ $0.id > lastSeenId }).sorted(by: { $0.id < $1.id }) {
                notify(ev)
            }
            if let max = events.first?.id, max > lastSeenId {
                lastSeenId = max
                UserDefaults.standard.set(lastSeenId, forKey: "lastSeenId")
            }
            setStatus("ready")
        } catch {
            setStatus("offline")
        }
    }

    private func notify(_ ev: HeyEvent) {
        let c = UNMutableNotificationContent()
        c.title = ev.title
        c.body = ev.message
        c.sound = .default
        c.userInfo = ["url": baseURL.absoluteString]
        let req = UNNotificationRequest(identifier: "hey-\(ev.id)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func setStatus(_ s: String) { statusLine.title = s }

    // MARK: - Notification click → open site

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let urlStr = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: urlStr) else { return }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
    }
}




