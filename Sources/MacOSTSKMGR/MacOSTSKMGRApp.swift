import SwiftUI

@main
struct MacOSTSKMGRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootWindowView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 860)
        .commands {
            FinderBarAppInfoCommands()
            FinderBarSystemCommands()
            FinderBarWindowCommands()
            FinderBarCustomMenuCommands()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.windows.forEach(configure(window:))
        DispatchQueue.main.async {
            self.updateFinderBarMenuVisibility(isCompactMode: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func updateFinderBarMenuVisibility(isCompactMode: Bool) {
        guard let items = NSApp.mainMenu?.items else { return }
        for (index, item) in items.enumerated() {
            item.isHidden = isCompactMode && index > 0
        }
        NSApp.mainMenu?.update()
    }

    private func configure(window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.toolbarStyle = .unifiedCompact
    }
}

struct FinderBarAppInfoCommands: Commands {
    @ObservedObject private var commandState = FinderBarCommandState.shared

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(commandState.language.text("关于 任务管理器", "About MacOSTSKMGR")) {
                post(.showAbout)
            }
        }
    }

    private func post(_ command: FinderBarCommand, value: String? = nil) {
        var userInfo: [String: Any] = ["command": command.rawValue]
        if let value {
            userInfo["value"] = value
        }
        NotificationCenter.default.post(name: .finderBarCommandTriggered, object: nil, userInfo: userInfo)
    }
}

struct FinderBarSystemCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) { }
        CommandGroup(replacing: .undoRedo) { }
        CommandGroup(replacing: .pasteboard) { }
        CommandGroup(replacing: .textEditing) { }
        CommandGroup(replacing: .textFormatting) { }
        CommandGroup(replacing: .toolbar) { }
        CommandGroup(replacing: .sidebar) { }
    }
}

struct FinderBarWindowCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .windowSize) { }
        CommandGroup(replacing: .windowList) { }
        CommandGroup(replacing: .windowArrangement) { }
        CommandGroup(replacing: .help) { }
    }
}

struct FinderBarCustomMenuCommands: Commands {
    @ObservedObject private var commandState = FinderBarCommandState.shared

    var body: some Commands {
        if !commandState.compactMode {
            CommandMenu(commandState.language.text("文件", "File")) {
                Button(commandState.language.text("运行新任务", "Run new task")) {
                    post(.runNewTask)
                }
                Divider()
                Button(commandState.language.text("退出", "Exit")) {
                    post(.quitApp)
                }
            }

            CommandMenu(commandState.language.text("选项", "Options")) {
                Button {
                    post(.toggleAlwaysOnTop)
                } label: {
                    checkmarkLabel(
                        commandState.language.text("置于顶层", "Always on top"),
                        checked: commandState.alwaysOnTop
                    )
                }
                Button {
                    post(.toggleUseSmallValues)
                } label: {
                    checkmarkLabel(
                        commandState.language.text("使用小值", "Use small values"),
                        checked: commandState.useSmallValues
                    )
                }
                Button {
                    post(.toggleHideWhenMinimized)
                } label: {
                    checkmarkLabel(
                        commandState.language.text("最小化时隐藏", "Hide when minimized"),
                        checked: commandState.hideWhenMinimized
                    )
                }
                Divider()
                Menu(commandState.language.text("语言", "Language")) {
                    ForEach(AppLanguage.allCases) { language in
                        Button {
                            post(.setLanguage, value: language.rawValue)
                        } label: {
                            checkmarkLabel(language == .chinese ? "中文" : "English", checked: commandState.language == language)
                        }
                    }
                }
                Menu(commandState.language.text("温度单位", "Temperature unit")) {
                    ForEach(TemperatureUnit.allCases) { unit in
                        Button {
                            post(.setTemperatureUnit, value: unit.rawValue)
                        } label: {
                            checkmarkLabel(unit.title(in: commandState.language), checked: commandState.temperatureUnit == unit)
                        }
                    }
                }
                Menu(commandState.language.text("菜单风格", "Menu style")) {
                    ForEach(MenuVisualStyle.allCases) { style in
                        Button {
                            post(.setMenuVisualStyle, value: style.rawValue)
                        } label: {
                            checkmarkLabel(style.title(in: commandState.language), checked: commandState.menuVisualStyle == style)
                        }
                    }
                }
            }

            CommandMenu(commandState.language.text("查看", "View")) {
                Button(commandState.language.text("立即刷新", "Refresh now")) {
                    post(.refreshNow)
                }
                Menu(commandState.language.text("更新速度", "Update speed")) {
                    ForEach(RefreshSpeedOption.allCases) { option in
                        Button {
                            post(.setRefreshSpeed, value: option.rawValue)
                        } label: {
                            checkmarkLabel(option.title(in: commandState.language), checked: commandState.refreshSpeed == option)
                        }
                    }
                }
                Divider()
                Button(commandState.language.text("全部展开", "Expand all")) {
                    post(.expandAll)
                }
                Button(commandState.language.text("全部折叠", "Collapse all")) {
                    post(.collapseAll)
                }
            }
        }
    }

    @ViewBuilder
    private func checkmarkLabel(_ title: String, checked: Bool) -> some View {
        if checked {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func post(_ command: FinderBarCommand, value: String? = nil) {
        var userInfo: [String: Any] = ["command": command.rawValue]
        if let value {
            userInfo["value"] = value
        }
        NotificationCenter.default.post(name: .finderBarCommandTriggered, object: nil, userInfo: userInfo)
    }
}
