import SwiftUI
import AppKit

enum PageInset {
    static let horizontal: CGFloat = 24
    static let top: CGFloat = 16
    static let bottom: CGFloat = 16
}

private enum WindowPresentationMode: Equatable {
    case compact
    case performanceSummary
    case performanceDetailSummary
    case full
}

enum KeyboardNavigationCommand {
    case focusNext
    case focusPrevious
    case moveUp
    case moveDown
    case moveLeft
    case moveRight
    case activatePrimary
    case activateSecondary
    case back
    case cancel
}

private enum KeyboardFocusArea: Equatable {
    case topTabs
    case compactList
    case compactMoreDetailsButton
    case compactPrimaryActionButton
    case performanceSidebar
    case performanceDetail
    case processTable
    case footerToggleCompact
    case footerPrimaryAction
}

private enum ProcessKeyboardItem: Equatable {
    case section(ProcessSectionKind)
    case row(ProcessSectionKind, Int32)
}

struct RootWindowView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("menu_visual_style") private var menuVisualStyleRawValue: String = MenuVisualStyle.windowsNT.rawValue
    @StateObject private var monitor = SystemMonitor()
    @StateObject private var newTaskPanelManager = NewTaskPanelManager()
    @StateObject private var networkDetailsPanelManager = NetworkDetailsPanelManager()
    @StateObject private var aboutPanelManager = AboutPanelManager.shared
    private let finderBarCommandState = FinderBarCommandState.shared
    @State private var language: AppLanguage = AppLanguage.defaultFromSystem()
    @State private var temperatureUnit: TemperatureUnit = .celsius
    @State private var selectedTab: TaskTab = .processes
    @State private var selectedPerf: PerfSelection = .cpu
    @State private var performanceViewMode: PerformanceViewMode = .full
    @State private var showsPerformanceGraphs = true
    @State private var cpuGraphMode: CPUGraphMode = .logicalProcessors
    @State private var gpuGraphLayoutMode: GPUGraphLayoutMode = .multiEngine
    @State private var showsKernelTime = false
    @State private var compactMode = true
    @State private var activeMenu: MenuKind?
    @State private var alwaysOnTop = false
    @State private var hideWhenMinimized = false
    @State private var useSmallValues = false
    @State private var collapsedSections: Set<ProcessSectionKind> = []
    @State private var processMemoryDisplayMode: ProcessResourceDisplayMode = .value
    @State private var processDiskDisplayMode: ProcessResourceDisplayMode = .value
    @State private var processNetworkDisplayMode: ProcessResourceDisplayMode = .value
    @State private var selectedProcessPID: Int32?
    @State private var taskActionErrorMessage = ""
    @State private var lastWindowPresentationMode: WindowPresentationMode?
    @State private var commandKeyPressed = false
    @State private var compactTransitionInProgress = false
    @State private var activeOptionsSubmenu: OptionsSubmenuKind?
    @State private var hoveredOptionsSubmenuParent: OptionsSubmenuKind?
    @State private var optionsSubmenuHovered = false
    @State private var activeViewSubmenu: ViewSubmenuKind?
    @State private var hoveredViewSubmenuParent: ViewSubmenuKind?
    @State private var viewSubmenuHovered = false
    @State private var pendingPerformanceSelection: PerfSelection?
    @State private var menuKeyboardContext: MenuKeyboardContext?
    @State private var menuKeyboardIndex = 0
    @State private var keyboardFocusArea: KeyboardFocusArea = .compactList
    @State private var selectedProcessSectionKind: ProcessSectionKind?
    @State private var processSortKey: ProcessSortKey = .cpu
    @State private var processSortAscending = false

    private var menuVisualStyle: MenuVisualStyle {
        get { MenuVisualStyle(rawValue: menuVisualStyleRawValue) ?? .windowsNT }
        nonmutating set { menuVisualStyleRawValue = newValue.rawValue }
    }

    var body: some View {
        lifecycleObservedContent
            .environment(\.appLanguage, language)
            .environment(\.temperatureUnit, temperatureUnit)
            .environment(\.menuVisualStyle, menuVisualStyle)
    }

    private var lifecycleObservedContent: some View {
        AnyView(interactionObservedContent)
            .onAppear {
                applySystemPresentationPreferences()
                let mode = currentWindowPresentationMode
                lastWindowPresentationMode = mode
                resizeWindowForCurrentMode(animated: false)
            }
            .onAppear {
                monitor.language = language
                monitor.temperatureUnit = temperatureUnit
                updateDiskRefreshPolicy()
                updateMonitorPresentation()
                monitor.start()
                normalizeKeyboardFocusArea()
                updateWindowTrafficLights()
                syncFinderBarCommandState()
                updateFinderBarForCompactMode()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                applySystemPresentationPreferences()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                monitor.stop()
            }
    }

    private var interactionObservedContent: some View {
        let base = AnyView(visualRootContent)
        let windowObserved = AnyView(
            base
            .onChange(of: alwaysOnTop) { _, value in
                updateWindowLevel(alwaysOnTop: value)
            }
        )
        let menuObserved = AnyView(
            windowObserved
            .onChange(of: activeMenu) { _, newValue in
                resetMenuHoverState()
                if let newValue {
                    menuKeyboardContext = .main(newValue)
                    menuKeyboardIndex = 0
                } else {
                    menuKeyboardContext = nil
                }
            }
            .onChange(of: menuVisualStyleRawValue) { _, _ in
                activeMenu = nil
                resetMenuHoverState()
            }
        )
        let selectionObserved = AnyView(
            menuObserved
            .onChange(of: monitor.sidebarItems.map(\.id)) { oldIDs, newIDs in
                guard !newIDs.isEmpty else { return }
                guard !newIDs.contains(selectedPerf) else { return }

                if let previousIndex = oldIDs.firstIndex(of: selectedPerf) {
                    let fallbackIndex = min(previousIndex, newIDs.count - 1)
                    selectedPerf = newIDs[fallbackIndex]
                } else {
                    selectedPerf = newIDs[0]
                }
            }
        )
        let hoverObserved = AnyView(selectionObserved)
        return AnyView(
            hoverObserved
            .onReceive(NotificationCenter.default.publisher(for: .finderBarCommandTriggered)) { notification in
                handleFinderBarCommand(notification)
            }
            .onChange(of: selectedProcessPID) { _, _ in
                if selectedTab == .processes, selectedProcessPID != nil {
                    selectedProcessSectionKind = nil
                }
            }
            .onChange(of: compactMode) { _, _ in
                exitPerformanceSummaryIfNeeded()
                updateDiskRefreshPolicy()
                updateMonitorPresentation()
                normalizeKeyboardFocusArea()
                syncFinderBarCommandState()
                updateFinderBarForCompactMode()
                DispatchQueue.main.async {
                    resizeWindowIfNeeded(animated: true)
                }
            }
            .onChange(of: performanceViewMode) { _, _ in
                normalizeKeyboardFocusArea()
                resizeWindowIfNeeded(animated: true)
                updateWindowTrafficLights()
            }
            .onChange(of: selectedTab) { _, _ in
                exitPerformanceSummaryIfNeeded()
                updateDiskRefreshPolicy()
                updateMonitorPresentation()
                loadSelectedDiskDetailsIfNeeded()
                normalizeKeyboardFocusArea()
                reconcileSelectionForCurrentTab()
                updateWindowTrafficLights()
                resizeWindowIfNeeded(animated: true)
            }
            .onChange(of: selectedPerf) { _, _ in
                loadSelectedDiskDetailsIfNeeded()
            }
            .onChange(of: language) { _, newValue in
                monitor.language = newValue
                newTaskPanelManager.update(language: newValue)
                networkDetailsPanelManager.updateLanguage(newValue)
                aboutPanelManager.update(language: newValue)
                syncFinderBarCommandState()
            }
            .onChange(of: temperatureUnit) { _, newValue in
                monitor.temperatureUnit = newValue
                syncFinderBarCommandState()
            }
            .onChange(of: menuVisualStyleRawValue) { _, _ in
                syncFinderBarCommandState()
            }
            .onChange(of: alwaysOnTop) { _, _ in
                syncFinderBarCommandState()
            }
            .onChange(of: useSmallValues) { _, _ in
                syncFinderBarCommandState()
            }
            .onChange(of: hideWhenMinimized) { _, _ in
                syncFinderBarCommandState()
            }
            .onChange(of: monitor.refreshSpeed) { _, _ in
                syncFinderBarCommandState()
            }
        )
    }

    private var visualRootContent: some View {
        rootContent
            .background(WindowSurfaceBackground())
            .ignoresSafeArea(.container, edges: selectedTab == .performance && performanceViewMode != .full ? .all : .top)
            .alert(language.text("结束任务失败", "End task failed"), isPresented: taskActionErrorPresented) {
                Button(language.text("确定", "OK"), role: .cancel) {
                    taskActionErrorMessage = ""
                }
            } message: {
                Text(language.localizeRuntimeMessage(taskActionErrorMessage))
            }
            .background(keyHandlingLayer)
    }

    private var rootContent: some View {
        ZStack(alignment: .topLeading) {
            if compactTransitionInProgress {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if compactMode {
                    CompactModeContainer(
                        rows: compactApplicationRows,
                        selectedPID: $selectedProcessPID,
                        primaryActionTitle: primaryTaskActionTitle,
                        isMoreDetailsFocused: keyboardFocusArea == .compactMoreDetailsButton,
                        isPrimaryActionFocused: keyboardFocusArea == .compactPrimaryActionButton,
                        onToggleCompact: toggleCompactMode,
                        onPrimaryAction: performPrimaryTaskAction
                    )
                } else if selectedTab == .performance && performanceViewMode == .detailSummary {
                    PerformancePageView(
                        monitor: monitor,
                        selectedPerf: performanceSelectionBinding,
                        highlightedPerf: highlightedPerformanceSelection,
                        viewMode: $performanceViewMode,
                        showsGraphs: $showsPerformanceGraphs,
                        cpuGraphMode: $cpuGraphMode,
                        gpuGraphLayoutMode: $gpuGraphLayoutMode,
                        showsKernelTime: $showsKernelTime,
                        onOpenNetworkDetails: { networkDetailsPanelManager.show(network: $0, language: language) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if selectedTab == .performance && performanceViewMode == .summary {
                    PerformancePageView(
                        monitor: monitor,
                        selectedPerf: performanceSelectionBinding,
                        highlightedPerf: highlightedPerformanceSelection,
                        viewMode: $performanceViewMode,
                        showsGraphs: $showsPerformanceGraphs,
                        cpuGraphMode: $cpuGraphMode,
                        gpuGraphLayoutMode: $gpuGraphLayoutMode,
                        showsKernelTime: $showsKernelTime,
                        onOpenNetworkDetails: { networkDetailsPanelManager.show(network: $0, language: language) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        if menuVisualStyle == .windowsNT {
                            WindowChromeView(
                                selectedTab: $selectedTab,
                                activeMenu: $activeMenu
                            )
                        } else {
                            nativeWindowChrome
                        }

                        Group {
                            switch selectedTab {
                            case .processes:
                                ProcessesPageView(
                                    monitor: monitor,
                                    collapsedSections: $collapsedSections,
                                    selectedPID: $selectedProcessPID,
                                    selectedSectionKind: selectedProcessSectionKind,
                                    memoryDisplayMode: $processMemoryDisplayMode,
                                    diskDisplayMode: $processDiskDisplayMode,
                                    networkDisplayMode: $processNetworkDisplayMode,
                                    onEndTask: endTask(pid:),
                                    onRestartTask: restartProcess,
                                    onRevealInFinder: revealInFinder,
                                    onSearchWeb: searchWeb,
                                    onShowProperties: showProcessProperties,
                                    onCopyProcessDetails: copyProcessDetails,
                                    onOpenDetailsTab: openDetailsTab,
                                    sortKey: $processSortKey,
                                    ascending: $processSortAscending
                                )
                            case .performance:
                                PerformancePageView(
                                    monitor: monitor,
                                    selectedPerf: performanceSelectionBinding,
                                    highlightedPerf: highlightedPerformanceSelection,
                                    viewMode: $performanceViewMode,
                                    showsGraphs: $showsPerformanceGraphs,
                                    cpuGraphMode: $cpuGraphMode,
                                    gpuGraphLayoutMode: $gpuGraphLayoutMode,
                                    showsKernelTime: $showsKernelTime,
                                    onOpenNetworkDetails: { networkDetailsPanelManager.show(network: $0, language: language) }
                                )
                            case .history:
                                AppHistoryPageView(monitor: monitor)
                            case .startup:
                                StartupPageView(monitor: monitor)
                            case .users:
                                UsersPageView(
                                    monitor: monitor,
                                    selectedPID: $selectedProcessPID,
                                    memoryDisplayMode: $processMemoryDisplayMode,
                                    diskDisplayMode: $processDiskDisplayMode,
                                    networkDisplayMode: $processNetworkDisplayMode,
                                    onEndTask: endTask(pid:),
                                    onRestartTask: restartProcess,
                                    onRevealInFinder: revealInFinder,
                                    onSearchWeb: searchWeb,
                                    onShowProperties: showProcessProperties,
                                    onCopyProcessDetails: copyProcessDetails,
                                    onOpenDetailsTab: openDetailsTab
                                )
                            case .details:
                                DetailsPageView(
                                    monitor: monitor,
                                    selectedPID: $selectedProcessPID,
                                    memoryDisplayMode: $processMemoryDisplayMode,
                                    onEndTask: endTask(pid:),
                                    onEndProcessTree: endProcessTree(pid:),
                                    onRestartTask: restartProcess,
                                    onRevealInFinder: revealInFinder,
                                    onSearchWeb: searchWeb,
                                    onShowProperties: showProcessProperties,
                                    onCopyProcessDetails: copyProcessDetails,
                                    onOpenDetailsTab: openDetailsTab,
                                    onOpenServicesTab: openServicesTab,
                                    onSetPriority: setProcessPriority(pid:preset:)
                                )
                            case .services:
                                ServicesPageView(
                                    monitor: monitor,
                                    selectedPID: $selectedProcessPID,
                                    onStartService: startService,
                                    onStopService: stopService,
                                    onRestartService: restartService,
                                    onSearchWeb: searchWeb,
                                    onOpenDetailsTab: openDetailsTab
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        FooterBarView(
                            compactMode: $compactMode,
                            canEndTask: canEndSelectedTask,
                            primaryActionTitle: primaryTaskActionTitle,
                            isToggleFocused: keyboardFocusArea == .footerToggleCompact,
                            isPrimaryActionFocused: keyboardFocusArea == .footerPrimaryAction,
                            onToggleCompact: toggleCompactMode,
                            onPrimaryAction: performPrimaryTaskAction
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            if menuVisualStyle == .windowsNT, let activeMenu {
                menuOverlay(for: activeMenu)
                    .padding(.top, 56)
                    .padding(.leading, menuXOffset(for: activeMenu))
                    .zIndex(10)
            }
        }
    }

    private var keyHandlingLayer: some View {
        MenuKeyHandlingView(
            onAltF: { openMenu(.file) },
            onAltO: { openMenu(.options) },
            onAltV: { openMenu(.view) },
            onNavigationCommand: handleKeyboardNavigation,
            onControlChanged: { monitor.setTemporarilyPaused($0) },
            onCommandChanged: { commandKeyPressed = $0 }
        )
    }

    private func applySystemPresentationPreferences() {
        let systemLanguage = AppLanguage.defaultFromSystem()
        if language != systemLanguage {
            language = systemLanguage
        }
    }

    private var compactApplicationRows: [ProcessRowData] {
        monitor.processSections.first(where: { $0.kind == .apps })?.rows ?? []
    }

    private func setMenuVisualStyle(_ style: MenuVisualStyle) {
        menuVisualStyle = style
        activeMenu = nil
        resetMenuHoverState()
    }

    private var canEndSelectedTask: Bool {
        guard let pid = selectedProcessPID else { return false }
        if isFinderProcess(pid: pid) {
            return selectedProcessRow(pid: pid) != nil
        }
        return canTerminate(pid: pid)
    }

    private var primaryTaskActionTitle: String {
        guard let pid = selectedProcessPID else {
            return language.text("结束任务(E)", "End task(E)")
        }
        return isFinderProcess(pid: pid)
            ? language.text("重新启动(R)", "Restart(R)")
            : language.text("结束任务(E)", "End task(E)")
    }

    private var taskActionErrorPresented: Binding<Bool> {
        Binding(
            get: { !taskActionErrorMessage.isEmpty },
            set: { presented in
                if !presented {
                    taskActionErrorMessage = ""
                }
            }
        )
    }

    private func openMenu(_ menu: MenuKind) {
        guard menuVisualStyle == .windowsNT else { return }
        activeMenu = menu
        resetMenuHoverState()
        menuKeyboardContext = .main(menu)
        menuKeyboardIndex = 0
    }

    private var availableKeyboardFocusAreas: [KeyboardFocusArea] {
        if compactMode {
            return [.compactList, .compactMoreDetailsButton, .compactPrimaryActionButton]
        }

        if selectedTab == .performance {
            switch performanceViewMode {
            case .summary:
                return [.performanceSidebar]
            case .detailSummary:
                return [.performanceSidebar, .performanceDetail]
            case .full:
                return [.topTabs, .performanceSidebar, .performanceDetail, .footerToggleCompact, .footerPrimaryAction]
            }
        }

        if selectedTab == .processes {
            return [.topTabs, .processTable, .footerToggleCompact, .footerPrimaryAction]
        }

        return [.topTabs, .footerToggleCompact, .footerPrimaryAction]
    }

    private var defaultKeyboardFocusArea: KeyboardFocusArea {
        if compactMode {
            return .compactList
        }
        if selectedTab == .performance {
            return .performanceSidebar
        }
        if selectedTab == .processes {
            return .processTable
        }
        return .topTabs
    }

    private func normalizeKeyboardFocusArea() {
        let areas = availableKeyboardFocusAreas
        guard !areas.contains(keyboardFocusArea) else { return }
        keyboardFocusArea = defaultKeyboardFocusArea
    }

    private func handleKeyboardNavigation(_ command: KeyboardNavigationCommand) {
        if activeMenu != nil {
            handleMenuKeyboardNavigation(command)
            return
        }

        switch command {
        case .focusNext:
            focusNextArea()
        case .focusPrevious:
            focusPreviousArea()
        default:
            handleNavigationCommandInCurrentFocus(command)
        }
    }

    private func focusNextArea() {
        let areas = availableKeyboardFocusAreas
        guard !areas.isEmpty else { return }
        guard let currentIndex = areas.firstIndex(of: keyboardFocusArea) else {
            keyboardFocusArea = defaultKeyboardFocusArea
            return
        }
        keyboardFocusArea = areas[(currentIndex + 1) % areas.count]
    }

    private func focusPreviousArea() {
        let areas = availableKeyboardFocusAreas
        guard !areas.isEmpty else { return }
        guard let currentIndex = areas.firstIndex(of: keyboardFocusArea) else {
            keyboardFocusArea = defaultKeyboardFocusArea
            return
        }
        keyboardFocusArea = areas[(currentIndex - 1 + areas.count) % areas.count]
    }

    private func handleNavigationCommandInCurrentFocus(_ command: KeyboardNavigationCommand) {
        switch keyboardFocusArea {
        case .topTabs:
            handleTopTabsNavigation(command)
        case .compactList, .compactMoreDetailsButton, .compactPrimaryActionButton:
            handleCompactNavigation(command)
        case .performanceSidebar, .performanceDetail:
            handlePerformanceNavigation(command)
        case .processTable:
            handleProcessNavigation(command)
        case .footerToggleCompact, .footerPrimaryAction:
            handleFooterNavigation(command)
        }
    }

    private func handleTopTabsNavigation(_ command: KeyboardNavigationCommand) {
        switch command {
        case .moveLeft:
            cycleSelectedTab(step: -1)
        case .moveRight:
            cycleSelectedTab(step: 1)
        case .moveDown:
            keyboardFocusArea = nextPrimaryContentFocusArea()
        case .activatePrimary, .activateSecondary:
            break
        case .back:
            break
        case .cancel:
            activeMenu = nil
        default:
            break
        }
    }

    private func handleCompactNavigation(_ command: KeyboardNavigationCommand) {
        switch keyboardFocusArea {
        case .compactList:
            switch command {
            case .moveUp:
                moveCompactSelection(step: -1)
            case .moveDown:
                moveCompactSelection(step: 1)
            case .moveLeft:
                cycleSelectedTab(step: -1)
            case .moveRight:
                cycleSelectedTab(step: 1)
            case .activatePrimary, .activateSecondary:
                toggleCompactMode()
            default:
                break
            }
        case .compactMoreDetailsButton:
            switch command {
            case .moveLeft:
                cycleSelectedTab(step: -1)
            case .moveRight:
                cycleSelectedTab(step: 1)
            case .moveUp, .back:
                keyboardFocusArea = .compactList
            case .activatePrimary, .activateSecondary:
                toggleCompactMode()
            default:
                break
            }
        case .compactPrimaryActionButton:
            switch command {
            case .moveLeft:
                cycleSelectedTab(step: -1)
            case .moveRight:
                cycleSelectedTab(step: 1)
            case .moveUp, .back:
                keyboardFocusArea = .compactList
            case .activatePrimary, .activateSecondary:
                performPrimaryTaskAction()
            default:
                break
            }
        default:
            break
        }
    }

    private func handlePerformanceNavigation(_ command: KeyboardNavigationCommand) {
        switch keyboardFocusArea {
        case .performanceSidebar:
            switch command {
            case .moveUp:
                movePerformanceSelection(step: -1)
            case .moveDown:
                movePerformanceSelection(step: 1)
            case .moveLeft:
                cycleSelectedTab(step: -1)
            case .moveRight:
                cycleSelectedTab(step: 1)
            case .activatePrimary, .activateSecondary:
                if performanceViewMode != .summary {
                    keyboardFocusArea = .performanceDetail
                }
            default:
                break
            }
        case .performanceDetail:
            switch command {
            case .moveLeft:
                cycleSelectedTab(step: -1)
            case .moveRight:
                cycleSelectedTab(step: 1)
            default:
                break
            }
        default:
            break
        }
    }

    private func handleProcessNavigation(_ command: KeyboardNavigationCommand) {
        let items = processKeyboardItems
        guard !items.isEmpty else { return }

        if currentProcessKeyboardItem == nil {
            applyProcessKeyboardSelection(items[0])
        }

        switch command {
        case .moveUp:
            moveProcessSelection(step: -1)
        case .moveDown:
            moveProcessSelection(step: 1)
        case .moveLeft:
            cycleSelectedTab(step: -1)
        case .moveRight:
            cycleSelectedTab(step: 1)
        case .activatePrimary, .activateSecondary:
            handleProcessActivate()
        case .back:
            handleProcessMoveLeft()
        default:
            break
        }
    }

    private func handleFooterNavigation(_ command: KeyboardNavigationCommand) {
        switch keyboardFocusArea {
        case .footerToggleCompact:
            switch command {
            case .moveLeft:
                cycleSelectedTab(step: -1)
            case .moveRight:
                cycleSelectedTab(step: 1)
            case .moveUp, .back:
                keyboardFocusArea = nextPrimaryContentFocusArea()
            case .activatePrimary, .activateSecondary:
                toggleCompactMode()
            default:
                break
            }
        case .footerPrimaryAction:
            switch command {
            case .moveLeft:
                cycleSelectedTab(step: -1)
            case .moveRight:
                cycleSelectedTab(step: 1)
            case .moveUp, .back:
                keyboardFocusArea = nextPrimaryContentFocusArea()
            case .activatePrimary, .activateSecondary:
                performPrimaryTaskAction()
            default:
                break
            }
        default:
            break
        }
    }

    private func handleMenuKeyboardNavigation(_ command: KeyboardNavigationCommand) {
        guard let context = menuKeyboardContext ?? activeMenu.map({ .main($0) }) else { return }

        switch command {
        case .moveUp:
            moveMenuKeyboardSelection(in: context, step: -1)
        case .moveDown:
            moveMenuKeyboardSelection(in: context, step: 1)
        case .activatePrimary, .activateSecondary:
            activateMenuKeyboardSelection(in: context)
        case .back:
            handleMenuKeyboardBack(from: context)
        case .cancel:
            activeMenu = nil
        default:
            break
        }
    }

    private func moveMenuKeyboardSelection(in context: MenuKeyboardContext, step: Int) {
        let count = menuKeyboardItemCount(for: context)
        guard count > 0 else { return }
        if menuKeyboardContext != context {
            menuKeyboardContext = context
            menuKeyboardIndex = 0
            return
        }
        menuKeyboardIndex = (menuKeyboardIndex + step + count) % count
    }

    private func menuKeyboardItemCount(for context: MenuKeyboardContext) -> Int {
        switch context {
        case .main(.file):
            return 2
        case .main(.options):
            return 6
        case .main(.view):
            return 4
        case .optionsSubmenu(.language):
            return 2
        case .optionsSubmenu(.temperatureUnit):
            return 2
        case .optionsSubmenu(.menuStyle):
            return MenuVisualStyle.allCases.count
        case .viewSubmenu(.refreshSpeed):
            return RefreshSpeedOption.allCases.count
        }
    }

    private func isMenuKeyboardFocused(_ context: MenuKeyboardContext, index: Int) -> Bool {
        menuKeyboardContext == context && menuKeyboardIndex == index
    }

    private func activateMenuKeyboardSelection(in context: MenuKeyboardContext) {
        switch context {
        case .main(.file):
            switch menuKeyboardIndex {
            case 0:
                if commandKeyPressed {
                    openNewTerminalWindow()
                } else {
                    newTaskPanelManager.show(language: language)
                }
                activeMenu = nil
            case 1:
                NSApp.terminate(nil)
            default:
                break
            }
        case .main(.options):
            switch menuKeyboardIndex {
            case 0:
                alwaysOnTop.toggle()
                activeMenu = nil
            case 1:
                useSmallValues.toggle()
                activeMenu = nil
            case 2:
                hideWhenMinimized.toggle()
                activeMenu = nil
            case 3:
                activeOptionsSubmenu = .language
                menuKeyboardContext = .optionsSubmenu(.language)
                menuKeyboardIndex = 0
            case 4:
                activeOptionsSubmenu = .temperatureUnit
                menuKeyboardContext = .optionsSubmenu(.temperatureUnit)
                menuKeyboardIndex = 0
            case 5:
                activeOptionsSubmenu = .menuStyle
                menuKeyboardContext = .optionsSubmenu(.menuStyle)
                menuKeyboardIndex = 0
            default:
                break
            }
        case .main(.view):
            switch menuKeyboardIndex {
            case 0:
                monitor.refreshNow()
                activeMenu = nil
            case 1:
                activeViewSubmenu = .refreshSpeed
                menuKeyboardContext = .viewSubmenu(.refreshSpeed)
                menuKeyboardIndex = 0
            case 2:
                collapsedSections.removeAll()
                activeMenu = nil
            case 3:
                collapsedSections = Set(monitor.processSections.map(\.kind))
                activeMenu = nil
            default:
                break
            }
        case .optionsSubmenu(.language):
            language = menuKeyboardIndex == 0 ? .chinese : .english
            activeOptionsSubmenu = nil
            activeMenu = nil
        case .optionsSubmenu(.temperatureUnit):
            temperatureUnit = menuKeyboardIndex == 0 ? .celsius : .fahrenheit
            activeOptionsSubmenu = nil
            activeMenu = nil
        case .optionsSubmenu(.menuStyle):
            let styles = MenuVisualStyle.allCases
            guard styles.indices.contains(menuKeyboardIndex) else { return }
            setMenuVisualStyle(styles[menuKeyboardIndex])
            activeOptionsSubmenu = nil
            activeMenu = nil
        case .viewSubmenu(.refreshSpeed):
            let options = RefreshSpeedOption.allCases
            guard options.indices.contains(menuKeyboardIndex) else { return }
            monitor.setRefreshSpeed(options[menuKeyboardIndex])
            activeViewSubmenu = nil
            activeMenu = nil
        }
    }

    private func handleMenuKeyboardBack(from context: MenuKeyboardContext) {
        switch context {
        case .main:
            activeMenu = nil
        case .optionsSubmenu(let submenu):
            activeOptionsSubmenu = nil
            menuKeyboardContext = .main(.options)
            menuKeyboardIndex = menuKeyboardMainIndex(for: submenu)
        case .viewSubmenu(.refreshSpeed):
            activeViewSubmenu = nil
            menuKeyboardContext = .main(.view)
            menuKeyboardIndex = 1
        }
    }

    private func menuKeyboardMainIndex(for submenu: OptionsSubmenuKind) -> Int {
        switch submenu {
        case .language:
            return 3
        case .temperatureUnit:
            return 4
        case .menuStyle:
            return 5
        }
    }

    private func nextPrimaryContentFocusArea() -> KeyboardFocusArea {
        if compactMode {
            return .compactList
        }
        if selectedTab == .performance {
            return .performanceSidebar
        }
        if selectedTab == .processes {
            return .processTable
        }
        return .topTabs
    }

    private func cycleSelectedTab(step: Int) {
        let tabs = TaskTab.allCases
        guard let currentIndex = tabs.firstIndex(of: selectedTab) else { return }
        let nextIndex = (currentIndex + step + tabs.count) % tabs.count
        selectedTab = tabs[nextIndex]
    }

    private func moveCompactSelection(step: Int) {
        guard !compactApplicationRows.isEmpty else { return }
        let currentIndex = compactApplicationRows.firstIndex(where: { $0.pid == selectedProcessPID }) ?? 0
        let nextIndex = max(0, min(currentIndex + step, compactApplicationRows.count - 1))
        selectedProcessPID = compactApplicationRows[nextIndex].pid
    }

    private var sortedProcessSectionsForKeyboard: [ProcessSectionData] {
        monitor.processSections.map { section in
            ProcessSectionData(kind: section.kind, rows: section.rows.sorted(by: compareProcessRowsForKeyboard))
        }
    }

    private var processKeyboardItems: [ProcessKeyboardItem] {
        var items: [ProcessKeyboardItem] = []
        for section in sortedProcessSectionsForKeyboard {
            items.append(.section(section.kind))
            if !collapsedSections.contains(section.kind) {
                items.append(contentsOf: section.rows.map { .row(section.kind, $0.pid) })
            }
        }
        return items
    }

    private var currentProcessKeyboardItem: ProcessKeyboardItem? {
        if let sectionKind = selectedProcessSectionKind {
            return .section(sectionKind)
        }
        if let pid = selectedProcessPID,
           let item = processKeyboardItems.first(where: {
               if case .row(_, let rowPID) = $0 {
                   return rowPID == pid
               }
               return false
           }) {
            return item
        }
        return nil
    }

    private func applyProcessKeyboardSelection(_ item: ProcessKeyboardItem) {
        switch item {
        case .section(let kind):
            selectedProcessSectionKind = kind
            selectedProcessPID = nil
        case .row(_, let pid):
            selectedProcessSectionKind = nil
            selectedProcessPID = pid
        }
    }

    private func moveProcessSelection(step: Int) {
        let items = processKeyboardItems
        guard !items.isEmpty else { return }
        let currentIndex = currentProcessKeyboardItem.flatMap { current in
            items.firstIndex(of: current)
        } ?? 0
        let nextIndex = max(0, min(currentIndex + step, items.count - 1))
        applyProcessKeyboardSelection(items[nextIndex])
    }

    private func handleProcessMoveLeft() {
        guard let selection = currentProcessKeyboardItem else { return }
        switch selection {
        case .section(let kind):
            if !collapsedSections.contains(kind) {
                collapsedSections.insert(kind)
            }
        case .row(let kind, _):
            selectedProcessSectionKind = kind
            selectedProcessPID = nil
        }
    }

    private func handleProcessActivate() {
        guard let selection = currentProcessKeyboardItem else { return }
        switch selection {
        case .section(let kind):
            if collapsedSections.contains(kind) {
                collapsedSections.remove(kind)
            } else {
                collapsedSections.insert(kind)
            }
        case .row(_, let pid):
            openDetailsTab(pid)
        }
    }

    private func movePerformanceSelection(step: Int) {
        let items = monitor.sidebarItems.map(\.id)
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex(of: selectedPerf) ?? 0
        let nextIndex = max(0, min(currentIndex + step, items.count - 1))
        requestPerformanceSelection(items[nextIndex])
    }

    private func compareProcessRowsForKeyboard(_ lhs: ProcessRowData, _ rhs: ProcessRowData) -> Bool {
        let result: Bool
        switch processSortKey {
        case .name:
            result = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .status:
            result = true
        case .cpu:
            result = lhs.cpuPercent < rhs.cpuPercent
        case .memory:
            result = lhs.memoryBytes < rhs.memoryBytes
        case .disk:
            result = lhs.diskBytesPerSecond < rhs.diskBytesPerSecond
        case .network:
            result = lhs.networkBytesPerSecond < rhs.networkBytesPerSecond
        case .power:
            result = lhs.powerUsageWatts < rhs.powerUsageWatts
        case .trend:
            result = lhs.powerTrendWatts < rhs.powerTrendWatts
        }
        return processSortAscending ? result : !result
    }

    private func updateFinderBarForCompactMode() {
        DispatchQueue.main.async {
            (NSApp.delegate as? AppDelegate)?.updateFinderBarMenuVisibility(isCompactMode: compactMode)
        }
    }

    private var shouldRefreshDisksForCurrentPresentation: Bool {
        !compactMode && selectedTab == .performance
    }

    private var performanceSelectionBinding: Binding<PerfSelection> {
        Binding(
            get: { selectedPerf },
            set: { requestPerformanceSelection($0) }
        )
    }

    private var highlightedPerformanceSelection: PerfSelection {
        pendingPerformanceSelection ?? selectedPerf
    }

    private func updateDiskRefreshPolicy() {
        monitor.setDiskRefreshEnabled(shouldRefreshDisksForCurrentPresentation)
    }

    private func updateMonitorPresentation() {
        monitor.setPresentation(tab: selectedTab, compactMode: compactMode)
    }

    private func loadSelectedDiskDetailsIfNeeded() {
        guard shouldRefreshDisksForCurrentPresentation else { return }
        guard case .disk(let diskID) = selectedPerf else { return }
        Task { @MainActor in
            _ = await monitor.loadDetailedDiskMetadataInBackground(forDiskID: diskID)
        }
    }

    private func requestPerformanceSelection(_ newSelection: PerfSelection) {
        guard shouldRefreshDisksForCurrentPresentation else {
            pendingPerformanceSelection = nil
            selectedPerf = newSelection
            return
        }

        guard case .disk(let diskID) = newSelection else {
            pendingPerformanceSelection = nil
            selectedPerf = newSelection
            return
        }

        if monitor.hasDetailedDiskMetadata(forDiskID: diskID) {
            pendingPerformanceSelection = nil
            selectedPerf = newSelection
            return
        }

        pendingPerformanceSelection = newSelection
        Task { @MainActor in
            let loaded = await monitor.loadDetailedDiskMetadataInBackground(forDiskID: diskID)
            guard pendingPerformanceSelection == newSelection else { return }
            pendingPerformanceSelection = nil
            if loaded {
                selectedPerf = newSelection
            }
        }
    }

    private func syncFinderBarCommandState() {
        finderBarCommandState.sync(
            language: language,
            temperatureUnit: temperatureUnit,
            menuVisualStyle: menuVisualStyle,
            alwaysOnTop: alwaysOnTop,
            useSmallValues: useSmallValues,
            hideWhenMinimized: hideWhenMinimized,
            refreshSpeed: monitor.refreshSpeed,
            compactMode: compactMode
        )
    }

    private func handleFinderBarCommand(_ notification: Notification) {
        guard
            let rawValue = notification.userInfo?["command"] as? String,
            let command = FinderBarCommand(rawValue: rawValue)
        else { return }

        switch command {
        case .runNewTask:
            newTaskPanelManager.show(language: language)
        case .showAbout:
            aboutPanelManager.show(language: language)
        case .quitApp:
            NSApp.terminate(nil)
        case .toggleAlwaysOnTop:
            alwaysOnTop.toggle()
        case .toggleUseSmallValues:
            useSmallValues.toggle()
        case .toggleHideWhenMinimized:
            hideWhenMinimized.toggle()
        case .refreshNow:
            monitor.refreshNow()
        case .expandAll:
            collapsedSections.removeAll()
        case .collapseAll:
            collapsedSections = Set(monitor.processSections.map(\.kind))
        case .setLanguage:
            if let value = notification.userInfo?["value"] as? String,
               let nextLanguage = AppLanguage(rawValue: value) {
                language = nextLanguage
            }
        case .setTemperatureUnit:
            if let value = notification.userInfo?["value"] as? String,
               let nextUnit = TemperatureUnit(rawValue: value) {
                temperatureUnit = nextUnit
            }
        case .setMenuVisualStyle:
            if let value = notification.userInfo?["value"] as? String,
               let nextStyle = MenuVisualStyle(rawValue: value) {
                setMenuVisualStyle(nextStyle)
            }
        case .setRefreshSpeed:
            if let value = notification.userInfo?["value"] as? String,
               let nextSpeed = RefreshSpeedOption(rawValue: value) {
                monitor.setRefreshSpeed(nextSpeed)
            }
        }
    }

    private func resetMenuHoverState() {
        hoveredOptionsSubmenuParent = nil
        optionsSubmenuHovered = false
        activeOptionsSubmenu = nil
        hoveredViewSubmenuParent = nil
        viewSubmenuHovered = false
        activeViewSubmenu = nil
        menuKeyboardContext = activeMenu.map { .main($0) }
        menuKeyboardIndex = 0
    }

    private enum OptionsSubmenuKind {
        case language
        case temperatureUnit
        case menuStyle
    }

    private enum MenuKeyboardContext: Equatable {
        case main(MenuKind)
        case optionsSubmenu(OptionsSubmenuKind)
        case viewSubmenu(ViewSubmenuKind)
    }

    private func activateOptionsSubmenu(_ kind: OptionsSubmenuKind) {
        hoveredOptionsSubmenuParent = kind
        activeOptionsSubmenu = kind
    }

    private func setOptionsSubmenuParentHover(_ kind: OptionsSubmenuKind, hovering: Bool) {
        if hovering {
            hoveredOptionsSubmenuParent = kind
            activeOptionsSubmenu = kind
        } else if hoveredOptionsSubmenuParent == kind {
            hoveredOptionsSubmenuParent = nil
            scheduleOptionsSubmenuCloseIfNeeded()
        }
    }

    private func setOptionsSubmenuHover(_ hovering: Bool) {
        optionsSubmenuHovered = hovering
        if !hovering {
            scheduleOptionsSubmenuCloseIfNeeded()
        }
    }

    private func scheduleOptionsSubmenuCloseIfNeeded() {
        DispatchQueue.main.async {
            guard hoveredOptionsSubmenuParent == nil, !optionsSubmenuHovered else { return }
            activeOptionsSubmenu = nil
        }
    }

    private enum ViewSubmenuKind {
        case refreshSpeed
    }

    private func activateViewSubmenu(_ kind: ViewSubmenuKind) {
        hoveredViewSubmenuParent = kind
        activeViewSubmenu = kind
    }

    private func setViewSubmenuParentHover(_ kind: ViewSubmenuKind, hovering: Bool) {
        if hovering {
            hoveredViewSubmenuParent = kind
            activeViewSubmenu = kind
        } else if hoveredViewSubmenuParent == kind {
            hoveredViewSubmenuParent = nil
            scheduleViewSubmenuCloseIfNeeded()
        }
    }

    private func setViewSubmenuHover(_ hovering: Bool) {
        viewSubmenuHovered = hovering
        if !hovering {
            scheduleViewSubmenuCloseIfNeeded()
        }
    }

    private func scheduleViewSubmenuCloseIfNeeded() {
        DispatchQueue.main.async {
            guard hoveredViewSubmenuParent == nil, !viewSubmenuHovered else { return }
            activeViewSubmenu = nil
        }
    }

    private func menuXOffset(for menu: MenuKind) -> CGFloat {
        let baseX: CGFloat = 14
        let chromeMenuSpacing: CGFloat = 16
        let chromeButtonHorizontalPadding: CGFloat = 4

        func chromeButtonWidth(_ title: String) -> CGFloat {
            ceil(textWidth(title, size: 14) + chromeButtonHorizontalPadding)
        }

        let fileWidth = chromeButtonWidth(language.text("文件(F)", "File(F)"))
        let optionsWidth = chromeButtonWidth(language.text("选项(O)", "Options(O)"))

        switch menu {
        case .file:
            return baseX
        case .options:
            return baseX + fileWidth + chromeMenuSpacing
        case .view:
            return baseX + fileWidth + chromeMenuSpacing + optionsWidth + chromeMenuSpacing
        }
    }

    private var menuRowHeight: CGFloat { 28 }
    private var menuDividerHeight: CGFloat { 1 }
    private var submenuGap: CGFloat { 0 }
    private var menuHorizontalPadding: CGFloat { 10 }
    private var menuItemSpacing: CGFloat { 8 }
    private var menuLeadingIconWidth: CGFloat { 12 }
    private var menuChevronWidth: CGFloat { 10 }
    private var menuTrailingInset: CGFloat { 12 }
    private var menuMinimumWidth: CGFloat { 120 }
    private var menuWidthSlack: CGFloat { 22 }

    private func submenuTopOffset(rowIndex: Int, dividerCountBefore: Int = 0) -> CGFloat {
        (CGFloat(rowIndex) * menuRowHeight) + (CGFloat(dividerCountBefore) * menuDividerHeight) - 1
    }

    private func textWidth(
        _ text: String,
        size: CGFloat = 13,
        weight: NSFont.Weight = .regular
    ) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight)
        ]
        return ceil((text as NSString).size(withAttributes: attributes).width)
    }

    private func plainMenuRowWidth(_ title: String, altHint: String? = nil) -> CGFloat {
        var width = (menuHorizontalPadding * 2) + menuLeadingIconWidth + menuItemSpacing + textWidth(title)
        if let altHint {
            width += menuItemSpacing + textWidth(altHint, size: 12)
        } else {
            width += menuTrailingInset
        }
        return ceil(width + menuWidthSlack)
    }

    private func submenuTriggerWidth(_ title: String) -> CGFloat {
        let width =
            (menuHorizontalPadding * 2) +
            menuLeadingIconWidth +
            menuItemSpacing +
            textWidth(title) +
            menuItemSpacing +
            menuChevronWidth +
            menuTrailingInset
        return ceil(width + menuWidthSlack)
    }

    private func checkableMenuRowWidth(_ title: String) -> CGFloat {
        ceil((menuHorizontalPadding * 2) + menuLeadingIconWidth + menuItemSpacing + textWidth(title) + menuTrailingInset + menuWidthSlack)
    }

    private func menuPanelWidth(for menu: MenuKind) -> CGFloat {
        switch menu {
        case .file:
            return max(
                menuMinimumWidth,
                plainMenuRowWidth(language.text("运行新任务(N)", "Run new task(N)")),
                plainMenuRowWidth(language.text("退出(X)", "Exit(X)"))
            )
        case .options:
            return max(
                menuMinimumWidth,
                checkableMenuRowWidth(language.text("置于顶层(A)", "Always on top(A)")),
                checkableMenuRowWidth(language.text("使用小值(U)", "Use small values(U)")),
                checkableMenuRowWidth(language.text("最小化时隐藏(H)", "Hide when minimized(H)")),
                submenuTriggerWidth(language.text("语言", "Language")),
                submenuTriggerWidth(language.text("温度单位", "Temperature unit")),
                submenuTriggerWidth(language.text("菜单风格", "Menu style"))
            )
        case .view:
            return max(
                menuMinimumWidth,
                plainMenuRowWidth(language.text("立即刷新(R)", "Refresh now(R)")),
                submenuTriggerWidth(language.text("更新速度(U)", "Update speed(U)")),
                plainMenuRowWidth(language.text("全部展开(E)", "Expand all(E)")),
                plainMenuRowWidth(language.text("全部折叠(C)", "Collapse all(C)"))
            )
        }
    }

    private var refreshSpeedSubmenuWidth: CGFloat {
        max(
            menuMinimumWidth,
            RefreshSpeedOption.allCases.map { checkableMenuRowWidth($0.title(in: language)) }.max() ?? menuMinimumWidth
        )
    }

    private var languageSubmenuWidth: CGFloat {
        max(
            menuMinimumWidth,
            checkableMenuRowWidth("中文"),
            checkableMenuRowWidth("English")
        )
    }

    private var temperatureUnitSubmenuWidth: CGFloat {
        max(
            menuMinimumWidth,
            checkableMenuRowWidth(language.text("摄氏度°C", "Celsius °C")),
            checkableMenuRowWidth(language.text("华氏度°F", "Fahrenheit °F"))
        )
    }

    private var menuStyleSubmenuWidth: CGFloat {
        max(
            menuMinimumWidth,
            MenuVisualStyle.allCases.map { checkableMenuRowWidth($0.title(in: language)) }.max() ?? menuMinimumWidth
        )
    }

    @ViewBuilder
    private func menuOverlay(for menu: MenuKind) -> some View {
        switch menu {
        case .file:
            menuPanel(for: .file) {
                menuItem(language.text("运行新任务(N)", "Run new task(N)"), altHint: nil, highlighted: isMenuKeyboardFocused(.main(.file), index: 0)) {
                    if commandKeyPressed {
                        openNewTerminalWindow()
                    } else {
                        newTaskPanelManager.show(language: language)
                    }
                    activeMenu = nil
                }
                Divider()
                menuItem(language.text("退出(X)", "Exit(X)"), altHint: nil, highlighted: isMenuKeyboardFocused(.main(.file), index: 1)) {
                    NSApp.terminate(nil)
                }
            }
        case .options:
            ZStack(alignment: .topLeading) {
                menuPanel(for: .options) {
                    checkableMenuItem(language.text("置于顶层(A)", "Always on top(A)"), checked: alwaysOnTop, highlighted: isMenuKeyboardFocused(.main(.options), index: 0)) {
                        alwaysOnTop.toggle()
                        activeMenu = nil
                    }
                    checkableMenuItem(language.text("使用小值(U)", "Use small values(U)"), checked: useSmallValues, highlighted: isMenuKeyboardFocused(.main(.options), index: 1)) {
                        useSmallValues.toggle()
                        activeMenu = nil
                    }
                    checkableMenuItem(language.text("最小化时隐藏(H)", "Hide when minimized(H)"), checked: hideWhenMinimized, highlighted: isMenuKeyboardFocused(.main(.options), index: 2)) {
                        hideWhenMinimized.toggle()
                        activeMenu = nil
                    }
                    Divider()
                    optionsSubmenuItem(
                        language.text("语言", "Language"),
                        expanded: activeOptionsSubmenu == .language || isMenuKeyboardFocused(.main(.options), index: 3),
                        action: { activateOptionsSubmenu(.language) },
                        onParentHover: { setOptionsSubmenuParentHover(.language, hovering: $0) }
                    )
                    optionsSubmenuItem(
                        language.text("温度单位", "Temperature unit"),
                        expanded: activeOptionsSubmenu == .temperatureUnit || isMenuKeyboardFocused(.main(.options), index: 4),
                        action: { activateOptionsSubmenu(.temperatureUnit) },
                        onParentHover: { setOptionsSubmenuParentHover(.temperatureUnit, hovering: $0) }
                    )
                    optionsSubmenuItem(
                        language.text("菜单风格", "Menu style"),
                        expanded: activeOptionsSubmenu == .menuStyle || isMenuKeyboardFocused(.main(.options), index: 5),
                        action: { activateOptionsSubmenu(.menuStyle) },
                        onParentHover: { setOptionsSubmenuParentHover(.menuStyle, hovering: $0) }
                    )
                }

                if let activeOptionsSubmenu {
                    optionsSubmenuOverlay(for: activeOptionsSubmenu)
                        .offset(
                            x: menuPanelWidth(for: .options) + submenuGap,
                            y: optionsSubmenuYOffset(for: activeOptionsSubmenu)
                        )
                        .zIndex(20)
                }
            }
        case .view:
            ZStack(alignment: .topLeading) {
                menuPanel(for: .view) {
                    menuItem(language.text("立即刷新(R)", "Refresh now(R)"), altHint: nil, highlighted: isMenuKeyboardFocused(.main(.view), index: 0)) {
                        monitor.refreshNow()
                        activeMenu = nil
                    }
                    optionsSubmenuItem(
                        language.text("更新速度(U)", "Update speed(U)"),
                        expanded: activeViewSubmenu == .refreshSpeed || isMenuKeyboardFocused(.main(.view), index: 1),
                        action: { activateViewSubmenu(.refreshSpeed) },
                        onParentHover: { setViewSubmenuParentHover(.refreshSpeed, hovering: $0) }
                    )
                    Divider()
                    menuItem(language.text("全部展开(E)", "Expand all(E)"), altHint: nil, highlighted: isMenuKeyboardFocused(.main(.view), index: 2)) {
                        collapsedSections.removeAll()
                        activeMenu = nil
                    }
                    menuItem(language.text("全部折叠(C)", "Collapse all(C)"), altHint: nil, highlighted: isMenuKeyboardFocused(.main(.view), index: 3)) {
                        collapsedSections = Set(monitor.processSections.map(\.kind))
                        activeMenu = nil
                    }
                }

                if let activeViewSubmenu {
                    viewSubmenuOverlay(for: activeViewSubmenu)
                        .offset(
                            x: menuPanelWidth(for: .view) + submenuGap,
                            y: viewSubmenuYOffset(for: activeViewSubmenu)
                        )
                        .zIndex(20)
                }
            }
        }
    }

    private var refreshSpeedSubmenu: some View {
        VStack(spacing: 0) {
            ForEach(Array(RefreshSpeedOption.allCases.enumerated()), id: \.element.id) { index, option in
                Button {
                    monitor.setRefreshSpeed(option)
                    activeViewSubmenu = nil
                    activeMenu = nil
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: monitor.refreshSpeed == option ? "checkmark" : "")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 12)
                        Text(option.title(in: language))
                            .font(.system(size: 13))
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(WinMenuButtonStyle(isHighlighted: isMenuKeyboardFocused(.viewSubmenu(.refreshSpeed), index: index)))
            }
        }
        .frame(width: refreshSpeedSubmenuWidth)
        .winMenuPanel()
        .onHover(perform: setViewSubmenuHover)
    }

    private var languageMenu: some View {
        VStack(spacing: 0) {
            Button {
                language = .chinese
                activeOptionsSubmenu = nil
                activeMenu = nil
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: language == .chinese ? "checkmark" : "")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 12)
                    Text("中文")
                        .font(.system(size: 13))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
            }
            .buttonStyle(WinMenuButtonStyle(isHighlighted: isMenuKeyboardFocused(.optionsSubmenu(.language), index: 0)))

            Button {
                language = .english
                activeOptionsSubmenu = nil
                activeMenu = nil
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: language == .english ? "checkmark" : "")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 12)
                    Text("English")
                        .font(.system(size: 13))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
            }
            .buttonStyle(WinMenuButtonStyle(isHighlighted: isMenuKeyboardFocused(.optionsSubmenu(.language), index: 1)))
        }
        .frame(width: languageSubmenuWidth)
        .winMenuPanel()
        .onHover(perform: setOptionsSubmenuHover)
    }

    private var temperatureUnitMenu: some View {
        VStack(spacing: 0) {
            Button {
                temperatureUnit = .celsius
                activeOptionsSubmenu = nil
                activeMenu = nil
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: temperatureUnit == .celsius ? "checkmark" : "")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 12)
                    Text(language.text("摄氏度°C", "Celsius °C"))
                        .font(.system(size: 13))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
            }
            .buttonStyle(WinMenuButtonStyle(isHighlighted: isMenuKeyboardFocused(.optionsSubmenu(.temperatureUnit), index: 0)))

            Button {
                temperatureUnit = .fahrenheit
                activeOptionsSubmenu = nil
                activeMenu = nil
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: temperatureUnit == .fahrenheit ? "checkmark" : "")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 12)
                    Text(language.text("华氏度°F", "Fahrenheit °F"))
                        .font(.system(size: 13))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
            }
            .buttonStyle(WinMenuButtonStyle(isHighlighted: isMenuKeyboardFocused(.optionsSubmenu(.temperatureUnit), index: 1)))
        }
        .frame(width: temperatureUnitSubmenuWidth)
        .winMenuPanel()
        .onHover(perform: setOptionsSubmenuHover)
    }

    private var menuStyleMenu: some View {
        VStack(spacing: 0) {
            ForEach(Array(MenuVisualStyle.allCases.enumerated()), id: \.element.id) { index, style in
                Button {
                    setMenuVisualStyle(style)
                    activeOptionsSubmenu = nil
                    activeMenu = nil
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: menuVisualStyle == style ? "checkmark" : "")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 12)
                        Text(style.title(in: language))
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                }
                .buttonStyle(WinMenuButtonStyle(isHighlighted: isMenuKeyboardFocused(.optionsSubmenu(.menuStyle), index: index)))
            }
        }
        .frame(width: menuStyleSubmenuWidth)
        .winMenuPanel()
        .onHover(perform: setOptionsSubmenuHover)
    }

    private func menuPanel<Content: View>(for menu: MenuKind, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .frame(width: menuPanelWidth(for: menu))
            .winMenuPanel()
    }

    private func menuItem(_ title: String, altHint: String?, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                Spacer()
                if let altHint {
                    Text(altHint)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .interactiveHitTarget()
        }
        .buttonStyle(WinMenuButtonStyle(isHighlighted: highlighted))
    }

    private func disabledMenuItem(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private func checkableMenuItem(_ title: String, checked: Bool, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: checked ? "checkmark" : "")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .interactiveHitTarget()
        }
        .buttonStyle(WinMenuButtonStyle(isHighlighted: highlighted))
    }

    private func subMenuItem<Content: View>(
        _ title: String,
        expanded: Bool,
        @ViewBuilder content: () -> Content,
        action: @escaping () -> Void,
        onParentHover: @escaping (Bool) -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: menuRowHeight)
            .interactiveHitTarget()
        }
        .buttonStyle(WinMenuButtonStyle(isHighlighted: expanded))
        .onHover(perform: onParentHover)
        .overlay(alignment: .topLeading) {
            if expanded {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: menuRowHeight, alignment: .topLeading)
        .zIndex(expanded ? 50 : 0)
    }

    private func optionsSubmenuItem(
        _ title: String,
        expanded: Bool,
        action: @escaping () -> Void,
        onParentHover: @escaping (Bool) -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 28)
                .interactiveHitTarget()
            }
            .buttonStyle(WinMenuButtonStyle(isHighlighted: expanded))
            .onHover(perform: onParentHover)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: menuRowHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private func optionsSubmenuOverlay(for kind: OptionsSubmenuKind) -> some View {
        switch kind {
        case .language:
            languageMenu
        case .temperatureUnit:
            temperatureUnitMenu
        case .menuStyle:
            menuStyleMenu
        }
    }

    private func optionsSubmenuYOffset(for kind: OptionsSubmenuKind) -> CGFloat {
        switch kind {
        case .language:
            return submenuTopOffset(rowIndex: 3, dividerCountBefore: 1)
        case .temperatureUnit:
            return submenuTopOffset(rowIndex: 4, dividerCountBefore: 1)
        case .menuStyle:
            return submenuTopOffset(rowIndex: 5, dividerCountBefore: 1)
        }
    }

    @ViewBuilder
    private func viewSubmenuOverlay(for kind: ViewSubmenuKind) -> some View {
        switch kind {
        case .refreshSpeed:
            refreshSpeedSubmenu
        }
    }

    private func viewSubmenuYOffset(for kind: ViewSubmenuKind) -> CGFloat {
        switch kind {
        case .refreshSpeed:
            return submenuTopOffset(rowIndex: 1)
        }
    }

    private func updateWindowLevel(alwaysOnTop: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        window.level = alwaysOnTop ? .floating : .normal
    }

    private func toggleCompactMode() {
        compactTransitionInProgress = true
        compactMode.toggle()
    }

    private var currentWindowPresentationMode: WindowPresentationMode {
        if compactMode {
            return .compact
        }
        if selectedTab == .performance && performanceViewMode == .summary {
            return .performanceSummary
        }
        if selectedTab == .performance && performanceViewMode == .detailSummary {
            return .performanceDetailSummary
        }
        return .full
    }

    private func resizeWindowIfNeeded(animated: Bool) {
        let newMode = currentWindowPresentationMode
        if lastWindowPresentationMode == nil {
            lastWindowPresentationMode = newMode
        }
        guard newMode != lastWindowPresentationMode else { return }
        lastWindowPresentationMode = newMode
        resizeWindowForCurrentMode(animated: animated)
    }

    private func resizeWindowForCurrentMode(animated: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
            compactTransitionInProgress = false
            return
        }
        let targetSize: NSSize
        let minSize: NSSize

        if compactMode {
            targetSize = NSSize(width: 400, height: 340)
            minSize = NSSize(width: 400, height: 340)
        } else if selectedTab == .performance && performanceViewMode == .summary {
            targetSize = NSSize(width: 300, height: 560)
            minSize = NSSize(width: 260, height: 420)
        } else if selectedTab == .performance && performanceViewMode == .detailSummary {
            targetSize = NSSize(width: 780, height: 510)
            minSize = NSSize(width: 640, height: 420)
        } else if selectedTab == .performance && performanceViewMode == .full {
            targetSize = NSSize(width: 1120, height: 760)
            minSize = NSSize(width: 1120, height: 760)
        } else {
            targetSize = NSSize(width: 1120, height: 760)
            minSize = NSSize(width: 1120, height: 760)
        }
        window.minSize = minSize
        var frame = window.frame
        frame.size = targetSize
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            } completionHandler: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    compactTransitionInProgress = false
                }
            }
        } else {
            window.setFrame(frame, display: true)
            compactTransitionInProgress = false
        }
    }

    private func updateWindowTrafficLights() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        let shouldHide = selectedTab == .performance && performanceViewMode == .summary
        window.standardWindowButton(.closeButton)?.isHidden = shouldHide
        window.standardWindowButton(.miniaturizeButton)?.isHidden = shouldHide
        window.standardWindowButton(.zoomButton)?.isHidden = shouldHide
    }

    private func endSelectedTask() {
        guard let pid = selectedProcessPID else { return }
        let result = TaskTerminator.terminate(pid: pid)
        switch result {
        case .success:
            selectedProcessPID = nil
            monitor.refreshNow()
        case .failure(let message):
            taskActionErrorMessage = message
        }
    }

    private func performPrimaryTaskAction() {
        guard let pid = selectedProcessPID else { return }
        if isFinderProcess(pid: pid), let row = selectedProcessRow(pid: pid) {
            restartProcess(row)
            return
        }
        endSelectedTask()
    }

    private func endTask(pid: Int32) {
        selectedProcessPID = pid
        endSelectedTask()
    }

    private func endProcessTree(pid: Int32) {
        let children = monitor.listChildPIDs(parentPID: pid)
        for child in children {
            _ = TaskTerminator.terminate(pid: child)
        }
        endTask(pid: pid)
    }

    private func openDetailsTab(_ pid: Int32) {
        selectedProcessPID = pid
        selectedTab = .details
    }

    private func openServicesTab() {
        selectedTab = .services
    }

    private func isFinderProcess(pid: Int32) -> Bool {
        let name = selectedProcessName(pid: pid).lowercased()
        let path = monitor.pidPath(pid: pid).lowercased()
        return name == "finder" || name == "访达" || path.contains("/system/library/coreservices/finder.app")
    }

    private func selectedProcessName(pid: Int32) -> String {
        if let row = monitor.processSections.flatMap(\.rows).first(where: { $0.pid == pid }) {
            return row.name
        }
        if let row = monitor.currentUserAppRows.first(where: { $0.pid == pid }) {
            return row.name
        }
        if let row = monitor.detailProcessRows.first(where: { $0.pid == pid }) {
            return row.name
        }
        if let row = monitor.serviceRows.first(where: { $0.pid == pid }) {
            return row.name
        }
        return ""
    }

    private func selectedProcessRow(pid: Int32) -> ProcessRowData? {
        if let row = monitor.processSections.flatMap(\.rows).first(where: { $0.pid == pid }) {
            return row
        }
        if let row = monitor.currentUserAppRows.first(where: { $0.pid == pid }) {
            return row
        }
        if let info = monitor.processInfo(pid: pid, includeResourceUsage: true) {
            return ProcessRowData(
                pid: pid,
                name: info.displayName,
                icon: monitor.iconForProcess(path: info.path),
                path: info.path,
                isApp: info.isApplication,
                isParent: false,
                parentPID: nil,
                childCount: 0,
                cpuPercent: 0,
                memoryBytes: info.residentSize,
                diskBytesPerSecond: 0,
                networkBytesPerSecond: 0,
                networkText: "0 Mbps",
                powerUsageWatts: 0,
                powerTrendWatts: 0,
                powerImpact: "",
                trend: "",
                threadCount: info.threadCount,
                openFiles: info.openFiles
            )
        }
        return nil
    }

    private func startService(_ row: ServiceRowData) {
        let target = serviceTarget(for: row)
        guard !target.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["enable", target]
        try? process.run()
        process.waitUntilExit()
        monitor.refreshServicesNow()
    }

    private func stopService(_ row: ServiceRowData) {
        let target = serviceTarget(for: row)
        guard !target.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["disable", target]
        try? process.run()
        process.waitUntilExit()
        monitor.refreshServicesNow()
    }

    private func restartService(_ row: ServiceRowData) {
        let target = serviceTarget(for: row)
        guard !target.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", target]
        try? process.run()
        process.waitUntilExit()
        monitor.refreshServicesNow()
    }

    private func serviceTarget(for row: ServiceRowData) -> String {
        "\(row.group)/\(row.label)"
    }

    private func restartProcess(_ row: ProcessRowData) {
        guard !row.path.isEmpty else { return }
        let url = URL(fileURLWithPath: row.path)
        _ = NSWorkspace.shared.open(url)
    }

    private func revealInFinder(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func searchWeb(_ query: String) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showProcessProperties(_ row: ProcessRowData) {
        guard !row.path.isEmpty else { return }
        let script = """
        tell application "Finder"
            activate
            set targetItem to POSIX file "\(row.path)" as alias
            open information window of targetItem
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private func copyProcessDetails(_ row: ProcessRowData) {
        let lines = [
            language.text("名称", "Name") + ": \(row.name)",
            "PID: \(row.pid)",
            "CPU: \(DisplayFormat.percentWithPrecision(row.cpuPercent, digits: 1))",
            language.text("内存", "Memory") + ": \(DisplayFormat.memory(row.memoryBytes))",
            language.text("磁盘", "Disk") + ": \(DisplayFormat.throughput(row.diskBytesPerSecond))",
            language.text("网络", "Network") + ": \(row.networkText)",
            language.text("电源使用情况", "Power usage") + ": \(row.powerImpact)"
        ]
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func openNewTerminalWindow() {
        let script = """
        tell application "Terminal"
            activate
            do script ""
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private func setProcessPriority(pid: Int32, preset: ProcessPriorityPreset) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/renice")
        process.arguments = ["-n", "\(preset.niceValue)", "-p", "\(pid)"]
        try? process.run()
        process.waitUntilExit()
        monitor.refreshNow()
    }

    private func canTerminate(pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return pid != Int32(ProcessInfo.processInfo.processIdentifier)
    }

    private func reconcileSelectionForCurrentTab() {
        guard let pid = selectedProcessPID else { return }

        switch selectedTab {
        case .processes:
            if !monitor.processSections.flatMap(\.rows).contains(where: { $0.pid == pid }) {
                selectedProcessPID = nil
            }
        case .users:
            if !monitor.currentUserAppRows.contains(where: { $0.pid == pid }) {
                selectedProcessPID = nil
            }
        case .details:
            if !monitor.detailProcessRows.contains(where: { $0.pid == pid }) {
                selectedProcessPID = nil
            }
        case .services:
            if !monitor.serviceRows.contains(where: { $0.pid == pid }) {
                selectedProcessPID = nil
            }
        default:
            selectedProcessPID = nil
        }
    }

    private func exitPerformanceSummaryIfNeeded() {
        if selectedTab != .performance || compactMode {
            performanceViewMode = .full
        }
    }

    @ViewBuilder
    private func nativeCheckmarkLabel(_ title: String, checked: Bool) -> some View {
        if checked {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func nativeMenuBarLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14))
            .foregroundStyle(AppTheme.primaryText(colorScheme))
            .padding(.horizontal, 4)
            .frame(height: 24)
    }

    private var nativeWindowChrome: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    Color.clear.frame(width: 88, height: 1)
                    Spacer()
                    Color.clear.frame(width: 88, height: 1)
                }

                HStack(spacing: 8) {
                    TaskManagerGlyph()
                    Text(language.text("任务管理器", "Task Manager"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText(colorScheme))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)

            HStack(spacing: 14) {
                Menu {
                    nativeFileMenuContent
                } label: {
                    nativeMenuBarLabel(language.text("文件", "File"))
                }
                .menuStyle(.borderlessButton)

                Menu {
                    nativeOptionsMenuContent
                } label: {
                    nativeMenuBarLabel(language.text("选项", "Options"))
                }
                .menuStyle(.borderlessButton)

                Menu {
                    nativeViewMenuContent
                } label: {
                    nativeMenuBarLabel(language.text("查看", "View"))
                }
                .menuStyle(.borderlessButton)

                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(AppTheme.chromeBackground(colorScheme))

            HStack(spacing: 2) {
                ForEach(TaskTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                        activeMenu = nil
                    } label: {
                        Text(tab.title(in: language))
                            .font(.system(size: 14))
                            .foregroundStyle(AppTheme.primaryText(colorScheme))
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(tab == selectedTab ? AppTheme.chromeSelectedFill(colorScheme) : Color.clear)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(tab == selectedTab ? AppTheme.accentBlue : .clear)
                                    .frame(height: 2)
                            }
                            .interactiveHitTarget()
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .padding(.bottom, 4)
        }
        .background {
            ZStack {
                VisualEffectBlur(material: .headerView, blendingMode: .withinWindow)
                LinearGradient(
                    colors: [
                        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.34),
                        colorScheme == .dark ? Color.white.opacity(0.03) : Color.white.opacity(0.12)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.separator(colorScheme))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var nativeFileMenuContent: some View {
        Button(language.text("运行新任务", "Run new task")) {
            if commandKeyPressed {
                openNewTerminalWindow()
            } else {
                newTaskPanelManager.show(language: language)
            }
        }
        Divider()
        Button(language.text("退出", "Exit")) {
            NSApp.terminate(nil)
        }
    }

    @ViewBuilder
    private var nativeOptionsMenuContent: some View {
        Button {
            alwaysOnTop.toggle()
        } label: {
            nativeCheckmarkLabel(language.text("置于顶层", "Always on top"), checked: alwaysOnTop)
        }
        Button {
            useSmallValues.toggle()
        } label: {
            nativeCheckmarkLabel(language.text("使用小值", "Use small values"), checked: useSmallValues)
        }
        Button {
            hideWhenMinimized.toggle()
        } label: {
            nativeCheckmarkLabel(language.text("最小化时隐藏", "Hide when minimized"), checked: hideWhenMinimized)
        }
        Divider()
        Menu(language.text("语言", "Language")) {
            ForEach(AppLanguage.allCases) { style in
                Button {
                    language = style
                } label: {
                    nativeCheckmarkLabel(style == .chinese ? "中文" : "English", checked: language == style)
                }
            }
        }
        Menu(language.text("菜单风格", "Menu style")) {
            ForEach(MenuVisualStyle.allCases) { style in
                Button {
                    setMenuVisualStyle(style)
                } label: {
                    nativeCheckmarkLabel(style.title(in: language), checked: menuVisualStyle == style)
                }
            }
        }
        Menu(language.text("温度单位", "Temperature unit")) {
            Button {
                temperatureUnit = .celsius
            } label: {
                nativeCheckmarkLabel(language.text("摄氏度 °C", "Celsius °C"), checked: temperatureUnit == .celsius)
            }
            Button {
                temperatureUnit = .fahrenheit
            } label: {
                nativeCheckmarkLabel(language.text("华氏度 °F", "Fahrenheit °F"), checked: temperatureUnit == .fahrenheit)
            }
        }
    }

    @ViewBuilder
    private var nativeViewMenuContent: some View {
        Button(language.text("立即刷新", "Refresh now")) {
            monitor.refreshNow()
        }
        Menu(language.text("更新速度", "Update speed")) {
            ForEach(RefreshSpeedOption.allCases) { option in
                Button {
                    monitor.setRefreshSpeed(option)
                } label: {
                    nativeCheckmarkLabel(option.title(in: language), checked: monitor.refreshSpeed == option)
                }
            }
        }
        Divider()
        Button(language.text("全部展开", "Expand all")) {
            collapsedSections.removeAll()
        }
        Button(language.text("全部折叠", "Collapse all")) {
            collapsedSections = Set(monitor.processSections.map(\.kind))
        }
    }
}

enum MenuKind {
    case file
    case options
    case view
}

struct WindowSurfaceBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppTheme.windowTop(colorScheme),
                    AppTheme.windowBottom(colorScheme)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VisualEffectBlur(material: .underWindowBackground, blendingMode: .behindWindow)
                .opacity(colorScheme == .dark ? 0.82 : 0.92)

            LinearGradient(
                colors: [
                    AppTheme.topGlow(colorScheme),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .center
            )

            if colorScheme == .light {
                Color.white.opacity(0.18)
            }
        }
        .ignoresSafeArea()
    }
}

struct WindowChromeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var language
    @Binding var selectedTab: TaskTab
    @Binding var activeMenu: MenuKind?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    Color.clear.frame(width: 88, height: 1)
                    Spacer()
                    Color.clear.frame(width: 88, height: 1)
                }

                HStack(spacing: 8) {
                    TaskManagerGlyph()
                    Text(language.text("任务管理器", "Task Manager"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText(colorScheme))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)

            HStack(spacing: 16) {
                chromeButton(language.text("文件(F)", "File(F)"), menu: .file)
                chromeButton(language.text("选项(O)", "Options(O)"), menu: .options)
                chromeButton(language.text("查看(V)", "View(V)"), menu: .view)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(AppTheme.chromeBackground(colorScheme))

            HStack(spacing: 2) {
                ForEach(TaskTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                        activeMenu = nil
                    } label: {
                        Text(tab.title(in: language))
                            .font(.system(size: 14))
                            .foregroundStyle(AppTheme.primaryText(colorScheme))
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(tab == selectedTab ? AppTheme.chromeSelectedFill(colorScheme) : Color.clear)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(tab == selectedTab ? AppTheme.accentBlue : .clear)
                                    .frame(height: 2)
                            }
                            .interactiveHitTarget()
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .padding(.bottom, 4)
        }
        .background {
            ZStack {
                VisualEffectBlur(material: .headerView, blendingMode: .withinWindow)
                LinearGradient(
                    colors: [
                        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.34),
                        colorScheme == .dark ? Color.white.opacity(0.03) : Color.white.opacity(0.12)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.separator(colorScheme))
                .frame(height: 1)
        }
    }

    private func chromeButton(_ title: String, menu: MenuKind) -> some View {
        Button {
            if activeMenu == menu {
                activeMenu = nil
            } else {
                activeMenu = menu
            }
        } label: {
            Text(title)
                .frame(height: 22)
                .padding(.horizontal, 2)
                .background(activeMenu == menu ? AppTheme.menuHighlight(colorScheme) : Color.clear)
                .interactiveHitTarget()
                .onHover { hovering in
                    guard hovering, activeMenu != nil, activeMenu != menu else { return }
                    activeMenu = menu
                }
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(AppTheme.primaryText(colorScheme))
    }
}

struct TaskManagerGlyph: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 1.6, y: 12.4))
            path.addLine(to: CGPoint(x: 5.2, y: 12.4))
            path.addLine(to: CGPoint(x: 7.1, y: 6.4))
            path.addLine(to: CGPoint(x: 9.6, y: 9.6))
            path.addLine(to: CGPoint(x: 12.0, y: 2.2))
            path.addLine(to: CGPoint(x: 14.3, y: 11.8))
        }
        .stroke(
            AppTheme.accentBlue,
            style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
        )
        .frame(width: 16, height: 16)
    }
}

