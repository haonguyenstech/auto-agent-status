// README screenshots: renders each tab of the panel with made-up data, so no real
// account, session or token ever ends up in an image. Built only by snapshot.sh.
import AppKit
import SwiftUI

private func demoStore() -> StatusStore {
    let s = StatusStore()
    let now = Date()
    var st = AgentStatus()
    st.credentialPresent = true
    st.expiresAt = now.addingTimeInterval(2 * 3600 + 15 * 60)
    st.role = "client"
    st.username = "your.name"
    st.serverUrl = "https://agent.example.com"
    st.serverOK = true
    st.serverLatencyMs = 42
    s.status = st
    s.autoRenew = true
    s.lastRenewAt = now.addingTimeInterval(-3 * 3600)
    s.cliPath = "/opt/homebrew/bin/auto-agent-ai"
    s.installedVersion = "1.1.20"
    s.latestVersion = "1.1.20"
    s.appLatestVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    s.planUsage = PlanUsage(limits: [
        PlanLimit(label: "Session", percent: 23, resetsAt: now.addingTimeInterval(3 * 3600 + 20 * 60), severity: "ok"),
        PlanLimit(label: "Week (all models)", percent: 41, resetsAt: now.addingTimeInterval(3 * 86400), severity: "ok"),
        PlanLimit(label: "Week · Opus", percent: 12, resetsAt: now.addingTimeInterval(3 * 86400), severity: "ok"),
    ])
    s.usage = TokenUsage(input: 412_000, output: 1_180_000, cacheCreate: 2_210_000, cacheRead: 38_400_000, costUSD: 61.42)
    let cal = Calendar.current
    let days: [Int] = [2_900_000, 4_100_000, 1_800_000, 5_200_000, 3_300_000, 4_600_000, 3_802_000]
    s.usageHistory = days.enumerated().map { i, b in
        DayUsage(date: cal.date(byAdding: .day, value: i - 6, to: cal.startOfDay(for: now))!, billable: b, costUSD: Double(b) / 62_000)
    }
    s.usageTotals = PeriodTotals(weekBillable: 25_702_000, weekCost: 414.5, monthBillable: 88_300_000, monthCost: 1_424.2,
                                 allBillable: 312_900_000, allCost: 5_046.8)
    s.aiSession = AISessionInfo(id: "s1", name: "Frontend team", isActive: true, updatedAt: now.addingTimeInterval(-1800),
                                members: ["your.name", "alex", "sam", "jordan"], createdBy: "owner")
    let shared = FigmaAccount(id: "1", email: "design@example.com", active: true, plan: "team:123")
    s.figmaSession = FigmaSessionInfo(sessionId: "f1", name: "Design seats", isActive: true, hasSession: true, cookieCount: 14,
                                      accounts: [shared], capturedAt: now.addingTimeInterval(-2 * 86400), memberCount: 5)
    s.figma = FigmaState(accounts: [shared], problem: nil, desktopRunning: true, checked: true)
    s.shareTokenRank = true
    s.tokenRankOK = true
    s.tokenRankAt = now.addingTimeInterval(-600)
    return s
}

/// Controls draw their active (accent) look only in a key window; this one never
/// shows on screen, so it claims to be key.
private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// Same reason, for controls that check whether the app is active.
private final class ActiveApp: NSApplication {
    override var isActive: Bool { true }
}

func runSnapshots() {
    let app = ActiveApp.shared
    app.setActivationPolicy(.prohibited)
    let dir = CommandLine.arguments.dropFirst().first ?? "snapshots"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let store = demoStore()
    let tabs: [(String, ContentView.Tab)] = [("status", .status), ("figma", .figma), ("system", .system), ("settings", .settings)]
    for appearance in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        for (name, tab) in tabs {
            let root = ContentView(store: store, tab: tab)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, appearance.0 == "dark" ? .dark : .light)
            let host = NSHostingView(rootView: root)
            host.appearance = NSAppearance(named: appearance.1)
            let size = host.fittingSize
            let win = KeyWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: appearance.1)
            win.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = "\(dir)/\(name)-\(appearance.0).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print(path, Int(size.width), "x", Int(size.height))
        }
    }
}
