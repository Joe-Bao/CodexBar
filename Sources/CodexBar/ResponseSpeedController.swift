import AppKit
import CodexBarCore
import Observation
import SwiftUI

/// A dedicated CodexBar status item keeps speed one click away, independent of billing and quota probes.
@MainActor
final class ResponseSpeedController: NSObject {
    private let settings: SettingsStore
    private let model = ResponseSpeedModel()
    private let scanner = ResponseSpeedScanner(roots: ResponseSpeedScanner.localRoots())
    private let popover = NSPopover()
    private var item: NSStatusItem?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var stopped = false
    private var lastRenderedStatusTitle: String?
    private let openSettings: () -> Void

    init(
        settings: SettingsStore,
        openSettings: @escaping () -> Void)
    {
        self.settings = settings
        self.openSettings = openSettings
        super.init()
        self.popover.behavior = .transient
        self.popover.contentViewController = NSHostingController(rootView: ResponseSpeedPopover(
            model: self.model,
            refresh: { [weak self] in self?.refresh() },
            openSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.openSettings()
            }))
        self.observeSettings()
    }

    func stop() {
        self.stopped = true
        self.generation += 1
        self.task?.cancel()
        self.task = nil
        self.popover.performClose(nil)
        if let item { NSStatusBar.system.removeStatusItem(item) }
        self.item = nil
    }

    private func observeSettings() {
        guard !self.stopped else { return }
        withObservationTracking {
            _ = self.settings.responseSpeedEnabled
            _ = self.settings.backgroundWorkLowPowerModeEnabled
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSettings() }
        }
        self.reconcile()
    }

    private func reconcile() {
        self.generation += 1
        self.task?.cancel()
        self.task = nil
        if !self.settings.responseSpeedEnabled {
            self.popover.performClose(nil)
            if let item { NSStatusBar.system.removeStatusItem(item) }
            self.item = nil
            self.model.samples = []
            return
        }
        if self.item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "CodexBarResponseSpeed"
            item.button?.target = self
            item.button?.action = #selector(self.togglePopover)
            item.button?.font = NSFont.monospacedDigitSystemFont(
                ofSize: 12,
                weight: .medium)
            item.button?.setAccessibilityIdentifier("codexbar-response-speed")
            self.item = item
            if MenuBarStatusItemWindowProbe.diagnosticsEnabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                    guard let item = self?.item else { return }
                    let rightArea = item.button?.window?.screen?.auxiliaryTopRightArea
                    MenuBarStatusItemWindowProbe.trace(
                        "response-speed-settled",
                        item: item,
                        evidence: "cameraSafeRightArea=\(rightArea.map(NSStringFromRect) ?? "none")")
                }
            }
        }
        self.updateTitle()
        self.refresh()
    }

    private func refresh() {
        guard !self.stopped, self.settings.responseSpeedEnabled else { return }
        self.generation += 1
        let generation = self.generation
        self.task?.cancel()
        let scanner = self.scanner
        self.task = Task { [weak self] in
            var rediscover = true
            while !Task.isCancelled {
                let result = await scanner.scan(rediscover: rediscover)
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.model.now = Date()
                self.model.samples = result.samples
                self.model.isIndexing = result.isIndexing
                self.model.unreadableFiles = result.unreadableFiles
                self.model.historyLimited = result.historyLimited
                self.model.lowPower = self.settings.backgroundWorkLowPowerModeEnabled
                self.updateTitle()
                rediscover = false
                // Respect the app's existing low-power promise. Opening the popover refreshes immediately.
                let seconds = self.model.lowPower ? 1800.0 : (result.isIndexing ? 0.5 : 2.0)
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            }
        }
    }

    private func updateTitle() {
        let title = self.model.statusTitle
        if let button = self.item?.button, button.image == nil || self.lastRenderedStatusTitle != title {
            button.title = ""
            button.image = ResponseSpeedStatusImage.render(rate: self.model.statusRate)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            self.lastRenderedStatusTitle = title
        }
        if let active = self.model.active {
            self.item?.button?.toolTip = "\(active.key.source.title) · \(active.key.model)\n"
                + L("response_speed_recent") + " · \(ResponseSpeedModel.rate(active.recentMedian)) tok/s"
        } else {
            self.item?.button?.toolTip = L("response_speed_empty")
        }
        self.item?.button?.setAccessibilityLabel(L("response_speed_title") + " " + self.model.statusTitle)
    }

    @objc private func togglePopover() {
        if self.popover.isShown {
            self.popover.performClose(nil)
        } else if let button = self.item?.button {
            self.refresh()
            self.popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY)
        }
    }
}