struct FooterBarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var language
    @Binding var compactMode: Bool
    let canEndTask: Bool
    let primaryActionTitle: String
    let isToggleFocused: Bool
    let isPrimaryActionFocused: Bool
    let onToggleCompact: () -> Void
    let onPrimaryAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleCompact) {
                HStack(spacing: 8) {
                    Circle()
                        .stroke(AppTheme.secondaryText(colorScheme), lineWidth: 1)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Image(systemName: compactMode ? "chevron.down" : "chevron.up")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(AppTheme.secondaryText(colorScheme))
                        )
                    Text(compactMode ? language.text("详细信息(D)", "More details(D)") : language.text("简略信息(D)", "Fewer details(D)"))
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 4)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isToggleFocused ? AppTheme.accentBlue : .clear, lineWidth: 1.5)
                )
                .interactiveHitTarget()
            }
            .buttonStyle(.plain)

            Button(language.text("打开资源监视器", "Open Activity Monitor")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.accentBlue)
                .interactiveHitTarget()

            Spacer()

            Button(primaryActionTitle, action: onPrimaryAction)
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(canEndTask ? AppTheme.primaryText(colorScheme) : AppTheme.secondaryText(colorScheme))
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppTheme.footerButtonFill(colorScheme, enabled: canEndTask))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isPrimaryActionFocused ? AppTheme.accentBlue : AppTheme.footerStroke(colorScheme), lineWidth: isPrimaryActionFocused ? 1.5 : 1)
                )
                .interactiveHitTarget()
                .disabled(!canEndTask)
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background {
            ZStack {
                VisualEffectBlur(material: .sheet, blendingMode: .withinWindow)
                LinearGradient(
                    colors: [
                        colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.18),
                        colorScheme == .dark ? Color.white.opacity(0.03) : Color.white.opacity(0.1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.separator(colorScheme))
                .frame(height: 1)
        }
    }
}

