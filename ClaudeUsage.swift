// ClaudeUsage.swift
// macOS menu bar app — quick-access popover for Claude Pro usage stats
//
// Account identity comes from ~/.claudeusage.json — no DOM scraping needed.
// On the login page a native account bar appears so you can one-click fill
// your email, then just grab the magic-link code as usual.
//
// Requirements: macOS 12+, Xcode Command Line Tools
// Build:        bash build.sh
// First launch: xattr -cr ClaudeUsage.app && open ClaudeUsage.app

import Cocoa
import WebKit

// MARK: - Config Model

struct ClaudeAccount: Codable {
    var email:   String
    var display: String
}

struct ClaudeConfig: Codable {
    var accounts:       [ClaudeAccount]
    var lastUsedIndex:  Int?

    // ~/.claudeusage.json
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claudeusage.json")
    }

    static func load() -> ClaudeConfig {
        guard let data   = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(ClaudeConfig.self, from: data)
        else { return ClaudeConfig(accounts: [], lastUsedIndex: nil) }
        return config
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(self) {
            try? data.write(to: ClaudeConfig.configURL, options: .atomic)
        }
    }

    /// Creates a template config on first launch so the user knows the format.
    static func createIfAbsent() {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        let template = ClaudeConfig(
            accounts: [
                ClaudeAccount(email: "personal@example.com", display: "Personal"),
                ClaudeAccount(email: "work@example.com",     display: "Work")
            ],
            lastUsedIndex: nil
        )
        template.save()
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {

    private var statusItem:          NSStatusItem!
    private var popover:             NSPopover!
    private var webView:             WKWebView!
    private var accountBar:          NSView!
    private var accountBarButtons:   [NSButton] = []
    private var navBar:              NSView!         // shown on authenticated pages

    private var appConfig  = ClaudeConfig.load()
    private var activeAccount: ClaudeAccount?

    private let settingsURL = URL(string: "https://claude.ai/settings")!
    private let loginURL    = URL(string: "https://claude.ai/login")!

    private let popoverWidth:    CGFloat = 440
    private let popoverHeight:   CGFloat = 600
    private let accountBarHeight: CGFloat = 46

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        ClaudeConfig.createIfAbsent()
        appConfig = ClaudeConfig.load()

        // Restore last used account for the menu bar label
        if let idx = appConfig.lastUsedIndex, idx < appConfig.accounts.count {
            activeAccount = appConfig.accounts[idx]
        }

        setupWebView()
        setupStatusItem()
        setupPopover()
        updateStatusItemLabel()
    }

    // MARK: Setup

    private func setupWebView() {
        let webConfig = WKWebViewConfiguration()
        webConfig.websiteDataStore = .default()     // Persist cookies between launches

        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight),
            configuration: webConfig
        )
        webView.navigationDelegate = self
        webView.load(URLRequest(url: settingsURL))
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        let symCfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = NSImage(
            systemSymbolName: "gauge.medium",
            accessibilityDescription: "Claude Usage"
        )?.withSymbolConfiguration(symCfg)

        button.imagePosition = .imageLeft
        button.font  = .systemFont(ofSize: 12, weight: .medium)
        button.title = ""
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupPopover() {
        let totalFrame = NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight)
        let container  = NSView(frame: totalFrame)

        // ── Account bar (sits at the top; hidden on authenticated pages) ──────
        accountBar = NSView(frame: NSRect(
            x: 0,
            y: popoverHeight - accountBarHeight,
            width: popoverWidth,
            height: accountBarHeight
        ))
        accountBar.wantsLayer = true
        accountBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Hairline separator at the bottom of the bar
        let sep = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        accountBar.addSubview(sep)

        accountBar.isHidden = true

        // ── Nav bar (shown on authenticated pages) ────────────────────────────
        navBar = NSView(frame: NSRect(
            x: 0,
            y: popoverHeight - accountBarHeight,
            width: popoverWidth,
            height: accountBarHeight
        ))
        navBar.wantsLayer = true
        navBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let navSep = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: 1))
        navSep.wantsLayer = true
        navSep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        navBar.addSubview(navSep)

        // Settings button (left)
        let settingsBtn = NSButton(frame: .zero)
        settingsBtn.title      = "⚙ Settings"
        settingsBtn.bezelStyle = .rounded
        settingsBtn.controlSize = .small
        settingsBtn.font       = .systemFont(ofSize: 12, weight: .medium)
        settingsBtn.target     = self
        settingsBtn.action     = #selector(goToSettings)
        settingsBtn.sizeToFit()
        settingsBtn.frame = CGRect(x: 10, y: (accountBarHeight - 22) / 2,
                                   width: settingsBtn.frame.width + 10, height: 22)
        navBar.addSubview(settingsBtn)

        // Sign Out button (right-aligned)
        let signOutBtn = NSButton(frame: .zero)
        signOutBtn.title      = "Sign Out"
        signOutBtn.bezelStyle = .rounded
        signOutBtn.controlSize = .small
        signOutBtn.font       = .systemFont(ofSize: 12, weight: .medium)
        signOutBtn.contentTintColor = .systemRed
        signOutBtn.target     = self
        signOutBtn.action     = #selector(signOut)
        signOutBtn.sizeToFit()
        let signOutWidth = signOutBtn.frame.width + 10
        signOutBtn.frame = CGRect(x: popoverWidth - signOutWidth - 10,
                                  y: (accountBarHeight - 22) / 2,
                                  width: signOutWidth, height: 22)
        navBar.addSubview(signOutBtn)

        navBar.isHidden = true

        // ── WebView (full height; shrinks when either bar is visible) ─────────
        webView.frame = totalFrame

        container.addSubview(webView)
        container.addSubview(accountBar)
        container.addSubview(navBar)

        rebuildAccountBarButtons()

        let vc        = NSViewController()
        vc.view       = container

        popover                    = NSPopover()
        popover.contentViewController = vc
        popover.contentSize        = NSSize(width: popoverWidth, height: popoverHeight)
        popover.behavior           = .transient
        popover.animates           = true
    }

    // MARK: Account bar

    private func rebuildAccountBarButtons() {
        accountBarButtons.forEach { $0.removeFromSuperview() }
        accountBarButtons = []

        guard !appConfig.accounts.isEmpty else { return }

        // Left label
        let label       = NSTextField(labelWithString: "Sign in as:")
        label.font      = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.sizeToFit()
        label.frame.origin = CGPoint(x: 10, y: (accountBarHeight - label.frame.height) / 2)
        accountBar.addSubview(label)

        var x = label.frame.maxX + 8

        for account in appConfig.accounts {
            let btn           = NSButton(frame: .zero)
            btn.title         = account.display
            btn.bezelStyle    = .rounded
            btn.controlSize   = .small
            btn.font          = .systemFont(ofSize: 12, weight: .medium)
            btn.toolTip       = account.email
            btn.target        = self
            btn.action        = #selector(accountButtonClicked(_:))
            btn.sizeToFit()
            btn.frame = CGRect(
                x: x, y: (accountBarHeight - 22) / 2,
                width: max(btn.frame.width + 10, 60), height: 22
            )
            accountBar.addSubview(btn)
            accountBarButtons.append(btn)
            x += btn.frame.width + 6
        }
    }

    private func showAccountBar() {
        guard !appConfig.accounts.isEmpty else { return }
        accountBar.isHidden = false
        webView.frame = NSRect(x: 0, y: 0,
                               width: popoverWidth,
                               height: popoverHeight - accountBarHeight)
    }

    private func hideAccountBar() {
        accountBar.isHidden = true
        webView.frame = NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight)
    }

    private func showNavBar() {
        navBar.isHidden    = false
        accountBar.isHidden = true
        webView.frame = NSRect(x: 0, y: 0,
                               width: popoverWidth,
                               height: popoverHeight - accountBarHeight)
    }

    private func hideNavBar() {
        navBar.isHidden = true
        webView.frame = NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight)
    }

    @objc private func goToSettings() {
        webView.load(URLRequest(url: settingsURL))
    }

    @objc private func signOut() {
        // Clear all webview cookies/data → effectively signs out of the embedded session
        let store     = webView.configuration.websiteDataStore
        let allTypes  = WKWebsiteDataStore.allWebsiteDataTypes()
        store.removeData(ofTypes: allTypes, modifiedSince: .distantPast) { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.hideNavBar()
                self.webView.load(URLRequest(url: self.loginURL))
            }
        }
    }

    // MARK: Account actions

    @objc private func accountButtonClicked(_ sender: NSButton) {
        guard let idx = accountBarButtons.firstIndex(of: sender),
              idx < appConfig.accounts.count else { return }
        let account = appConfig.accounts[idx]
        selectAccount(account, index: idx)
        fillEmailInWebView(account.email)
    }

    private func selectAccount(_ account: ClaudeAccount, index: Int) {
        activeAccount             = account
        appConfig.lastUsedIndex   = index
        appConfig.save()
        updateStatusItemLabel()
    }

    /// Fills the email input on the claude.ai login page using React-compatible
    /// synthetic events so the framework picks up the value change.
    private func fillEmailInWebView(_ email: String) {
        let safe = email.replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            var input = document.querySelector(
                'input[type="email"], input[placeholder*="email" i]'
            );
            if (!input) return false;
            var setter = Object.getOwnPropertyDescriptor(
                window.HTMLInputElement.prototype, 'value'
            ).set;
            setter.call(input, '\(safe)');
            input.dispatchEvent(new Event('input',  { bubbles: true }));
            input.dispatchEvent(new Event('change', { bubbles: true }));
            input.focus();
            return true;
        })()
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: Status item label

    private func updateStatusItemLabel() {
        guard let button = statusItem.button else { return }
        if let account = activeAccount {
            let label = account.display.count > 12
                ? String(account.display.prefix(11)) + "…"
                : account.display
            button.title   = " \(label)"
            button.toolTip = "Claude Pro Usage · \(account.email)\nClick to view, right-click for options"
        } else {
            button.title   = ""
            button.toolTip = "Claude Pro Usage — click to view, right-click for options"
        }
    }

    // MARK: Popover / click

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        event.type == .rightMouseUp ? showContextMenu() : togglePopover()
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if isOnAuthenticatedPage() { webView.reload() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func isOnAuthenticatedPage() -> Bool {
        guard let url = webView.url else { return false }
        let s    = url.absoluteString
        let path = url.path
        let authPatterns = ["/login", "/magic", "/verify", "/auth", "/callback",
                            "/sign-in", "/signup", "/register", "/oauth"]
        if authPatterns.contains(where: { s.contains($0) }) { return false }
        if path == "/" || path.isEmpty                       { return false }
        return true
    }

    // MARK: Context menu

    private func showContextMenu() {
        let menu = NSMenu()

        // ── Active account header ─────────────────────────────────────────────
        if let account = activeAccount {
            let n = NSMenuItem(title: account.display, action: nil, keyEquivalent: "")
            n.isEnabled = false; menu.addItem(n)
            let e = NSMenuItem(title: account.email,   action: nil, keyEquivalent: "")
            e.isEnabled = false; menu.addItem(e)
        } else {
            let i = NSMenuItem(title: "No account configured", action: nil, keyEquivalent: "")
            i.isEnabled = false; menu.addItem(i)
        }

        menu.addItem(.separator())

        // ── Switch account submenu (only if >1 account) ───────────────────────
        if appConfig.accounts.count > 1 {
            let switchItem = NSMenuItem(title: "Switch Account", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (i, account) in appConfig.accounts.enumerated() {
                let item = NSMenuItem(
                    title:          "\(account.display)  –  \(account.email)",
                    action:         #selector(switchAccount(_:)),
                    keyEquivalent:  ""
                )
                item.tag    = i
                item.target = self
                if i == appConfig.lastUsedIndex { item.state = .on }
                sub.addItem(item)
            }
            switchItem.submenu = sub
            menu.addItem(switchItem)
            menu.addItem(.separator())
        }

        // ── Actions ───────────────────────────────────────────────────────────
        let reload = NSMenuItem(title: "Reload", action: #selector(reloadPage), keyEquivalent: "r")
        reload.target = self; menu.addItem(reload)

        let open = NSMenuItem(title: "Open in Browser", action: #selector(openInBrowser), keyEquivalent: "o")
        open.target = self; menu.addItem(open)

        let edit = NSMenuItem(title: "Edit Config File…", action: #selector(editConfig), keyEquivalent: ",")
        edit.target = self; menu.addItem(edit)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Claude Usage",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in self?.statusItem.menu = nil }
    }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx < appConfig.accounts.count else { return }
        selectAccount(appConfig.accounts[idx], index: idx)
        // Navigate to login page so the user can sign in with the new account
        webView.load(URLRequest(url: loginURL))
    }

    @objc private func reloadPage() {
        if isOnAuthenticatedPage() { webView.reload() }
        if !popover.isShown, let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func openInBrowser() {
        NSWorkspace.shared.open(settingsURL)
    }

    @objc private func editConfig() {
        // Reload config in case user edited it externally, then open in default editor
        appConfig = ClaudeConfig.load()
        rebuildAccountBarButtons()
        NSWorkspace.shared.open(ClaudeConfig.configURL)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let path = webView.url?.path ?? ""

        // Post-login redirect lands on "/": check if actually authenticated
        if path == "/" || path.isEmpty {
            webView.evaluateJavaScript("""
                document.querySelector('input[type="email"], input[placeholder*="email" i]') === null
            """) { [weak self] result, _ in
                guard let self = self else { return }
                if (result as? Bool) == true {
                    DispatchQueue.main.async {
                        self.hideAccountBar()
                        self.hideNavBar()
                        self.webView.load(URLRequest(url: self.settingsURL))
                    }
                }
            }
            return
        }

        DispatchQueue.main.async {
            if self.isOnAuthenticatedPage() {
                self.showNavBar()       // Settings + Sign Out bar
            } else {
                self.hideNavBar()
                self.showAccountBar()   // "Sign in as: Personal / Work" bar
            }
        }
    }

    func webView(
        _ webView:          WKWebView,
        decidePolicyFor     navigationAction: WKNavigationAction,
        decisionHandler:    @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let host      = url.host ?? ""
        let isTrusted = host.hasSuffix("claude.ai") || host.hasSuffix("anthropic.com")
        if navigationAction.navigationType == .linkActivated && !isTrusted {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

// MARK: - Entry Point

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
