import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

// Minimal menu bar, so Cmd-Q and Cmd-W behave.
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
// Settings, Hide, Quit -- and nothing else. Everything that used to be here
// is a control in the Settings window, which is where a setting belongs.
//
// Target left nil so it travels the responder chain, which ends at NSApp and
// then its delegate, where the settings live.
appMenu.addItem(withTitle: "About…",
                action: #selector(AppDelegate.showAbout(_:)),
                keyEquivalent: "")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Settings…",
                action: #selector(AppDelegate.showSettings(_:)),
                keyEquivalent: ",")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Hide Cochleagram",
                action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Quit Cochleagram",
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
app.mainMenu = mainMenu

app.run()