struct CompactApplicationsView: View {
    @Environment(\.colorScheme) private var colorScheme
    let rows: [ProcessRowData]
    @Binding var selectedPID: Int32?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            ProcessIconView(icon: row.icon)
                            Text(row.name)
                                .font(.system(size: 14))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 34)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selectedPID == row.pid ? AppTheme.selectedRow(colorScheme) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .id(row.pid)
                        .onTapGesture {
                            selectedPID = row.pid
                        }
                    }
                }
            }
            .onChange(of: selectedPID) { _, newValue in
                guard let newValue else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .background(Color.clear)
        .onAppear {
            if selectedPID == nil {
                selectedPID = rows.first?.pid
            }
        }
    }
}

struct CompactModeContainer: View {
    let rows: [ProcessRowData]
    @Binding var selectedPID: Int32?
    let primaryActionTitle: String
    let isMoreDetailsFocused: Bool
    let isPrimaryActionFocused: Bool
    let onToggleCompact: () -> Void
    let onPrimaryAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CompactModeHeader()
            CompactApplicationsView(rows: rows, selectedPID: $selectedPID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            CompactModeFooter(
                canEndTask: selectedPID != nil,
                primaryActionTitle: primaryActionTitle,
                isMoreDetailsFocused: isMoreDetailsFocused,
                isPrimaryActionFocused: isPrimaryActionFocused,
                onToggleCompact: onToggleCompact,
                onPrimaryAction: onPrimaryAction
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


struct CompactModeHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var language
    var body: some View {
        ZStack {
            Text(language.text("任务管理器", "Task Manager"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.primaryText(colorScheme))
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.separator(colorScheme))
                .frame(height: 1)
        }
    }
}

struct CompactModeFooter: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var language
    let canEndTask: Bool
    let primaryActionTitle: String
    let isMoreDetailsFocused: Bool
    let isPrimaryActionFocused: Bool
    let onToggleCompact: () -> Void
    let onPrimaryAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleCompact) {
                HStack(spacing: 8) {
                    Circle()
                        .stroke(AppTheme.secondaryText(colorScheme), lineWidth: 1)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(AppTheme.secondaryText(colorScheme))
                        )
                    Text(language.text("详细信息(D)", "More details(D)"))
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 4)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isMoreDetailsFocused ? AppTheme.accentBlue : .clear, lineWidth: 1.5)
                )
                .interactiveHitTarget()
            }
            .buttonStyle(.plain)

            Spacer()

            Button(primaryActionTitle, action: onPrimaryAction)
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(canEndTask ? AppTheme.primaryText(colorScheme) : AppTheme.secondaryText(colorScheme))
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AppTheme.compactFooterFill(colorScheme, enabled: canEndTask))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isPrimaryActionFocused ? AppTheme.accentBlue : AppTheme.compactFooterStroke(colorScheme), lineWidth: isPrimaryActionFocused ? 1.5 : 1)
                )
                .interactiveHitTarget()
                .disabled(!canEndTask)
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.16))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.separator(colorScheme))
                .frame(height: 1)
        }
    }
}

