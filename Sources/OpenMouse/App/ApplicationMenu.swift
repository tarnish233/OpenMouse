import AppKit

/// A menu-bar-only app does not receive the standard application menu for free. Installing
/// one explicitly restores the normal macOS responder-chain commands whenever the settings
/// window temporarily promotes the app to `.regular`.
struct ApplicationMenuSet {
    let main: NSMenu
    let services: NSMenu
    let windows: NSMenu

    @MainActor
    func install(on application: NSApplication) {
        application.mainMenu = main
        application.servicesMenu = services
        application.windowsMenu = windows
    }
}

@MainActor
enum ApplicationMenuBuilder {
    static func make(settingsTarget: AnyObject?, settingsAction: Selector) -> ApplicationMenuSet {
        let main = NSMenu()

        let application = NSMenu(title: Strings.appName)
        application.addItem(applicationItem(
            Strings.menuAbout,
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        ))
        application.addItem(.separator())
        let settings = item(Strings.menuSettings, action: settingsAction, key: ",")
        settings.target = settingsTarget
        application.addItem(settings)
        application.addItem(.separator())

        let services = NSMenu(title: Strings.menuServices)
        let servicesItem = item(Strings.menuServices)
        servicesItem.submenu = services
        application.addItem(servicesItem)
        application.addItem(.separator())
        application.addItem(applicationItem(
            Strings.menuHideApp,
            action: #selector(NSApplication.hide(_:)),
            key: "h"
        ))
        application.addItem(applicationItem(
            Strings.menuHideOthers,
            action: #selector(NSApplication.hideOtherApplications(_:)),
            key: "h",
            modifiers: [.command, .option]
        ))
        application.addItem(applicationItem(
            Strings.menuShowAll,
            action: #selector(NSApplication.unhideAllApplications(_:))
        ))
        application.addItem(.separator())
        application.addItem(applicationItem(
            Strings.menuQuitApp,
            action: #selector(NSApplication.terminate(_:)),
            key: "q"
        ))
        main.addItem(topLevel(Strings.appName, submenu: application))

        let file = NSMenu(title: Strings.menuFile)
        file.addItem(item(
            Strings.menuCloseWindow,
            action: #selector(NSWindow.performClose(_:)),
            key: "w"
        ))
        main.addItem(topLevel(Strings.menuFile, submenu: file))

        let edit = NSMenu(title: Strings.menuEdit)
        edit.addItem(item(Strings.menuUndo, action: Selector(("undo:")), key: "z"))
        edit.addItem(item(
            Strings.menuRedo,
            action: Selector(("redo:")),
            key: "z",
            modifiers: [.command, .shift]
        ))
        edit.addItem(.separator())
        edit.addItem(item(Strings.menuCut, action: #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item(Strings.menuCopy, action: #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item(Strings.menuPaste, action: #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(item(Strings.menuSelectAll, action: #selector(NSText.selectAll(_:)), key: "a"))
        main.addItem(topLevel(Strings.menuEdit, submenu: edit))

        let windows = NSMenu(title: Strings.menuWindow)
        windows.addItem(item(
            Strings.menuMinimize,
            action: #selector(NSWindow.performMiniaturize(_:)),
            key: "m"
        ))
        windows.addItem(item(Strings.menuZoom, action: #selector(NSWindow.performZoom(_:))))
        windows.addItem(.separator())
        windows.addItem(item(Strings.menuBringAllToFront, action: #selector(NSApplication.arrangeInFront(_:))))
        main.addItem(topLevel(Strings.menuWindow, submenu: windows))

        return ApplicationMenuSet(main: main, services: services, windows: windows)
    }

    private static func applicationItem(
        _ title: String,
        action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let entry = item(title, action: action, key: key, modifiers: modifiers)
        entry.target = NSApp
        return entry
    }

    private static func topLevel(_ title: String, submenu: NSMenu) -> NSMenuItem {
        let entry = item(title)
        entry.submenu = submenu
        return entry
    }

    private static func item(
        _ title: String,
        action: Selector? = nil,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return entry
    }
}