struct WinMenuButtonStyle: ButtonStyle {
    var isHighlighted = false

    func makeBody(configuration: Configuration) -> some View {
        WinMenuButtonBody(configuration: configuration, isHighlighted: isHighlighted)
    }
}

private struct WinMenuButtonBody: View {
    @Environment(\.colorScheme) private var colorScheme
    let configuration: ButtonStyle.Configuration
    let isHighlighted: Bool
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHighlighted || isHovering || configuration.isPressed
                    ? AppTheme.menuHighlight(colorScheme)
                    : Color.clear
            )
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

struct NewTaskPanelView: View {
    let language: AppLanguage
    let onClose: () -> Void
    @State private var command = ""
    @State private var useAdmin = false
    @State private var password = ""
    @State private var errorMessage = ""
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 28))
                    .frame(width: 40)
                Text(language.text("MacOS 将根据你所键入的名称，为你打开相应的程序、文件夹、文档或 Internet 资源。", "macOS will open the app, folder, document, or Internet resource you enter."))
                    .font(.system(size: 14))
            }

            HStack(spacing: 8) {
                Text(language.text("打开(O):", "Open(O):"))
                    .font(.system(size: 14))
                TextField("", text: $command)
                    .textFieldStyle(.roundedBorder)
                Button(language.text("浏览(B)...", "Browse(B)...")) { browse() }
                    .buttonStyle(.bordered)
            }

            Toggle(language.text("使用管理权限创建此任务。", "Create this task with admin privileges."), isOn: $useAdmin)
                .toggleStyle(.checkbox)

            if useAdmin {
                HStack(spacing: 8) {
                    Text(language.text("密码(P):", "Password(P):"))
                        .font(.system(size: 14))
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if !errorMessage.isEmpty {
                Text(language.localizeRuntimeMessage(errorMessage))
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(language.text("取消", "Cancel"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(isRunning ? language.text("执行中...", "Running...") : language.text("确定", "OK")) {
                    runTask()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (useAdmin && password.isEmpty) || isRunning)
            }
        }
        .padding(18)
        .frame(width: 480, height: 240, alignment: .topLeading)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.title = language.text("浏览", "Browse")
        if panel.runModal() == .OK, let url = panel.url {
            command = url.path.contains(" ") ? "\"\(url.path)\"" : url.path
        }
    }

    private func runTask() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = ""
        isRunning = true
        let admin = useAdmin
        let pwd = password

        DispatchQueue.global(qos: .userInitiated).async {
            let result = TaskRunner.executeCommand(trimmed, asAdmin: admin, password: pwd)
            DispatchQueue.main.async {
                isRunning = false
                switch result {
                case .success:
                    onClose()
                case .failure(let message):
                    errorMessage = message
                }
            }
        }
    }

    private var input: String { command }

}

@MainActor
final class NewTaskPanelManager: ObservableObject {
    private var panel: NSPanel?
    private let panelSize = NSSize(width: 480, height: 286)

    func show(language: AppLanguage) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = false
            panel.titleVisibility = .visible
            panel.titlebarAppearsTransparent = false
            panel.isMovableByWindowBackground = false
            panel.minSize = panelSize
            panel.maxSize = panelSize
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.standardWindowButton(.closeButton)?.isHidden = false
            panel.standardWindowButton(.closeButton)?.isEnabled = true
            self.panel = panel
        }

        update(language: language)
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(language: AppLanguage) {
        guard let panel else { return }
        panel.title = language.text("新建任务", "Create new task")
        panel.contentView = NSHostingView(
            rootView: NewTaskPanelView(
                language: language,
                onClose: { [weak self] in
                    self?.panel?.close()
                }
            )
        )
    }
}

@MainActor
final class NetworkDetailsPanelManager: ObservableObject {
    private var panel: NSPanel?
    private var currentLanguage: AppLanguage = .chinese
    private let panelSize = NSSize(width: 560, height: 760)
    private var currentNetwork: NetworkState?

    func show(network: NetworkState, language: AppLanguage) {
        currentNetwork = network
        currentLanguage = language
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = false
            panel.titleVisibility = .visible
            panel.titlebarAppearsTransparent = false
            panel.isMovableByWindowBackground = false
            panel.minSize = panelSize
            panel.maxSize = panelSize
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            self.panel = panel
        }

        updatePanel()
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateLanguage(_ language: AppLanguage) {
        currentLanguage = language
        updatePanel()
    }

    private func updatePanel() {
        guard let panel, let currentNetwork else { return }
        panel.title = currentLanguage.text("网络详细信息", "Network details")
        panel.contentView = NSHostingView(
            rootView: NetworkDetailsView(
                network: currentNetwork,
                language: currentLanguage
            )
        )
    }
}

@MainActor
final class AboutPanelManager: ObservableObject {
    static let shared = AboutPanelManager()

    private var panel: NSPanel?
    private let panelSize = NSSize(width: 420, height: 320)
    private var currentLanguage: AppLanguage = .defaultFromSystem()

    func show(language: AppLanguage) {
        currentLanguage = language
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = false
            panel.titleVisibility = .visible
            panel.titlebarAppearsTransparent = false
            panel.isMovableByWindowBackground = false
            panel.minSize = panelSize
            panel.maxSize = panelSize
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            self.panel = panel
        }

        update(language: language)
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showCurrentLanguage() {
        show(language: currentLanguage)
    }

    func update(language: AppLanguage) {
        currentLanguage = language
        guard let panel else { return }
        panel.title = language.text("关于 任务管理器", "About Task Manager")
        panel.contentView = NSHostingView(
            rootView: AboutPanelView(language: language)
        )
    }
}

struct AboutPanelView: View {
    @Environment(\.colorScheme) private var colorScheme
    let language: AppLanguage

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                TaskManagerGlyph()
                    .frame(width: 40, height: 40)
                    .scaleEffect(2.0)
                    .padding(.top, 8)

                Text("MacOSTSKMGR")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText(colorScheme))

                Text(versionLine)
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.secondaryText(colorScheme))
            }

            Text(language.text(
                "一个模仿 Windows 任务管理器交互与布局风格的 macOS 任务管理器实验项目。",
                "An experimental macOS task manager inspired by the layout and interactions of Windows Task Manager."
            ))
            .font(.system(size: 13))
            .foregroundStyle(AppTheme.primaryText(colorScheme))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)

            VStack(spacing: 6) {
                Text(language.text("版权所有 © 2026 Linqin。保留所有权利。", "Copyright © 2026 Linqin. All rights reserved."))
                Text(language.text("部分代码由 AI 协助生成。", "Some portions of the code were created with AI assistance."))
            }
            .font(.system(size: 12))
            .foregroundStyle(AppTheme.secondaryText(colorScheme))
            .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowSurfaceBackground())
    }

    private var versionLine: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "1.0"
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "1"
        return language.text("版本 \(shortVersion) (构建 \(buildVersion))", "Version \(shortVersion) (Build \(buildVersion))")
    }
}

struct NetworkDetailsView: View {
    @Environment(\.colorScheme) private var colorScheme
    let network: NetworkState
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                detailsHeaderCell(language.text("属性", "Property"), width: 240)
                detailsHeaderCell(network.displayName, width: 280)
            }
            .frame(height: 40)
            .background(AppTheme.tableHeader(colorScheme))
            .overlay(alignment: .bottom) {
                Rectangle().fill(AppTheme.strongSeparator(colorScheme)).frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(detailRows.indices, id: \.self) { index in
                        let row = detailRows[index]
                        HStack(spacing: 0) {
                            detailCell(row.0, width: 240)
                            detailCell(row.1, width: 280)
                        }
                        .frame(height: 30)
                        .background(index.isMultiple(of: 2) ? AppTheme.rowEven(colorScheme) : AppTheme.rowOdd(colorScheme))
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .padding(.top, 18)
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .background(WindowSurfaceBackground())
    }

    private var detailRows: [(String, String)] {
        let totalBytes = network.totalSendBytes + network.totalReceiveBytes
        let totalPackets = network.packetsSent + network.packetsReceived
        let totalMulticast = network.multicastSent + network.multicastReceived
        let bytesPerInterval = network.sendBytesPerSecond + network.receiveBytesPerSecond
        let sendRatePercent = currentLinkPercent(bytesPerSecond: network.sendBytesPerSecond)
        let receiveRatePercent = currentLinkPercent(bytesPerSecond: network.receiveBytesPerSecond)
        let totalRatePercent = currentLinkPercent(bytesPerSecond: bytesPerInterval)

        return [
            (language.text("网络使用率", "Network utilization"), formattedOptionalPercent(totalRatePercent)),
            (language.text("链接速度", "Link speed"), network.linkSpeedText),
            (language.text("状态", "Status"), network.statusText),
            (language.text("发送字节百分比", "Send byte rate"), formattedOptionalPercent(sendRatePercent)),
            (language.text("接收字节百分比", "Recv byte rate"), formattedOptionalPercent(receiveRatePercent)),
            (language.text("字节百分比", "Byte rate"), formattedOptionalPercent(totalRatePercent)),
            (language.text("已发送的字节", "Bytes sent"), formattedInteger(network.totalSendBytes)),
            (language.text("已接收的字节", "Bytes received"), formattedInteger(network.totalReceiveBytes)),
            (language.text("字节", "Bytes"), formattedInteger(totalBytes)),
            (language.text("每个间隔发送的字节", "Bytes sent / interval"), formattedInteger(network.sendBytesPerSecond)),
            (language.text("每个间隔接收的字节", "Bytes recv / interval"), formattedInteger(network.receiveBytesPerSecond)),
            (language.text("每个间隔的字节", "Bytes / interval"), formattedInteger(bytesPerInterval)),
            (language.text("已发送的单播", "Unicast sent"), formattedInteger(network.packetsSent - network.multicastSent)),
            (language.text("已接收的单播", "Unicast received"), formattedInteger(network.packetsReceived - network.multicastReceived)),
            (language.text("单播", "Unicast"), formattedInteger(totalPackets - totalMulticast)),
            (language.text("已发送的非单播", "Non-unicast sent"), formattedInteger(network.multicastSent)),
            (language.text("已接收的非单播", "Non-unicast received"), formattedInteger(network.multicastReceived)),
            (language.text("非单播", "Non-unicast"), formattedInteger(totalMulticast)),
            (language.text("IPv4 地址", "IPv4 address"), network.ipv4.isEmpty ? "--" : network.ipv4),
            (language.text("IPv6 地址", "IPv6 address"), network.ipv6.isEmpty ? "--" : network.ipv6),
            (language.text("MTU", "MTU"), "\(network.mtu)"),
            (language.text("输入错误", "Input errors"), formattedInteger(network.errorsIn)),
            (language.text("输出错误", "Output errors"), formattedInteger(network.errorsOut)),
            (language.text("输入丢弃", "Input drops"), formattedInteger(network.dropsIn)),
            (language.text("输出丢弃", "Output drops"), formattedInteger(network.dropsOut))
        ]
    }

    private func detailsHeaderCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 13))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(width: width, height: 40, alignment: .leading)
            .foregroundStyle(AppTheme.primaryText(colorScheme))
            .overlay(alignment: .trailing) {
                Rectangle().fill(AppTheme.separator(colorScheme)).frame(width: 1)
            }
    }

    private func detailCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 13))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(width: width, height: 30, alignment: .leading)
            .foregroundStyle(AppTheme.primaryText(colorScheme))
            .overlay(alignment: .trailing) {
                Rectangle().fill(AppTheme.separator(colorScheme)).frame(width: 1)
            }
    }

    private func formattedInteger(_ value: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formattedPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func formattedOptionalPercent(_ value: Double?) -> String {
        guard let value else { return "--" }
        return formattedPercent(value)
    }

    private func currentLinkPercent(bytesPerSecond: UInt64) -> Double? {
        guard network.linkSpeedBitsPerSecond > 0 else { return nil }
        let bitsPerSecond = Double(bytesPerSecond) * 8
        return min(bitsPerSecond / Double(network.linkSpeedBitsPerSecond) * 100, 100)
    }
}

enum TaskRunResult {
    case success
    case failure(String)
}

enum TaskTerminateResult {
    case success
    case failure(String)
}

enum TaskTerminator {
    static func terminate(pid: Int32) -> TaskTerminateResult {
        guard pid > 1 else {
            return .failure("Unable to end this task.")
        }

        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        guard pid != ownPID else {
            return .failure("Unable to end Task Manager itself.")
        }

        if kill(pid, SIGTERM) == 0 {
            return .success
        }

        let termError = errno
        if termError == ESRCH {
            return .success
        }

        if kill(pid, SIGKILL) == 0 {
            return .success
        }

        let finalError = errno
        if finalError == ESRCH {
            return .success
        }

        return .failure(terminationErrorMessage(errnoValue: finalError))
    }

    private static func terminationErrorMessage(errnoValue: Int32) -> String {
        switch errnoValue {
        case EPERM:
            return "Permission denied. Unable to end this task."
        case EINVAL:
            return "Invalid end-task request."
        case ESRCH:
            return "This task no longer exists."
        default:
            return String(cString: strerror(errnoValue))
        }
    }
}

enum TaskRunner {
    static func executeCommand(_ input: String, asAdmin: Bool, password: String) -> TaskRunResult {
        if let appURL = appBundleURL(from: input) {
            return openApplication(at: appURL)
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        if asAdmin {
            process.arguments = ["-lc", "sudo -S -- \(input)"]
            process.standardInput = inputPipe
        } else {
            process.arguments = ["-lc", input]
        }
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return .failure("Unable to start task: \(error.localizedDescription)")
        }

        if asAdmin {
            if let data = "\(password)\n".data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            try? inputPipe.fileHandleForWriting.close()
        }

        process.waitUntilExit()

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus == 0 {
            return .success
        }

        if asAdmin && errorText.localizedCaseInsensitiveContains("incorrect password") {
            return .failure("Incorrect password.")
        }

        if errorText.isEmpty {
            return .failure("Task execution failed.")
        }

        return .failure(errorText)
    }

    private static func appBundleURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidate = trimmed
        if candidate.hasPrefix("\""), candidate.hasSuffix("\""), candidate.count >= 2 {
            candidate.removeFirst()
            candidate.removeLast()
        }

        guard candidate.hasSuffix(".app") else { return nil }

        let url = URL(fileURLWithPath: candidate)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        return url
    }

    private static func openApplication(at url: URL) -> TaskRunResult {
        let openResult: Bool
        if Thread.isMainThread {
            openResult = NSWorkspace.shared.open(url)
        } else {
            openResult = DispatchQueue.main.sync {
                NSWorkspace.shared.open(url)
            }
        }

        return openResult ? .success : .failure("Unable to open application.")
    }
}

struct MenuKeyHandlingView: NSViewRepresentable {
    let onAltF: () -> Void
    let onAltO: () -> Void
    let onAltV: () -> Void
    let onNavigationCommand: (KeyboardNavigationCommand) -> Void
    let onControlChanged: (Bool) -> Void
    let onCommandChanged: (Bool) -> Void

    func makeNSView(context: Context) -> KeyHandlingNSView {
        let view = KeyHandlingNSView()
        view.onAltF = onAltF
        view.onAltO = onAltO
        view.onAltV = onAltV
        view.onNavigationCommand = onNavigationCommand
        view.onControlChanged = onControlChanged
        view.onCommandChanged = onCommandChanged
        return view
    }

    func updateNSView(_ nsView: KeyHandlingNSView, context: Context) {
        nsView.onAltF = onAltF
        nsView.onAltO = onAltO
        nsView.onAltV = onAltV
        nsView.onNavigationCommand = onNavigationCommand
        nsView.onControlChanged = onControlChanged
        nsView.onCommandChanged = onCommandChanged
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

final class KeyHandlingNSView: NSView {
    var onAltF: (() -> Void)?
    var onAltO: (() -> Void)?
    var onAltV: (() -> Void)?
    var onNavigationCommand: ((KeyboardNavigationCommand) -> Void)?
    var onControlChanged: ((Bool) -> Void)?
    var onCommandChanged: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let optionPressed = event.modifierFlags.contains(.option)
        if optionPressed, let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "f": onAltF?()
            case "o": onAltO?()
            case "v": onAltV?()
            default: super.keyDown(with: event)
            }
            return
        }

        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 48:
            onNavigationCommand?(event.modifierFlags.contains(.shift) ? .focusPrevious : .focusNext)
        case 123:
            onNavigationCommand?(.moveLeft)
        case 124:
            onNavigationCommand?(.moveRight)
        case 125:
            onNavigationCommand?(.moveDown)
        case 126:
            onNavigationCommand?(.moveUp)
        case 36, 76:
            onNavigationCommand?(.activatePrimary)
        case 49:
            onNavigationCommand?(.activateSecondary)
        case 51:
            onNavigationCommand?(.back)
        case 53:
            onNavigationCommand?(.cancel)
        default:
            super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        onControlChanged?(event.modifierFlags.contains(.control))
        onCommandChanged?(event.modifierFlags.contains(.command))
        super.flagsChanged(with: event)
    }
}
