import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Paths & constants

let cliCandidates = [
    "/opt/homebrew/bin/auto-agent-ai",
    "/usr/local/bin/auto-agent-ai",
]
let home = FileManager.default.homeDirectoryForCurrentUser.path
let agentHome = ProcessInfo.processInfo.environment["AUTO_AGENT_AI_HOME"] ?? "\(home)/.auto-agent-ai"
let statePath = "\(agentHome)/state.json"
let logPath = "\(agentHome)/watch.log"
let keychainService = "Claude Code-credentials"
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
let updateRepo = "haonguyenstech/autoagent-status" // private repo with release zips
let installedAppPath = "\(home)/Applications/AutoAgent Status.app"

/// Read-only fine-grained PAT (Contents: read on the update repo only),
/// injected at build time from .update-token — see build.sh. Nil when absent.
var updateToken: String? {
    guard let d = Data(base64Encoded: updateTokenB64), !d.isEmpty,
          let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !s.isEmpty else { return nil }
    return s
}

// MARK: - Shell helpers

struct CommandResult {
    let code: Int32
    let output: String
}

/// `onOutput` is called on a background queue with the full accumulated output
/// each time a chunk arrives; return `true` from it to abort the process early
/// (used to bail out of an interactive sign-in we can't complete unattended).
@discardableResult
func runCommand(_ path: String, _ args: [String], timeout: TimeInterval = 30,
                extraPATH: [String] = [],
                onOutput: ((String) -> Bool)? = nil) -> CommandResult {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    proc.standardInput = FileHandle.nullDevice
    // Apps launched from Finder get a minimal PATH; the CLI needs node.
    // Include the resolved CLI's own bin dir (covers nvm/volta/asdf installs).
    var env = ProcessInfo.processInfo.environment
    var extraPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
    if let cli = cachedCLIPath {
        extraPaths.insert((cli as NSString).deletingLastPathComponent, at: 0)
    }
    // Highest-priority PATH entries (e.g. the no-op `open` shim used to stop the
    // login flow from auto-launching the sign-in browser).
    extraPaths.insert(contentsOf: extraPATH, at: 0)
    env["PATH"] = extraPaths.joined(separator: ":") + ":" + (env["PATH"] ?? "/usr/bin:/bin")
    proc.environment = env
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe

    var data = Data()
    let lock = NSLock()
    var aborted = false
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if !chunk.isEmpty {
            lock.lock()
            data.append(chunk)
            let snapshot = String(data: data, encoding: .utf8) ?? ""
            lock.unlock()
            if let onOutput, !aborted, onOutput(snapshot) {
                aborted = true
                proc.terminate()
            }
        }
    }

    do { try proc.run() } catch {
        return CommandResult(code: -1, output: "Failed to launch \(path): \(error.localizedDescription)")
    }

    let deadline = Date().addingTimeInterval(timeout)
    while proc.isRunning && Date() < deadline { usleep(50_000) }
    var timedOut = false
    if proc.isRunning {
        timedOut = true
        proc.terminate()
        usleep(300_000)
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
    }
    proc.waitUntilExit()
    usleep(50_000) // let the readability handler drain
    pipe.fileHandleForReading.readabilityHandler = nil

    lock.lock()
    let text = String(data: data, encoding: .utf8) ?? ""
    lock.unlock()
    let suffix = timedOut ? "\n[timed out after \(Int(timeout))s]" : ""
    return CommandResult(code: timedOut ? -2 : proc.terminationStatus,
                         output: text.trimmingCharacters(in: .whitespacesAndNewlines) + suffix)
}

func stripANSI(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
}

/// A directory whose `open` is a no-op script. Prepending it to a child's PATH
/// stops the CLI from auto-launching the Microsoft sign-in browser — which pops
/// a loading icon in the Dock on every login. The URL is still printed (and the
/// app shows an in-app "Open sign-in page" button), so sign-in still works; the
/// browser only appears when the user deliberately taps that button.
func noOpenShimDir() -> String? {
    let fm = FileManager.default
    guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
    let dir = base.appendingPathComponent("AutoAgent Status/shim", isDirectory: true)
    let openPath = dir.appendingPathComponent("open")
    do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.isExecutableFile(atPath: openPath.path) {
            try "#!/bin/sh\nexit 0\n".write(to: openPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: openPath.path)
        }
        return dir.path
    } catch { return nil }
}

/// The CLI hard-blocks with an "Update required" box when the installed
/// version is below the server's minimum — it exits non-zero and refuses to
/// run (login/push/logout/watcher) until it's npm-updated. Detect that so we
/// can prompt (or auto-update) instead of dumping the raw box as a failure.
func isUpdateRequired(_ output: String) -> Bool {
    let s = stripANSI(output).lowercased()
    return s.contains("update required")
        || s.contains("required update")
        || s.contains("can no longer be used")
}

/// `login` now does interactive Microsoft OAuth: it prints a sign-in URL and
/// waits for the browser callback. Pull that URL out of the CLI's output so we
/// can re-open it / show it as a fallback (the CLI tries to open it itself).
func extractLoginURL(_ output: String) -> String? {
    let clean = stripANSI(output)
    guard let re = try? NSRegularExpression(pattern: "https?://[^\\s\"'`)]+") else { return nil }
    let ns = clean as NSString
    let urls = re.matches(in: clean, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }
    // Prefer the CLI auth redirect (has cli_redirect/cli_state) over any other link.
    return urls.first { $0.contains("cli_redirect") || $0.contains("cli_state") }
        ?? urls.first { $0.contains("/login") }
}

let defaultServer = "https://vibe.saigontechnology.vn"
let npmCandidates = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]
let cliPackage = "@saigontechnology/auto-agent"

var cachedCLIPath: String?

/// Find the CLI: known locations first, then ask the user's login shell —
/// that picks up nvm / volta / asdf installs whose bin dirs aren't fixed.
func findCLI() -> String? {
    let fm = FileManager.default
    if let c = cachedCLIPath, fm.isExecutableFile(atPath: c) { return c }
    for p in cliCandidates where fm.isExecutableFile(atPath: p) {
        cachedCLIPath = p
        return p
    }
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let r = runCommand(shell, ["-l", "-i", "-c", "command -v auto-agent-ai"], timeout: 10)
    if let path = r.output.split(separator: "\n").map(String.init)
        .last(where: { $0.hasPrefix("/") }),
       fm.isExecutableFile(atPath: path) {
        cachedCLIPath = path
        return path
    }
    return nil
}

var npmPath: String? {
    var candidates = npmCandidates
    if let cli = cachedCLIPath {
        // npm usually lives next to the CLI (same node bin dir)
        candidates.insert((cli as NSString).deletingLastPathComponent + "/npm", at: 0)
    }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Any HTTP response (even 403/404) means the server is reachable.
func pingServer(_ urlString: String) -> (ok: Bool, ms: Int) {
    guard let url = URL(string: urlString) else { return (false, 0) }
    var req = URLRequest(url: url)
    req.httpMethod = "HEAD"
    req.timeoutInterval = 4
    var ok = false
    let start = Date()
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { _, resp, _ in
        ok = resp != nil
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 5)
    return (ok, Int(Date().timeIntervalSince(start) * 1000))
}

/// Resolve the CLI symlink and read version from its package.json (no subprocess).
func installedCLIVersion() -> String? {
    let fm = FileManager.default
    let candidates = (cachedCLIPath.map { [$0] } ?? []) + cliCandidates
    for cli in candidates where fm.fileExists(atPath: cli) {
        var resolved = (try? fm.destinationOfSymbolicLink(atPath: cli)) ?? cli
        if !resolved.hasPrefix("/") {
            resolved = ((cli as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent(resolved)
        }
        let pkgDir = ((resolved as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let pkg = ((pkgDir as NSString).appendingPathComponent("package.json") as NSString).standardizingPath
        if let d = fm.contents(atPath: pkg),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let v = obj["version"] as? String {
            return v
        }
    }
    return nil
}

/// Latest app release from the GitHub repo (works for the private repo via
/// the embedded read-only token; the asset API URL is used for download).
func fetchLatestAppRelease() -> (version: String, zipURL: String)? {
    guard let url = URL(string: "https://api.github.com/repos/\(updateRepo)/releases/latest") else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = 10
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    if let t = updateToken {
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
    }
    var result: (String, String)?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, _, _ in
        defer { sem.signal() }
        guard let data,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return }
        let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = obj["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let dl = zip["url"] as? String else { return } // asset API URL, not browser_download_url
        result = (ver, dl)
    }.resume()
    _ = sem.wait(timeout: .now() + 12)
    return result.map { (version: $0.0, zipURL: $0.1) }
}

func isNewer(_ a: String, than b: String) -> Bool {
    let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}

// MARK: - Token usage (same algorithm as the CLI: scan today's Claude
// Code transcripts in ~/.claude/projects/**/*.jsonl, dedupe by message id)

struct TokenUsage {
    var input = 0
    var output = 0
    var cacheCreate = 0
    var cacheRead = 0
    var costUSD = 0.0
    var billable: Int { input + output + cacheCreate }
    var total: Int { billable + cacheRead }
}

/// Per-token USD pricing by model family. Rates are $/million tokens from the
/// claude-api reference: Opus 5/25, Sonnet 3/15, Haiku 1/5 (input/output);
/// cache write = 1.25× input, cache read = 0.1× input.
struct ModelPricing {
    let input, output, cacheWrite, cacheRead: Double
}

func pricing(for model: String) -> ModelPricing? {
    func p(_ inMtok: Double, _ outMtok: Double) -> ModelPricing {
        ModelPricing(input: inMtok / 1_000_000, output: outMtok / 1_000_000,
                     cacheWrite: inMtok * 1.25 / 1_000_000, cacheRead: inMtok * 0.1 / 1_000_000)
    }
    let m = model.lowercased()
    if m.contains("opus") { return p(5, 25) }
    if m.contains("sonnet") { return p(3, 15) }
    if m.contains("haiku") { return p(1, 5) }
    return nil
}

func formatUSD(_ v: Double) -> String {
    if v >= 1 { return String(format: "$%.2f", v) }
    if v > 0 { return String(format: "$%.3f", v) }
    return "$0.00"
}

func formatTokens(_ n: Int) -> String {
    let d = Double(n)
    func fmt(_ v: Double) -> String {
        v >= 100 ? String(format: "%.1f", v) : String(format: "%.2f", v)
    }
    if d >= 1_000_000 { return fmt(d / 1_000_000) + "M" }
    if d >= 1_000 { return String(format: "%.1fK", d / 1_000) }
    return "\(n)"
}

struct DayUsage: Identifiable {
    let date: Date
    var billable = 0
    var costUSD = 0.0
    var id: Date { date }
}

/// Cumulative billable-token / cost totals over wider windows than "today".
struct PeriodTotals {
    var weekBillable = 0
    var weekCost = 0.0
    var monthBillable = 0
    var monthCost = 0.0
    var allBillable = 0
    var allCost = 0.0
}

// Per-file usage aggregate, persisted so unchanged transcripts (the bulk of the
// ~GB on disk) are parsed once and skipped on later scans — only files whose
// mtime/size changed are re-read. `monthly` (keyed "YYYY-MM") feeds month/all-
// time and survives a calendar rollover; `daily` (keyed "YYYY-MM-DD", kept only
// for the recent window) feeds today's breakdown and the 7-day chart, recomputed
// against the current date so a day-old cache still maps to the right bucket.
struct MonthAgg: Codable { var billable: Int = 0; var cost: Double = 0 }
/// Per-model token split for one day — mirrors the CLI's per-model breakdown
/// so the app can report it to the server (adding this field invalidates any
/// older on-disk cache once, triggering a single full rescan on first launch).
struct ModelAgg: Codable { var input = 0, output = 0, cacheCreate = 0, cacheRead = 0 }
struct DayAgg: Codable {
    var input = 0, output = 0, cacheCreate = 0, cacheRead = 0
    var cost: Double = 0
    var models: [String: ModelAgg] = [:]
}
struct FileAgg: Codable {
    var mtime: Double
    var size: Int
    var monthly: [String: MonthAgg]
    var daily: [String: DayAgg]
}

private func usageCacheURL() -> URL? {
    let fm = FileManager.default
    guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
    let dir = base.appendingPathComponent("AutoAgentStatus", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("usage-cache.json")
}
private func loadUsageCache() -> [String: FileAgg] {
    guard let url = usageCacheURL(), let data = try? Data(contentsOf: url),
          let c = try? JSONDecoder().decode([String: FileAgg].self, from: data) else { return [:] }
    return c
}
private func saveUsageCache(_ c: [String: FileAgg]) {
    guard let url = usageCacheURL(), let data = try? JSONEncoder().encode(c) else { return }
    try? data.write(to: url)
}

/// Single scan of the Claude transcripts. Returns today's full breakdown, a
/// per-day billable/cost history for the last `days` days (oldest first), and
/// cumulative totals for this week / this calendar month / all-time.
///
/// The month/all-time totals need every transcript, but ~GB of those never
/// change. We persist a per-file aggregate keyed by path + mtime + size and only
/// re-read files whose mtime/size moved — so steady-state scans read just the
/// few active sessions, and everything else comes from the cache.
func readUsageReport(days: Int = 7) -> (today: TokenUsage, history: [DayUsage], totals: PeriodTotals, todayModels: [String: ModelAgg]) {
    var today = TokenUsage()
    var todayModels: [String: ModelAgg] = [:]
    var totals = PeriodTotals()
    var buckets = Array(repeating: (tokens: 0, cost: 0.0), count: days) // index 0 = today
    let fm = FileManager.default
    let cal = Calendar.current
    let startToday = cal.startOfDay(for: Date())
    func ymKey(_ day: Date) -> String {
        let c = cal.dateComponents([.year, .month], from: day)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
    func dmyKey(_ day: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    func daysAgoOf(dayKey: String) -> Int? {
        let p = dayKey.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var c = DateComponents(); c.year = p[0]; c.month = p[1]; c.day = p[2]
        guard let day = cal.date(from: c) else { return nil }
        return cal.dateComponents([.day], from: cal.startOfDay(for: day), to: startToday).day
    }
    let curYM = ymKey(startToday)

    var configDirs = ["\(home)/.claude"]
    if let cfg = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
        configDirs.append(cfg)
    }

    let isoFrac = ISO8601DateFormatter()
    isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let iso = ISO8601DateFormatter()

    let cache = loadUsageCache()
    var freshCache: [String: FileAgg] = [:]

    // Fold one file's cached aggregate into the running totals/buckets.
    func fold(_ agg: FileAgg) {
        for (ym, m) in agg.monthly {
            totals.allBillable += m.billable; totals.allCost += m.cost
            if ym == curYM { totals.monthBillable += m.billable; totals.monthCost += m.cost }
        }
        for (dk, a) in agg.daily {
            guard let ago = daysAgoOf(dayKey: dk), ago >= 0 && ago < days else { continue }
            buckets[ago].tokens += a.input + a.output + a.cacheCreate
            buckets[ago].cost += a.cost
            if ago == 0 {
                today.input += a.input; today.output += a.output
                today.cacheCreate += a.cacheCreate; today.cacheRead += a.cacheRead
                today.costUSD += a.cost
                for (m, ma) in a.models {
                    var t = todayModels[m] ?? ModelAgg()
                    t.input += ma.input; t.output += ma.output
                    t.cacheCreate += ma.cacheCreate; t.cacheRead += ma.cacheRead
                    todayModels[m] = t
                }
            }
        }
    }

    for dir in configDirs {
        let projects = dir + "/projects"
        guard let en = fm.enumerator(atPath: projects) else { continue }
        for case let rel as String in en {
            guard rel.hasSuffix(".jsonl") else { continue }
            let path = projects + "/" + rel
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            let size = (attrs[.size] as? Int) ?? 0

            // Unchanged file → reuse the cached aggregate, no read.
            if let agg = cache[path],
               agg.mtime == mtime.timeIntervalSince1970, agg.size == size {
                freshCache[path] = agg
                fold(agg)
                continue
            }

            guard let data = fm.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) else { continue }

            var fileMonthly: [String: MonthAgg] = [:]
            var fileDaily: [String: DayAgg] = [:]
            var fileSeen = Set<String>() // dedup within this file

            for line in text.split(separator: "\n") {
                guard line.contains("\"usage\""),
                      let d = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { continue }
                // Which day does this entry belong to? (no timestamp → treat as today)
                var entryDay = startToday
                if let ts = obj["timestamp"] as? String {
                    guard let date = isoFrac.date(from: ts) ?? iso.date(from: ts) else { continue }
                    entryDay = cal.startOfDay(for: date)
                }
                let daysAgo = cal.dateComponents([.day], from: entryDay, to: startToday).day ?? 999
                if daysAgo < 0 { continue } // future-dated entry — ignore

                if let mid = msg["id"] as? String {
                    let key = mid + "\u{0}" + ((obj["requestId"] as? String) ?? "")
                    if fileSeen.contains(key) { continue }
                    fileSeen.insert(key)
                }

                let inp = usage["input_tokens"] as? Int ?? 0
                let out = usage["output_tokens"] as? Int ?? 0
                let cc = usage["cache_creation_input_tokens"] as? Int ?? 0
                let cr = usage["cache_read_input_tokens"] as? Int ?? 0
                let model = (msg["model"] as? String) ?? "unknown"
                var cost = 0.0
                if let pr = pricing(for: model) {
                    cost = Double(inp) * pr.input + Double(out) * pr.output
                        + Double(cc) * pr.cacheWrite + Double(cr) * pr.cacheRead
                }

                let ym = ymKey(entryDay)
                fileMonthly[ym, default: MonthAgg()].billable += inp + out + cc
                fileMonthly[ym, default: MonthAgg()].cost += cost
                // Keep per-day detail only for the recent window (bounds cache size;
                // aging only pushes entries further out, never back in).
                if daysAgo < days {
                    let dk = dmyKey(entryDay)
                    var day = fileDaily[dk] ?? DayAgg()
                    day.input += inp; day.output += out
                    day.cacheCreate += cc; day.cacheRead += cr; day.cost += cost
                    var ma = day.models[model] ?? ModelAgg()
                    ma.input += inp; ma.output += out
                    ma.cacheCreate += cc; ma.cacheRead += cr
                    day.models[model] = ma
                    fileDaily[dk] = day
                }
            }

            let agg = FileAgg(mtime: mtime.timeIntervalSince1970, size: size,
                              monthly: fileMonthly, daily: fileDaily)
            freshCache[path] = agg
            fold(agg)
        }
    }

    saveUsageCache(freshCache)

    for b in buckets { totals.weekBillable += b.tokens; totals.weekCost += b.cost }
    let history = (0..<days).reversed().map { i in
        DayUsage(date: cal.date(byAdding: .day, value: -i, to: startToday) ?? startToday,
                 billable: buckets[i].tokens, costUSD: buckets[i].cost)
    }
    return (today, history, totals, todayModels)
}

// MARK: - Usage report upload (POST /api/v1/usage/me)
//
// The CLI reports today's Claude Code token usage to the server every 5 minutes
// — but only from its *interactive* foreground session (`Ka()` → `/usage/me`).
// The detached `__watch` process the app launches never uploads it, so relying
// on the app alone left the server with no report. We reproduce that upload
// natively: same payload, same 5-minute cadence (driven by `refreshUsage`).
//
// Auth uses the server session token the CLI stores in ~/.auto-agent-ai/
// .config.json (`auth.accessToken`), which the running watcher keeps refreshed.
// This is client-only — the owner role uses a different, watcher-driven endpoint
// (/usage/by-token/claude-usage) that we don't touch.

/// The auto-agent-ai server session access token, if present.
func readAgentAuthToken() -> String? {
    guard let d = FileManager.default.contents(atPath: "\(agentHome)/.config.json"),
          let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
          let auth = obj["auth"] as? [String: Any],
          let tok = auth["accessToken"] as? String, !tok.isEmpty else { return nil }
    return tok
}

/// Claude Code's configured effort level (`~/.claude/settings.json`), if any.
func readClaudeEffortLevel() -> String? {
    guard let d = FileManager.default.contents(atPath: "\(home)/.claude/settings.json"),
          let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
          let e = obj["effortLevel"] as? String else { return nil }
    return e
}

/// Today's date in the server's timezone (Asia/Ho_Chi_Minh), matching the CLI.
private func reportDateString() -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
    df.dateFormat = "yyyy-MM-dd"
    return df.string(from: Date())
}

/// POST today's usage to the server. No-op for the owner role (uses a different
/// endpoint) or when logged out / no auth token. On 401 we simply skip — the
/// watcher refreshes the stored token within ~30s, so the next cycle succeeds;
/// we deliberately don't rewrite the CLI's .config.json to avoid racing its
/// refresh-token rotation. Best-effort and silent, like the CLI's uploader.
func pushUsageReport(server: String, role: String?, today: TokenUsage,
                     models: [String: ModelAgg]) {
    guard let role, role != "owner" else { return }
    guard let token = readAgentAuthToken() else { return }
    let base = server.hasSuffix("/") ? String(server.dropLast()) : server
    guard let url = URL(string: "\(base)/api/v1/usage/me") else { return }

    let modelsPayload: [[String: Any]] = models.map { name, m in
        ["model": name, "inputTokens": m.input, "outputTokens": m.output,
         "cacheReadTokens": m.cacheRead, "cacheCreationTokens": m.cacheCreate]
    }
    let body: [String: Any] = [
        "date": reportDateString(),
        "inputTokens": today.input,
        "outputTokens": today.output,
        "cacheCreationTokens": today.cacheCreate,
        "effortLevel": readClaudeEffortLevel() ?? NSNull(),
        "models": modelsPayload,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 12
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    // Mirror the CLI's X-Client-Version (its own package version) so any
    // server-side min-version gating treats us the same as the CLI.
    req.setValue(installedCLIVersion() ?? appVersion, forHTTPHeaderField: "X-Client-Version")
    req.httpBody = data

    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
    _ = sem.wait(timeout: .now() + 14)
}

// MARK: - auto-agent server API (same base + auth the CLI uses)

/// GET `{server}/api/v1/<path>` with the CLI's stored session token and its
/// `X-Client-Version` header. Returns the unwrapped `data` field, or nil.
func agentAPIGet(_ path: String, server: String) -> Any? {
    guard let token = readAgentAuthToken() else { return nil }
    let base = server.hasSuffix("/") ? String(server.dropLast()) : server
    guard let url = URL(string: "\(base)/api/v1/\(path)") else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = 12
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(installedCLIVersion() ?? appVersion, forHTTPHeaderField: "X-Client-Version")

    var result: Any?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        defer { sem.signal() }
        guard let data, let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        result = obj["data"]
    }.resume()
    _ = sem.wait(timeout: .now() + 14)
    return result
}

/// The server's own CLI version gate (`GET /app-versions/check?version=…`) —
/// the same call the CLI makes before every command. It is the authority on
/// what's current: it knows the minimum version (`forceUpdate`, the hard block
/// that makes the CLI refuse to run) and ships release notes, neither of which
/// the npm registry can tell us.
struct CLIVersionCheck: Equatable {
    var latest: String
    var updateAvailable: Bool
    var forceUpdate: Bool
    var notes: String?
}

func fetchCLIVersionCheck(server: String, installed: String?) -> CLIVersionCheck? {
    guard let version = installed ?? installedCLIVersion() else { return nil }
    guard let obj = agentAPIGet("app-versions/check?version=\(version)", server: server) as? [String: Any],
          let latest = obj["latestVersion"] as? String else { return nil }
    let notes = (obj["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return CLIVersionCheck(latest: latest,
                           updateAvailable: obj["updateAvailable"] as? Bool ?? false,
                           forceUpdate: obj["forceUpdate"] as? Bool ?? false,
                           notes: (notes?.isEmpty ?? true) ? nil : notes)
}

private let isoParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func parseISODate(_ s: String?) -> Date? {
    guard let s else { return nil }
    return isoParser.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

/// The Claude Code session this machine is assigned to (`GET /ai-sessions/me`) —
/// the CLI shows its name in the menu header; the app shows it in Credential.
struct AISessionInfo: Equatable {
    var id: String
    var name: String
    var isActive: Bool
    var updatedAt: Date?
    var members: [String]
    var createdBy: String?
}

func fetchAISession(server: String, sessionId: String?) -> AISessionInfo? {
    guard let arr = agentAPIGet("ai-sessions/me", server: server) as? [[String: Any]],
          !arr.isEmpty else { return nil }
    let obj = arr.first { ($0["id"] as? String) == sessionId } ?? arr[0]
    guard let id = obj["id"] as? String else { return nil }
    let members = (obj["assignedUsers"] as? [[String: Any]])?
        .compactMap { $0["username"] as? String } ?? []
    let creator = (obj["createdBy"] as? [String: Any])?["displayName"] as? String
    return AISessionInfo(id: id,
                         name: obj["name"] as? String ?? "session",
                         isActive: obj["isActive"] as? Bool ?? true,
                         updatedAt: parseISODate(obj["updatedAt"] as? String),
                         members: members,
                         createdBy: creator)
}

/// The shared Figma session assigned to this user (`GET /figma-sessions/me`).
/// The CLI only offers its Figma menu when this exists, and only offers
/// "Login to Figma" when `hasSession` is true — the app mirrors both rules.
struct FigmaSessionInfo: Equatable {
    var sessionId: String
    var name: String
    var isActive: Bool
    var hasSession: Bool
    var cookieCount: Int
    var accounts: [FigmaAccount]
    var capturedAt: Date?
    var memberCount: Int

    /// "figma3@company.com" — what the shared login actually signs you in as.
    var sharedLabel: String? {
        accounts.first?.email ?? (cookieCount > 0 ? "\(cookieCount) cookies" : nil)
    }
}

func fetchFigmaSession(server: String) -> FigmaSessionInfo? {
    guard let arr = agentAPIGet("figma-sessions/me", server: server) as? [[String: Any]],
          let obj = arr.first else { return nil }
    let accounts = (obj["accounts"] as? [[String: Any]])?.compactMap { a -> FigmaAccount? in
        guard let id = a["id"] as? String, let label = a["label"] as? String else { return nil }
        return FigmaAccount(id: id, email: label, active: a["active"] as? Bool ?? false,
                            plan: a["plan"] as? String)
    } ?? []
    return FigmaSessionInfo(
        sessionId: obj["sessionId"] as? String ?? "",
        name: obj["name"] as? String ?? "Figma session",
        isActive: obj["isActive"] as? Bool ?? true,
        hasSession: obj["hasSession"] as? Bool ?? false,
        cookieCount: obj["cookieCount"] as? Int ?? 0,
        accounts: accounts,
        capturedAt: parseISODate(obj["capturedAt"] as? String),
        memberCount: (obj["assignedUsernames"] as? [String])?.count ?? 0)
}

// MARK: - Plan usage (subscription rate limits — the same session/weekly
// percentages Claude Code's /usage screen shows, from the OAuth usage endpoint)

/// One rate-limit window: how much of the allowance is used (0–100) and when it
/// resets. `severity` mirrors the API ("normal"/"warning"/"reached"…).
struct PlanLimit: Identifiable {
    let label: String
    let percent: Double
    let resetsAt: Date?
    let severity: String
    var id: String { label }
    var color: Color {
        if percent >= 100 || severity == "reached" { return .red }
        if percent >= 80 || severity == "warning" { return .orange }
        return .green
    }
}

struct PlanUsage {
    var limits: [PlanLimit] = []
}

/// The Claude Code OAuth access token from the login Keychain item, if present.
func readOAuthAccessToken() -> String? {
    let secret = runCommand("/usr/bin/security",
                            ["find-generic-password", "-s", keychainService, "-w"], timeout: 5)
    guard secret.code == 0, let d = secret.output.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
          let oauth = obj["claudeAiOauth"] as? [String: Any],
          let tok = oauth["accessToken"] as? String, !tok.isEmpty else { return nil }
    return tok
}

/// Fetch the subscription session/weekly usage from Anthropic's OAuth usage
/// endpoint. Read-only; does not consume message quota. Returns nil on any
/// failure (no token, offline, non-2xx) so the card just hides itself.
func fetchPlanUsage() -> PlanUsage? {
    guard let tok = readOAuthAccessToken(),
          let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = 12
    req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

    var result: PlanUsage?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        defer { sem.signal() }
        guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        func date(_ v: Any?) -> Date? {
            guard let s = v as? String else { return nil }
            return isoFrac.date(from: s) ?? iso.date(from: s)
        }
        func window(_ key: String, _ label: String) -> PlanLimit? {
            guard let o = obj[key] as? [String: Any],
                  let u = (o["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return PlanLimit(label: label, percent: u, resetsAt: date(o["resets_at"]),
                             severity: (o["severity"] as? String) ?? "normal")
        }
        var limits: [PlanLimit] = []
        if let s = window("five_hour", "Session") { limits.append(s) }
        if let w = window("seven_day", "Week (all models)") { limits.append(w) }
        if let opus = window("seven_day_opus", "Week · Opus") { limits.append(opus) }
        guard !limits.isEmpty else { return }
        result = PlanUsage(limits: limits)
    }.resume()
    _ = sem.wait(timeout: .now() + 14)
    return result
}

/// Notification categories the user can mute individually (default: on).
enum NotifKind: String, CaseIterable {
    case watcher, credential, updates, signIn, keepAwake, figma

    var key: String { "notify_\(rawValue)" }
    var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    var title: String {
        switch self {
        case .watcher: return "Watcher"
        case .credential: return "Credential & token"
        case .updates: return "Updates"
        case .signIn: return "Sign-in prompts"
        case .keepAwake: return "Keep-awake"
        case .figma: return "Figma session"
        }
    }
    var icon: String {
        switch self {
        case .watcher: return "eye"
        case .credential: return "key.fill"
        case .updates: return "arrow.down.circle"
        case .signIn: return "person.badge.shield.checkmark"
        case .keepAwake: return "cup.and.saucer"
        case .figma: return "paintpalette"
        }
    }
}

func notify(_ title: String, _ body: String, kind: NotifKind) {
    guard kind.enabled else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
}

// MARK: - Status model

struct AgentStatus {
    var watcherRunning = false
    var watcherPid: Int?
    var credentialPresent = false
    var expiresAt: Date?
    var role: String?
    var username: String?
    var serverUrl: String?
    var lastLogLine: String?
    var serverOK: Bool?
    var serverLatencyMs: Int?
    /// Written by the CLI for the primary user (owner): the per-session
    /// handshake token `push` / `figma upload|revoke` need, and its session id.
    var handshakeToken: String?
    var sessionId: String?

    var isOwner: Bool { role == "owner" }

    var credentialValid: Bool {
        guard let e = expiresAt else { return false }
        return e > Date()
    }

    enum State { case active, warning, inactive }

    var state: State {
        if watcherRunning && credentialValid { return .active }
        if watcherRunning || credentialPresent { return .warning }
        return .inactive
    }

    var headline: String {
        switch (watcherRunning, credentialValid, credentialPresent) {
        case (true, true, _): return "Credential synced and watching"
        case (true, false, true): return "Credential expired — watcher syncing"
        case (true, false, false): return "Watcher running — waiting for credential"
        case (false, _, true): return "Watcher stopped — credential present"
        default: return "Logged out"
        }
    }

    var stateLabel: String {
        switch state {
        case .active: return "Active"
        case .warning: return "Attention"
        case .inactive: return "Offline"
        }
    }

    var color: Color {
        switch state {
        case .active: return .green
        case .warning: return .orange
        case .inactive: return .gray
        }
    }

    var symbolName: String {
        switch state {
        case .active: return "key.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .inactive: return "key.slash"
        }
    }
}

func readStatus() -> AgentStatus {
    var s = AgentStatus()

    // 1. Background watcher process
    let pg = runCommand("/usr/bin/pgrep", ["-f", "auto-agent-ai __watch"], timeout: 5)
    if pg.code == 0, let first = pg.output.split(separator: "\n").first, let pid = Int(first) {
        s.watcherRunning = true
        s.watcherPid = pid
    }

    // 2. Local state written by the CLI
    if let d = FileManager.default.contents(atPath: statePath),
       let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
        s.role = obj["role"] as? String
        s.username = obj["username"] as? String
        s.serverUrl = obj["serverUrl"] as? String
        s.sessionId = obj["sessionId"] as? String
        s.handshakeToken = (obj["handshakeToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    // 3. Server reachability
    let ping = pingServer(s.serverUrl ?? defaultServer)
    s.serverOK = ping.ok
    s.serverLatencyMs = ping.ok ? ping.ms : nil

    // 4. Keychain credential + expiry
    let exists = runCommand("/usr/bin/security", ["find-generic-password", "-s", keychainService], timeout: 5)
    if exists.code == 0 {
        s.credentialPresent = true
        let secret = runCommand("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-w"], timeout: 5)
        if secret.code == 0,
           let d = secret.output.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let oauth = obj["claudeAiOauth"] as? [String: Any] {
            if let ms = oauth["expiresAt"] as? Double {
                s.expiresAt = Date(timeIntervalSince1970: ms / 1000)
            } else if let ms = oauth["expiresAt"] as? Int {
                s.expiresAt = Date(timeIntervalSince1970: Double(ms) / 1000)
            }
        }
    }

    // 5. Last watcher log line (tail ~4 KB)
    if let fh = FileHandle(forReadingAtPath: logPath) {
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > 4096 ? size - 4096 : 0
        try? fh.seek(toOffset: start)
        if let d = try? fh.readToEnd(), let text = String(data: d, encoding: .utf8) {
            s.lastLogLine = text.split(separator: "\n").map(String.init)
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        }
    }

    return s
}

// MARK: - Figma session sharing (`auto-agent-ai figma …`, CLI ≥ 1.1.16)

/// One Figma account signed in on this Mac, as printed by `figma list`:
///   `1) me@company.com (active)  id=15761…  plan=team:11803…`
struct FigmaAccount: Identifiable, Equatable {
    let id: String
    let email: String
    let active: Bool
    let plan: String?

    /// "team" / "pro" — the part before the plan's org id.
    var planKind: String? {
        guard let plan, !plan.isEmpty else { return nil }
        return plan.split(separator: ":").first.map(String.init)
    }
}

struct FigmaState: Equatable {
    var accounts: [FigmaAccount] = []
    /// Why we couldn't read the local Figma profile (Figma not installed, Node
    /// too old, Keychain unreadable…). Shown instead of the account list.
    var problem: String?
    var desktopRunning = false
    var checked = false

    var activeAccount: FigmaAccount? { accounts.first { $0.active } ?? accounts.first }
}

/// Figma Desktop must be fully quit before cookies can be written/removed —
/// the CLI refuses otherwise ("Figma Desktop is running. Quit it completely").
func figmaDesktopApps() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.figma.Desktop")
}

func figmaDesktopRunning() -> Bool {
    if !figmaDesktopApps().isEmpty { return true }
    // Fall back to the same check the CLI does (covers a renamed bundle id).
    return runCommand("/usr/bin/pgrep", ["-x", "Figma"], timeout: 5).code == 0
}

let figmaAppPath = "/Applications/Figma.app"

/// Ask Figma Desktop to quit and wait (up to `timeout`) for it to actually go.
@discardableResult
func quitFigmaDesktop(timeout: TimeInterval = 12) -> Bool {
    let apps = figmaDesktopApps()
    apps.forEach { $0.terminate() }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !figmaDesktopRunning() { return true }
        usleep(300_000)
    }
    // Last resort: force it, then give it a moment.
    figmaDesktopApps().forEach { $0.forceTerminate() }
    usleep(800_000)
    return !figmaDesktopRunning()
}

private let figmaLineRegex = try? NSRegularExpression(
    pattern: #"\d+\)\s+(\S+?)(\s+\(active\))?\s+id=([A-Za-z0-9_-]+)(?:\s+plan=(\S+))?\s*$"#)

/// Parse `auto-agent-ai figma list`. Its lines carry a `HH:MM:SS` log prefix,
/// so match on the trailing `N) email … id=… plan=…` shape only.
func parseFigmaList(_ output: String) -> [FigmaAccount] {
    guard let re = figmaLineRegex else { return [] }
    var out: [FigmaAccount] = []
    for raw in stripANSI(output).split(separator: "\n") {
        let line = String(raw)
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r).trimmingCharacters(in: .whitespaces)
        }
        guard let email = group(1), let id = group(3) else { continue }
        out.append(FigmaAccount(id: id, email: email, active: group(2) != nil, plan: group(4)))
    }
    return out
}

func readFigmaState() -> FigmaState {
    var s = FigmaState()
    s.desktopRunning = figmaDesktopRunning()
    s.checked = true
    guard let cli = findCLI() else {
        s.problem = "auto-agent-ai CLI not found."
        return s
    }
    let r = runCommand(cli, ["figma", "list"], timeout: 45)
    let text = stripANSI(r.output)
    s.accounts = parseFigmaList(text)
    if s.accounts.isEmpty {
        if text.lowercased().contains("no figma account is signed in") {
            s.problem = nil // genuinely signed out — not an error
        } else if r.code != 0 || text.isEmpty {
            // Surface the CLI's own explanation (missing profile, old Node, …).
            let line = text.split(separator: "\n").map(String.init)
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            s.problem = line.map { stripLogTimestamp($0) } ?? "Couldn't read the Figma profile."
        }
    }
    return s
}

/// Drop the CLI's `10:09:37  ` log prefix so messages read cleanly in the UI.
func stripLogTimestamp(_ s: String) -> String {
    s.replacingOccurrences(of: #"^\s*\d{2}:\d{2}:\d{2}\s*"#, with: "",
                           options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

// MARK: - Keep-awake (runs `caffeinate` — mirrors the proven `live` shell alias)

/// Keeps the Mac awake by launching `caffeinate -dimsu`, exactly like the
/// shell `live` function. The bare `PreventUserIdleSystemSleep` IOKit assertion
/// we used before only covered idle *system* sleep (equivalent to `caffeinate
/// -i`), so the display and the system itself could still sleep — which is why
/// it didn't reliably keep the Mac up. Flags here match the alias:
///   -d prevent display sleep   -i prevent idle system sleep
///   -m prevent disk idle sleep -s prevent system sleep (on AC)
///   -u declare the user active
/// `-w <appPID>` ties caffeinate's lifetime to this app: if the app crashes
/// without calling `stop()`, caffeinate exits too and never orphans.
final class SleepGuard {
    private var proc: Process?
    private(set) var active = false

    func start(reason: String) {
        guard !active else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-dimsu", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            proc = p
            active = true
        } catch {
            proc = nil
            active = false
        }
    }

    func stop() {
        guard active else { return }
        proc?.terminate()
        proc = nil
        active = false
    }
}

// MARK: - Clamshell (lid-closed) keep-awake — runs `pmset disablesleep`

/// Keeps the Mac running with the lid CLOSED and no external display attached.
///
/// `caffeinate`/IOKit assertions can't do this — closing the lid triggers a
/// firmware-level "clamshell sleep" that ignores every power assertion. The one
/// software lever Apple still exposes (even on Apple Silicon) is the pmset
/// `disablesleep` flag, exactly what Amphetamine's Closed-Display Mode flips:
///   `pmset -a disablesleep 1`  → lid-close never sleeps
///   `pmset -a disablesleep 0`  → back to normal
///
/// `disablesleep` needs root. To avoid a password prompt on every toggle (and,
/// crucially, on the silent revert we run when the app quits), we install a
/// tightly-scoped passwordless sudoers rule on first use — one admin prompt
/// ever, allowing ONLY `pmset -a disablesleep 0|1` for this user. After that
/// every flip is silent.
///
/// SAFETY: `disablesleep` is a persistent system setting, not tied to our PID —
/// if we leave it on and the app dies, the Mac never sleeps with no UI to undo
/// it. So we revert on quit, and clear an "armed" flag on clean exit; a stale
/// flag on next launch means we crashed mid-session and we silently revert.
final class ClamshellGuard {
    private(set) var active = false
    private let sudoersPath = "/etc/sudoers.d/autoagent-clamshell"
    private let armedKey = "clamshellArmed"

    var sudoersInstalled: Bool { FileManager.default.fileExists(atPath: sudoersPath) }

    /// Actual kernel state, read from `pmset -g` (`SleepDisabled 1`).
    var systemDisabled: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return false }
        return out.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    /// Flip `disablesleep` silently via the NOPASSWD sudoers rule. Returns true
    /// on success; false if the rule isn't installed or sudo declined.
    @discardableResult
    private func silentSet(_ on: Bool) -> Bool {
        guard sudoersInstalled else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }

    /// Enable lid-closed mode. Installs the sudoers rule on first use (one admin
    /// prompt), then flips the flag. Returns nil on success or an error message
    /// ("cancelled" if the user dismissed the password prompt).
    func enable() -> String? {
        if silentSet(true) {
            active = true
            UserDefaults.standard.set(true, forKey: armedKey)
            return nil
        }
        if let err = privileged(installAndSetScript(on: true)) { return err }
        active = true
        UserDefaults.standard.set(true, forKey: armedKey)
        return nil
    }

    /// Turn lid-closed mode off. Silent when the sudoers rule exists; otherwise
    /// falls back to a one-off admin prompt.
    func disable() -> String? {
        defer { UserDefaults.standard.set(false, forKey: armedKey) }
        if silentSet(false) { active = false; return nil }
        if let err = privileged(setScript(on: false)) { return err }
        active = false
        return nil
    }

    /// Best-effort silent revert for app-quit / crash-recovery. Never prompts.
    func revertQuietly() {
        silentSet(false)
        active = false
        UserDefaults.standard.set(false, forKey: armedKey)
    }

    /// True if a previous run left the flag armed without a clean revert
    /// (crash / force-quit) — the caller should revert on launch.
    var leftOrphaned: Bool {
        UserDefaults.standard.bool(forKey: armedKey) && systemDisabled
    }

    // MARK: Privileged helpers

    /// Shell run as root via a single `with administrator privileges` prompt.
    /// Body is staged to a temp file so we don't have to escape it into AppleScript.
    private func privileged(_ body: String) -> String? {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("autoagent-clamshell.sh")
        do { try body.write(toFile: path, atomically: true, encoding: .utf8) }
        catch { return "could not stage helper script" }
        defer { try? FileManager.default.removeItem(atPath: path) }

        let source = "do shell script \"/bin/sh \(path)\" with administrator privileges"
        var errorDict: NSDictionary?
        guard let apple = NSAppleScript(source: source) else { return "could not build helper" }
        apple.executeAndReturnError(&errorDict)
        if let e = errorDict {
            let code = (e["NSAppleScriptErrorNumber"] as? Int) ?? 0
            if code == -128 { return "cancelled" } // user dismissed the prompt
            return (e["NSAppleScriptErrorMessage"] as? String) ?? "admin command failed (\(code))"
        }
        return nil
    }

    private func setScript(on: Bool) -> String {
        "/usr/bin/pmset -a disablesleep \(on ? "1" : "0")\n"
    }

    /// Validate + install the NOPASSWD sudoers rule, then set the flag — all in
    /// the one root shell so it costs a single password prompt.
    private func installAndSetScript(on: Bool) -> String {
        let user = NSUserName()
        return """
        #!/bin/sh
        set -e
        CONTENT='\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1'
        TMP=$(mktemp)
        printf '%s\\n' "$CONTENT" > "$TMP"
        if /usr/sbin/visudo -cf "$TMP" >/dev/null 2>&1; then
          /usr/bin/install -m 0440 -o root -g wheel "$TMP" \(sudoersPath)
          rm -f "$TMP"
        else
          rm -f "$TMP"
          exit 3
        fi
        /usr/bin/pmset -a disablesleep \(on ? "1" : "0")
        """
    }
}

// MARK: - Store

final class StatusStore: ObservableObject {
    @Published var status = AgentStatus()
    @Published var busy: String?
    @Published var lastError: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var autoRestart = UserDefaults.standard.object(forKey: "autoRestart") as? Bool ?? true
    @Published var installedVersion: String?
    @Published var latestVersion: String?
    @Published var updatingCLI = false
    @Published var autoUpdateCLI = UserDefaults.standard.object(forKey: "autoUpdateCLI") as? Bool ?? true
    @Published var usage: TokenUsage?
    @Published var usageHistory: [DayUsage] = []
    @Published var usageTotals: PeriodTotals?
    @Published var planUsage: PlanUsage?
    // Per-category notification mutes (default on).
    @Published var notifyWatcher = NotifKind.watcher.enabled
    @Published var notifyCredential = NotifKind.credential.enabled
    @Published var notifyUpdates = NotifKind.updates.enabled
    @Published var notifySignIn = NotifKind.signIn.enabled
    @Published var notifyKeepAwake = NotifKind.keepAwake.enabled
    @Published var notifyFigma = NotifKind.figma.enabled
    @Published var appLatestVersion: String?
    @Published var appDownloadURL: String?
    @Published var updatingApp = false
    /// CLI returned the "Update required" hard-block — it can't run until updated.
    @Published var cliUpdateRequired = false
    /// What's in the newest CLI release, per the server's version check.
    @Published var cliReleaseNotes: String?
    /// Microsoft sign-in URL while an interactive login is waiting on the browser.
    @Published var loginURL: String?

    // Figma session sharing (`auto-agent-ai figma`).
    @Published var figma = FigmaState()
    /// Name of the running figma command ("import", "sign out", …), or nil.
    @Published var figmaBusy: String?
    @Published var figmaError: String?
    /// Owner/primary-user handshake token used by `push` / `figma upload|revoke`.
    /// The CLI stores its own copy in state.json once you log in as primary
    /// user; this is the fallback when it hasn't (or for a different session).
    @Published var figmaToken = UserDefaults.standard.string(forKey: "figmaToken") ?? ""
    /// The shared Figma session assigned to this user, server-side.
    @Published var figmaSession: FigmaSessionInfo?
    /// The Claude Code session this machine pulls its credential from.
    @Published var aiSession: AISessionInfo?

    /// A token typed here wins (that's the user switching sessions on purpose);
    /// otherwise use the one the CLI stored in state.json at login.
    var handshakeToken: String? {
        let typed = figmaToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        if let t = status.handshakeToken, !t.isEmpty { return t }
        return nil
    }

    /// The CLI only offers "Login to Figma" when a login has been uploaded to
    /// the assigned session — same gate here.
    var canImportFigma: Bool { figmaSession?.hasSession == true }

    // Keep-awake: prevent the Mac from sleeping for a chosen duration.
    @Published var keepAwake = false
    @Published var keepAwakeHours = UserDefaults.standard.object(forKey: "keepAwakeHours") as? Int ?? 2
    @Published var keepAwakeUntil: Date?
    /// Keep the Mac awake automatically whenever the watcher is running.
    @Published var autoAwakeWithWatcher = UserDefaults.standard.bool(forKey: "autoAwakeWithWatcher")
    /// Selectable durations (hours); 0 means "until I turn it off".
    let keepAwakeOptions = [2, 4, 6, 8, 10, 12]

    /// The Mac is being held awake — manually, or automatically while the watcher runs.
    var isStayingAwake: Bool { keepAwake || (autoAwakeWithWatcher && status.watcherRunning) }

    /// Lid-closed (clamshell) keep-awake: run with the lid shut, no external
    /// display needed. Session-scoped — reverted on quit for safety.
    @Published var lidClosedAwake = false
    @Published var lidClosedBusy = false
    private let clamshellGuard = ClamshellGuard()

    private let workQueue = DispatchQueue(label: "auto-agent-status.work")
    private let usageQueue = DispatchQueue(label: "auto-agent-status.usage", qos: .utility)
    private let figmaQueue = DispatchQueue(label: "auto-agent-status.figma")
    private var lastFigmaScan = Date.distantPast
    private var lastSessionFetch = Date.distantPast
    private var lastVersionCheck = Date.distantPast
    private var lastUsageScan = Date.distantPast
    private var lastPlanFetch = Date.distantPast
    private var hasStatus = false
    private var lastUserAction = Date.distantPast
    private var lastAutoRestartAt = Date.distantPast

    private let sleepGuard = SleepGuard()
    private var keepAwakeTimer: DispatchWorkItem?

    // Token-expiry warnings: notify once per threshold (minutes) per credential.
    private let expiryThresholds = [30, 15, 5]
    private var firedExpiryWarnings = Set<Int>()
    private var lastExpirySeen: Date?

    /// Last role we logged in with — survives the CLI wiping state.json,
    /// so auto-restart knows what to log back in as.
    private var savedRole: String? {
        get { UserDefaults.standard.string(forKey: "lastRole") }
        set { UserDefaults.standard.set(newValue, forKey: "lastRole") }
    }

    @Published var cliPath: String?

    init() {
        // Recover from an unclean previous exit: if lid-closed mode was armed but
        // never reverted (crash / force-quit), the Mac is stuck never-sleeping —
        // silently clear it now.
        if clamshellGuard.leftOrphaned { clamshellGuard.revertQuietly() }

        // Restore keep-awake across relaunches (notably the app's own self-update).
        defer { syncSleepGuard() }
        guard UserDefaults.standard.bool(forKey: "keepAwake") else { return }
        if keepAwakeHours == 0 {
            keepAwake = true
        } else if let until = UserDefaults.standard.object(forKey: "keepAwakeUntil") as? Date,
                  until > Date() {
            keepAwake = true
            keepAwakeUntil = until
            scheduleKeepAwakeExpiry(at: until)
        } else {
            UserDefaults.standard.set(false, forKey: "keepAwake")
        }
    }

    /// Drive the power assertion from the combined desired state (manual + auto).
    private func syncSleepGuard() {
        if isStayingAwake {
            sleepGuard.start(reason: "AutoAgent: keep Mac awake")
        } else {
            sleepGuard.stop()
        }
    }

    func setAutoAwakeWithWatcher(_ on: Bool) {
        autoAwakeWithWatcher = on
        UserDefaults.standard.set(on, forKey: "autoAwakeWithWatcher")
        syncSleepGuard()
    }

    /// Toggle lid-closed (clamshell) keep-awake. The privileged flip runs off the
    /// main thread so the SwiftUI switch stays responsive during the (first-time)
    /// password prompt; on failure we roll the toggle back and surface the error.
    func setLidClosedAwake(_ on: Bool) {
        guard !lidClosedBusy else { return }
        lidClosedBusy = true
        // Also hold a normal caffeinate guard so display/idle sleep is covered too.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let err = on ? self.clamshellGuard.enable() : self.clamshellGuard.disable()
            DispatchQueue.main.async {
                self.lidClosedBusy = false
                if let err {
                    if err != "cancelled" {
                        self.lastError = "Lid-closed mode: \(err)"
                        notify("Lid-closed mode failed", err, kind: .keepAwake)
                    }
                    self.lidClosedAwake = self.clamshellGuard.active // reflect reality
                    return
                }
                self.lidClosedAwake = on
                if on {
                    notify("Lid-closed mode on",
                           "Your Mac stays running with the lid shut — no external display needed.",
                           kind: .keepAwake)
                }
            }
        }
    }

    /// Called on app quit — always undo the persistent `disablesleep` flag so we
    /// never orphan a never-sleeping Mac.
    func tearDownClamshell() {
        clamshellGuard.revertQuietly()
    }

    func isNotifyOn(_ kind: NotifKind) -> Bool {
        switch kind {
        case .watcher: return notifyWatcher
        case .credential: return notifyCredential
        case .updates: return notifyUpdates
        case .signIn: return notifySignIn
        case .keepAwake: return notifyKeepAwake
        case .figma: return notifyFigma
        }
    }

    func setNotify(_ kind: NotifKind, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: kind.key)
        switch kind {
        case .watcher: notifyWatcher = on
        case .credential: notifyCredential = on
        case .updates: notifyUpdates = on
        case .signIn: notifySignIn = on
        case .keepAwake: notifyKeepAwake = on
        case .figma: notifyFigma = on
        }
    }

    /// Remaining keep-awake time as "1h 05m" / "12m", or nil if off/indefinite.
    var keepAwakeRemaining: String? {
        guard let until = keepAwakeUntil else { return nil }
        let secs = Int(until.timeIntervalSinceNow)
        guard secs > 0 else { return nil }
        let h = secs / 3600, m = (secs % 3600) / 60
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }

    func setKeepAwake(_ on: Bool) {
        keepAwake = on
        UserDefaults.standard.set(on, forKey: "keepAwake")
        if on {
            armKeepAwakeExpiry()
        } else {
            keepAwakeTimer?.cancel(); keepAwakeTimer = nil
            keepAwakeUntil = nil
            UserDefaults.standard.removeObject(forKey: "keepAwakeUntil")
        }
        syncSleepGuard()
    }

    /// Tap a duration chip: remember it, and start keep-awake right away
    /// (or restart the countdown if it's already on).
    func pickKeepAwake(hours: Int) {
        keepAwakeHours = hours
        UserDefaults.standard.set(hours, forKey: "keepAwakeHours")
        if keepAwake {
            armKeepAwakeExpiry() // restart the countdown with the new duration
        } else {
            setKeepAwake(true)   // one-tap start with the chosen duration
        }
    }

    private func armKeepAwakeExpiry() {
        keepAwakeTimer?.cancel(); keepAwakeTimer = nil
        guard keepAwakeHours > 0 else { // 0 = indefinite, until toggled off
            keepAwakeUntil = nil
            UserDefaults.standard.removeObject(forKey: "keepAwakeUntil")
            return
        }
        let until = Date().addingTimeInterval(Double(keepAwakeHours) * 3600)
        keepAwakeUntil = until
        UserDefaults.standard.set(until, forKey: "keepAwakeUntil")
        scheduleKeepAwakeExpiry(at: until)
    }

    private func scheduleKeepAwakeExpiry(at date: Date) {
        keepAwakeTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.keepAwake = false
            self.keepAwakeUntil = nil
            UserDefaults.standard.set(false, forKey: "keepAwake")
            UserDefaults.standard.removeObject(forKey: "keepAwakeUntil")
            self.syncSleepGuard()
            notify("Sleep re-enabled", "Keep-awake finished — your Mac can sleep normally again.", kind: .keepAwake)
        }
        keepAwakeTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, date.timeIntervalSinceNow), execute: item)
    }

    func refresh() {
        workQueue.async {
            let cli = findCLI()
            let s = readStatus()
            DispatchQueue.main.async {
                self.cliPath = cli
                self.apply(s)
            }
        }
        checkVersions()
        refreshUsage()
        refreshPlanUsage()
        refreshFigmaDesktopFlag()
        refreshSessions()
    }

    /// Fetch the AI + Figma sessions this user is assigned to (network only —
    /// no CLI call). Same 5-minute cadence as the other server reads.
    func refreshSessions(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastSessionFetch) > 300 else { return }
        lastSessionFetch = Date()
        let server = status.serverUrl ?? defaultServer
        let sessionId = status.sessionId
        usageQueue.async {
            let ai = fetchAISession(server: server, sessionId: sessionId)
            let figma = fetchFigmaSession(server: server)
            DispatchQueue.main.async {
                if ai != nil || self.status.role != nil { self.aiSession = ai }
                self.figmaSession = figma
            }
        }
    }

    /// Scan today's Claude transcripts (at most every 5 min — it reads files).
    func refreshUsage(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastUsageScan) > 300 else { return }
        lastUsageScan = Date()
        usageQueue.async {
            let report = readUsageReport(days: 7)
            DispatchQueue.main.async {
                self.usage = report.today
                self.usageHistory = report.history
                self.usageTotals = report.totals
                // Report today's usage to the server (same payload + 5-min
                // cadence the CLI uses). Read role/server on main, upload on
                // the background usage queue.
                let role = self.status.role
                let server = self.status.serverUrl ?? defaultServer
                self.usageQueue.async {
                    pushUsageReport(server: server, role: role,
                                    today: report.today, models: report.todayModels)
                }
            }
        }
    }

    /// Fetch the subscription session/weekly usage (at most every 5 min — it's a
    /// network call). Leaves the last good value in place on a transient failure.
    func refreshPlanUsage(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPlanFetch) > 300 else { return }
        lastPlanFetch = Date()
        usageQueue.async {
            guard let plan = fetchPlanUsage() else { return }
            DispatchQueue.main.async { self.planUsage = plan }
        }
    }

    func setAutoUpdateCLI(_ on: Bool) {
        autoUpdateCLI = on
        UserDefaults.standard.set(on, forKey: "autoUpdateCLI")
        if on { checkVersions(force: true) }
    }

    /// Compare installed CLI version with the registry (at most every 6 h unless forced).
    func checkVersions(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastVersionCheck) > 6 * 3600 else { return }
        lastVersionCheck = Date()
        let server = status.serverUrl ?? defaultServer
        workQueue.async {
            let installed = installedCLIVersion()
            // The server's gate is the authority (it knows the *minimum*
            // version and the release notes); npm is the fallback.
            let check = fetchCLIVersionCheck(server: server, installed: installed)
            var latest: String? = check?.latest
            if latest == nil, let npm = npmPath {
                let r = runCommand(npm, ["view", cliPackage, "version"], timeout: 30)
                if r.code == 0,
                   let line = r.output.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces),
                   !line.isEmpty {
                    latest = line
                }
            }
            let appRelease = fetchLatestAppRelease()
            DispatchQueue.main.async {
                self.installedVersion = installed
                self.latestVersion = latest
                if let check {
                    self.cliReleaseNotes = check.notes
                    // Surface the hard block *before* a command fails on it.
                    if check.forceUpdate, !self.cliUpdateRequired {
                        self.cliUpdateRequired = true
                        notify("CLI update required",
                               "auto-agent-ai v\(check.latest) is mandatory — the CLI is blocked until you update.",
                               kind: .updates)
                    } else if !check.forceUpdate, !check.updateAvailable {
                        self.cliUpdateRequired = false
                    }
                }
                if let appRelease {
                    self.appLatestVersion = appRelease.version
                    self.appDownloadURL = appRelease.zipURL
                    if isNewer(appRelease.version, than: appVersion) {
                        notify("App update available",
                               "AutoAgent Status v\(appRelease.version) is available — click Update App in the panel.",
                               kind: .updates)
                    }
                }
                if let latest, let installed, isNewer(latest, than: installed) {
                    if self.autoUpdateCLI, !self.updatingCLI {
                        notify("CLI update", "Auto-updating auto-agent-ai v\(installed) → v\(latest)…", kind: .updates)
                        self.updateCLI()
                    } else {
                        let notes = self.cliReleaseNotes.map { " — \($0)" } ?? ""
                        notify("CLI update available",
                               "auto-agent-ai v\(latest) is available (you have v\(installed))." + notes,
                               kind: .updates)
                    }
                }
            }
        }
    }

    func updateCLI(then completion: (() -> Void)? = nil) {
        guard !updatingCLI else { return }
        guard let npm = npmPath else {
            lastError = "npm not found in /opt/homebrew/bin or /usr/local/bin"
            return
        }
        updatingCLI = true
        lastError = nil
        workQueue.async {
            let r = runCommand(npm, ["install", "-g", "\(cliPackage)@latest"], timeout: 240)
            DispatchQueue.main.async {
                self.updatingCLI = false
                if r.code != 0 {
                    self.lastError = "CLI update failed:\n" + String(stripANSI(r.output).suffix(400))
                } else {
                    self.cliUpdateRequired = false
                    notify("CLI updated", "auto-agent-ai was updated successfully.", kind: .updates)
                    completion?()
                }
                self.checkVersions(force: true)
            }
        }
    }

    private func apply(_ new: AgentStatus) {
        let old = hasStatus ? status : nil
        status = new
        hasStatus = true
        if let role = new.role { savedRole = role }
        if let old { notifyTransitions(old: old, new: new) }
        checkExpiryWarnings(new)
        syncSleepGuard() // watcher may have started/stopped → auto-awake follows
        maybeAutoRestart(new)
    }

    /// Warn once at each threshold (30/15/5 min) before the credential expires.
    private func checkExpiryWarnings(_ s: AgentStatus) {
        guard let exp = s.expiresAt else {
            firedExpiryWarnings.removeAll(); lastExpirySeen = nil; return
        }
        if exp != lastExpirySeen { // new credential / renewed token → fresh cycle
            firedExpiryWarnings.removeAll()
            lastExpirySeen = exp
        }
        guard exp > Date() else { return } // already expired — handled by notifyTransitions
        let minsLeft = exp.timeIntervalSinceNow / 60
        let crossed = expiryThresholds.filter { Double($0) >= minsLeft }
        guard let warn = crossed.min(), !firedExpiryWarnings.contains(warn) else { return }
        firedExpiryWarnings.formUnion(crossed)
        let tail = s.watcherRunning ? " The watcher will try to renew it." : ""
        notify("Token expiring soon", "Your Claude Code token expires in about \(warn) min.\(tail)", kind: .credential)
    }

    private func notifyTransitions(old: AgentStatus, new: AgentStatus) {
        // Don't notify about changes the user just caused (login/logout clicks).
        let userJustActed = Date().timeIntervalSince(lastUserAction) < 20
        if old.watcherRunning && !new.watcherRunning && !userJustActed {
            notify("Watcher stopped", "The auto-agent watcher is no longer running.", kind: .watcher)
        }
        if old.credentialPresent && !new.credentialPresent && !userJustActed {
            notify("Credential removed", "The Claude Code credential was wiped from your Keychain.", kind: .credential)
        }
        if old.credentialValid && !new.credentialValid && new.credentialPresent && !new.watcherRunning {
            notify("Token expired", "The token expired and no watcher is running to renew it.", kind: .credential)
        }
        if old.state != .active && new.state == .active {
            notify("AutoAgent active", "Credential synced and watcher running.", kind: .credential)
        }
    }

    /// Self-healing: if the watcher died but we know the last role, log in again.
    private func maybeAutoRestart(_ s: AgentStatus) {
        guard autoRestart, busy == nil, !s.watcherRunning else { return }
        guard let role = s.role ?? savedRole else { return }
        guard Date().timeIntervalSince(lastUserAction) > 20 else { return }
        guard Date().timeIntervalSince(lastAutoRestartAt) > 300 else { return } // retry at most every 5 min
        lastAutoRestartAt = Date()
        var args = ["login", "--role", role]
        if role == "owner" {
            // Primary-user login is token-based; without one the CLI would sit
            // at a prompt our stdin-less subprocess can never answer.
            guard let token = handshakeToken else { return }
            args += ["--token", token]
        }
        runCLI("auto-restart (\(role))", args, isAutoRestart: true)
    }

    func setAutoRestart(_ on: Bool) {
        autoRestart = on
        UserDefaults.standard.set(on, forKey: "autoRestart")
    }

    func login(role: String) {
        savedRole = role
        var args = ["login", "--role", role]
        // The primary user signs in with the session handshake token instead of
        // the Microsoft browser flow — pass it so the CLI never has to prompt
        // (our subprocess has no stdin, so a prompt would just hang).
        if role == "owner" {
            guard let token = handshakeToken else {
                lastError = "Signing in as primary user needs the session handshake token — "
                    + "paste it in the Figma tab (Primary User) first."
                return
            }
            args += ["--token", token]
        }
        runCLI("login (\(role))", args, interactive: role != "owner")
    }

    /// Log in with whatever role this machine last used (client unless the CLI
    /// state says primary user) — what the single Login button does.
    func loginWithSavedRole() { login(role: status.role ?? savedRole ?? "client") }

    /// Owner only: push this Mac's credential to the session.
    func push() { runCLI("push", ["push"]) }
    func logout() {
        savedRole = nil // user chose to leave — disable auto-restart until next login
        runCLI("logout", ["logout"])
    }

    // MARK: Figma session

    /// Re-read the Figma accounts signed in on this Mac. Throttled — the CLI
    /// call decrypts cookies through the Keychain, so we don't poll it blindly;
    /// it runs when the Figma tab is opened, after an action, or on refresh.
    func refreshFigma(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastFigmaScan) > 60 else { return }
        guard figmaBusy == nil else { return }
        lastFigmaScan = Date()
        figmaQueue.async {
            let state = readFigmaState()
            DispatchQueue.main.async { self.figma = state }
        }
    }

    /// Cheap poll (no CLI call): just whether Figma Desktop is up right now.
    func refreshFigmaDesktopFlag() {
        figmaQueue.async {
            let running = figmaDesktopRunning()
            DispatchQueue.main.async {
                if self.figma.desktopRunning != running { self.figma.desktopRunning = running }
            }
        }
    }

    func setFigmaToken(_ token: String) {
        figmaToken = token
        UserDefaults.standard.set(token, forKey: "figmaToken")
    }

    /// Pull the shared Figma login and write it into Figma Desktop.
    /// Figma must be quit while cookies are written, so we quit it, import,
    /// and (if we quit it) launch it again so it comes back signed in.
    func figmaImport() {
        runFigma("import", ["figma", "import"], needsFigmaQuit: true, relaunchFigma: true)
    }

    /// Owner/primary user: share this Mac's Figma login with the team.
    func figmaUpload() {
        var args = ["figma", "upload"]
        if let id = figma.activeAccount?.id { args += ["--account", id] }
        guard let token = handshakeToken else {
            figmaError = "Uploading needs the session handshake token — paste it above first."
            return
        }
        args += ["--token", token]
        runFigma("upload", args, needsFigmaQuit: true, relaunchFigma: true)
    }

    /// Owner/primary user: delete the shared login from the server.
    func figmaRevoke() {
        guard let token = handshakeToken else {
            figmaError = "Revoking needs the session handshake token — paste it above first."
            return
        }
        runFigma("revoke", ["figma", "revoke", "--token", token])
    }

    /// Sign this Mac out of every shared Figma account (local only).
    func figmaClearAll() {
        runFigma("sign out", ["figma", "clear", "--all"], needsFigmaQuit: true)
    }

    /// Sign one account out (the CLI's `figma clear --account`, which it
    /// otherwise asks for interactively — we always pass the id).
    func figmaClear(account: FigmaAccount) {
        runFigma("sign out", ["figma", "clear", "--account", account.id], needsFigmaQuit: true)
    }

    func openFigmaDesktop() {
        let url = URL(fileURLWithPath: figmaAppPath)
        guard FileManager.default.fileExists(atPath: figmaAppPath) else {
            figmaError = "Figma Desktop isn't installed in /Applications."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refreshFigmaDesktopFlag() }
        }
    }

    func quitFigmaDesktopNow() {
        figmaQueue.async {
            _ = quitFigmaDesktop()
            DispatchQueue.main.async { self.refreshFigmaDesktopFlag() }
        }
    }

    private func runFigma(_ name: String, _ args: [String],
                          needsFigmaQuit: Bool = false, relaunchFigma: Bool = false) {
        guard figmaBusy == nil, busy == nil else { return }
        guard let cli = cliPath ?? findCLI() else {
            figmaError = "auto-agent-ai CLI not found. Install it: npm install -g \(cliPackage)"
            return
        }
        figmaBusy = name
        figmaError = nil
        figmaQueue.async {
            // The CLI can't touch the cookie DB while Figma Desktop is open.
            var quitIt = false
            if needsFigmaQuit && figmaDesktopRunning() {
                quitIt = quitFigmaDesktop()
                if !quitIt {
                    DispatchQueue.main.async {
                        self.figmaBusy = nil
                        self.figmaError = "Figma Desktop wouldn't quit — quit it manually, then try again."
                    }
                    return
                }
            }
            let result = runCommand(cli, args, timeout: 180)
            if relaunchFigma && quitIt && result.code == 0 {
                let url = URL(fileURLWithPath: figmaAppPath)
                if FileManager.default.fileExists(atPath: figmaAppPath) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(),
                                                       completionHandler: { _, _ in })
                }
            }
            let state = readFigmaState()
            DispatchQueue.main.async {
                self.figmaBusy = nil
                self.figma = state
                self.lastFigmaScan = Date()
                self.refreshSessions(force: true) // upload/revoke change hasSession
                let text = stripANSI(result.output)
                if result.code != 0 {
                    if isUpdateRequired(text) { self.cliUpdateRequired = true }
                    let tail = text.split(separator: "\n").map(String.init)
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .suffix(3).map(stripLogTimestamp).joined(separator: "\n")
                    self.figmaError = "Figma \(name) failed:\n" + (tail.isEmpty ? "exit \(result.code)" : tail)
                    return
                }
                let who = state.activeAccount?.email
                switch name {
                case "import":
                    notify("Figma signed in",
                           who.map { "Figma Desktop is signed in as \($0)." }
                            ?? "The shared Figma login was imported.", kind: .figma)
                case "upload":
                    notify("Figma session shared", "Your Figma login was uploaded for the team.", kind: .figma)
                case "revoke":
                    notify("Figma session revoked", "The shared Figma login was deleted from the server.", kind: .figma)
                case "sign out":
                    notify("Figma signed out", "This Mac was signed out of the shared Figma account.", kind: .figma)
                default: break
                }
            }
        }
    }

    private func runCLI(_ name: String, _ args: [String],
                        isAutoRestart: Bool = false, isRetry: Bool = false, interactive: Bool = false) {
        guard busy == nil else { return }
        guard let cli = cliPath ?? findCLI() else {
            lastError = "auto-agent-ai CLI not found. Install it: npm install -g \(cliPackage)"
            return
        }
        busy = name
        lastError = nil
        loginURL = nil
        lastUserAction = Date()
        // Interactive sign-in waits on the browser callback, so give it room.
        let timeout: TimeInterval = interactive ? 180 : 90
        // For interactive logins, block the CLI's automatic browser launch (it
        // pops a loading icon in the Dock); the user opens the sign-in page from
        // the in-app banner instead.
        let extraPATH = interactive ? [noOpenShimDir()].compactMap { $0 } : []
        workQueue.async {
            var sawURL = false
            var abortedForAuth = false
            let result = runCommand(cli, args, timeout: timeout, extraPATH: extraPATH) { text in
                // Only logins surface a sign-in URL; ignore everything else.
                guard interactive || isAutoRestart, !sawURL, let url = extractLoginURL(text) else { return false }
                sawURL = true
                if isAutoRestart {
                    // Can't complete an interactive sign-in unattended — bail and ask the user.
                    abortedForAuth = true
                    DispatchQueue.main.async {
                        notify("Sign-in required",
                               "The watcher needs you to sign in again — open AutoAgent and click Owner or Client Login.",
                               kind: .signIn)
                    }
                    return true // abort the hung process
                }
                DispatchQueue.main.async {
                    self.loginURL = url
                    notify("Finish signing in",
                           "Complete the Microsoft sign-in in your browser to finish logging in.",
                           kind: .signIn)
                }
                return false // keep waiting for the browser callback
            }
            let fresh = readStatus()
            DispatchQueue.main.async {
                self.busy = nil
                self.loginURL = nil
                self.lastUserAction = Date()
                self.apply(fresh)
                if abortedForAuth { return } // user was already notified; no error banner
                if result.code != 0 {
                    if isUpdateRequired(result.output) {
                        self.cliUpdateRequired = true
                        // Auto-update once, then retry the original command.
                        if self.autoUpdateCLI, !isRetry, !self.updatingCLI {
                            notify("CLI update required",
                                   "auto-agent-ai must be updated before it can run — updating now…",
                                   kind: .updates)
                            self.updateCLI {
                                self.runCLI(name, args, isAutoRestart: isAutoRestart,
                                            isRetry: true, interactive: interactive)
                            }
                        } else {
                            self.lastError = "auto-agent-ai requires an update before it can run. "
                                + "Click \u{201C}Update CLI now\u{201D} above."
                        }
                        return
                    }
                    self.lastError = "\(name) failed (exit \(result.code)):\n"
                        + String(stripANSI(result.output).suffix(400))
                } else {
                    self.cliUpdateRequired = false
                    if isAutoRestart {
                        notify("Watcher restarted", "Watcher was down — logged in again automatically.", kind: .watcher)
                    }
                }
                // login spawns a detached watcher that writes state shortly after
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh() }
            }
        }
    }

    /// Download the latest release zip, replace this app, and relaunch.
    func updateApp() {
        guard !updatingApp else { return }
        guard let dl = appDownloadURL else {
            lastError = "No release found yet — click Refresh first."
            return
        }
        updatingApp = true
        lastError = nil
        let auth = updateToken.map { "-H 'Authorization: Bearer \($0)'" } ?? ""
        let script = """
        set -e
        TMP=$(mktemp -d)
        /usr/bin/curl -fsSL -H 'Accept: application/octet-stream' \(auth) -o "$TMP/app.zip" '\(dl)'
        /usr/bin/ditto -x -k "$TMP/app.zip" "$TMP/x"
        SRC=$(/usr/bin/find "$TMP/x" -maxdepth 4 -name "AutoAgent Status.app" | head -1)
        test -n "$SRC"
        rm -rf '\(installedAppPath)'
        /usr/bin/ditto "$SRC" '\(installedAppPath)'
        /usr/bin/xattr -dr com.apple.quarantine '\(installedAppPath)' 2>/dev/null || true
        rm -rf "$TMP"
        """
        workQueue.async {
            let r = runCommand("/bin/bash", ["-c", script], timeout: 300)
            DispatchQueue.main.async {
                self.updatingApp = false
                if r.code != 0 {
                    self.lastError = "App update failed:\n" + String(stripANSI(r.output).suffix(400))
                    return
                }
                notify("App updated", "Restarting AutoAgent Status…", kind: .updates)
                let relauncher = Process()
                relauncher.executableURL = URL(fileURLWithPath: "/bin/bash")
                relauncher.arguments = ["-c", "sleep 1; /usr/bin/open '\(installedAppPath)'"]
                try? relauncher.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = "Start at Login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openLog() {
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        } else {
            lastError = "No log yet — log in first to start the watcher."
        }
    }
}

// MARK: - UI components

struct InfoRow: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = .primary
    var help: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.callout.weight(.medium))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(help ?? value)
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.callout.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(hovering ? 0.25 : 0.14))
            )
            .foregroundStyle(disabled ? Color.secondary : color)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Main view

struct ContentView: View {
    @ObservedObject var store: StatusStore
    @State private var confirmLogout = false
    @State private var confirmFigmaClear = false
    @State private var switchingToken = false
    @State private var tab: Tab = .status
    @State private var notifExpanded = false

    enum Tab: Hashable { case status, figma, system, settings }

    private static let relFormatter = RelativeDateTimeFormatter()
    private static let absFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private var s: AgentStatus { store.status }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker
            banners
            Group {
                switch tab {
                case .status: statusTab
                case .figma: figmaTab
                case .system: systemTab
                case .settings: settingsTab
                }
            }
            Divider()
            bottomBar
        }
        .frame(width: 340)
        .confirmationDialog(
            "Log out of AutoAgent?",
            isPresented: $confirmLogout,
            titleVisibility: .visible
        ) {
            Button("Logout", role: .destructive) { store.logout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops the watcher and removes the Claude Code credential from your Keychain.")
        }
    }

    private var tabPicker: some View {
        TabSwitcher(selection: $tab, tint: s.color)
            .padding(.horizontal, 12)
            .padding(.top, 10)
    }

    /// Important banners stay visible on both tabs.
    @ViewBuilder private var banners: some View {
        if store.cliUpdateRequired || store.loginURL != nil || store.lastError != nil {
            VStack(spacing: 8) {
                if store.cliUpdateRequired { updateRequiredBanner }
                if let url = store.loginURL { loginBanner(url) }
                if let err = store.lastError { errorBanner(err) }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
    }

    private var statusTab: some View {
        VStack(spacing: 8) {
            credentialCard
            planCard
            usageCard
            actionsSection
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Figma session sharing: which account this Mac is signed into, and the
    /// one-tap import that pulls the team's shared Figma login.
    private var figmaTab: some View {
        VStack(spacing: 8) {
            figmaSharedCard
            figmaAccountsCard
            figmaActionsCard
            if s.isOwner { figmaOwnerCard }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear {
            store.refreshFigma()
            store.refreshSessions()
        }
        .confirmationDialog(
            "Sign out of the shared Figma account?",
            isPresented: $confirmFigmaClear,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) { store.figmaClearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only removes the login from this Mac — Figma Desktop will be quit first.")
        }
    }

    /// What the server has: the Figma session you're assigned to, and whether a
    /// login has actually been uploaded to it yet.
    private var figmaSharedCard: some View {
        Card(title: "Shared Figma Session", icon: "person.2.badge.key.fill") {
            if let ses = store.figmaSession {
                InfoRow(icon: "rectangle.stack.fill", label: "Session",
                        value: ses.memberCount > 0 ? "\(ses.name) · \(ses.memberCount) members" : ses.name,
                        valueColor: ses.isActive ? .primary : .orange)
                InfoRow(icon: ses.hasSession ? "checkmark.seal.fill" : "clock.badge.questionmark",
                        label: "Shared login",
                        value: ses.hasSession ? (ses.sharedLabel ?? "Available") : "Not uploaded yet",
                        valueColor: ses.hasSession ? .green : .orange,
                        help: ses.hasSession
                            ? "\(ses.cookieCount) cookies uploaded" + (ses.capturedAt.map { " · captured " + Self.absFormatter.string(from: $0) } ?? "")
                            : "The primary user hasn't uploaded their Figma login to this session yet.")
                if ses.hasSession, let at = ses.capturedAt {
                    InfoRow(icon: "clock.arrow.circlepath", label: "Captured",
                            value: Self.relFormatter.localizedString(for: at, relativeTo: Date()),
                            valueColor: .secondary)
                }
            } else {
                Text(store.status.role == nil
                     ? "Log in first — the shared Figma session is read from the server."
                     : "You're not assigned to a Figma session yet. Ask the session owner to add you.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var figmaAccountsCard: some View {
        Card(title: "Figma Account", icon: "person.crop.square.filled.and.at.rectangle") {
            if let problem = store.figma.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if store.figma.accounts.isEmpty {
                InfoRow(icon: "person.slash", label: "Signed in",
                        value: store.figma.checked ? "No account" : "Checking…",
                        valueColor: store.figma.checked ? .secondary : .secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(store.figma.accounts) { acct in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: acct.active ? "checkmark.seal.fill" : "person.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(acct.active ? Color.green : .secondary)
                                .frame(width: 16)
                            Text(acct.email)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(acct.email)
                            Spacer(minLength: 8)
                            if let kind = acct.planKind {
                                Text(kind.capitalized)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.quaternary.opacity(0.7), in: Capsule())
                            }
                            // With several accounts signed in, allow signing out
                            // just one — the CLI's `figma clear --account`.
                            if store.figma.accounts.count > 1, store.figmaBusy == nil {
                                Button { store.figmaClear(account: acct) } label: {
                                    Image(systemName: "person.badge.minus")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Sign \(acct.email) out of Figma Desktop")
                            }
                        }
                    }
                }
            }
            InfoRow(icon: "macwindow", label: "Figma Desktop",
                    value: store.figma.desktopRunning ? "Running" : "Not running",
                    valueColor: store.figma.desktopRunning ? .orange : .secondary,
                    help: store.figma.desktopRunning
                        ? "Figma must be quit while the shared login is written — the app quits and reopens it for you."
                        : "Ready to import the shared login.")
        }
    }

    private var figmaActionsCard: some View {
        Card(title: "Shared Session", icon: "arrow.down.circle") {
            if let busy = store.figmaBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(figmaBusyText(busy))
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                Text(figmaHint)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Two primary actions only — refresh lives in the footer, and
                // signing out is the rare, destructive one (small link below).
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    // Mirrors the CLI: importing is only offered once a login
                    // has actually been uploaded to your assigned session.
                    ActionButton(title: "Import login", icon: "square.and.arrow.down.fill", color: .purple,
                                 disabled: store.cliPath == nil || !store.canImportFigma) { store.figmaImport() }
                    ActionButton(title: "Open Figma", icon: "paintpalette.fill", color: .blue) {
                        store.openFigmaDesktop()
                    }
                }
                if !store.figma.accounts.isEmpty {
                    Button("Sign out of Figma on this Mac") { confirmFigmaClear = true }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.85))
                        .padding(.top, 1)
                }
            }
            if let err = store.figmaError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.red)
                    Text(err)
                        .font(.caption2).lineLimit(4).help(err)
                    Spacer(minLength: 2)
                    Button { store.figmaError = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
    }

    /// Primary-user (owner) side: publish or revoke the shared login. Both need
    /// the per-session handshake token from the web dashboard.
    private var figmaOwnerCard: some View {
        Card(title: "Primary User", icon: "person.badge.key.fill") {
            if s.handshakeToken != nil && !switchingToken {
                HStack(spacing: 6) {
                    Text("Using the session token from your CLI login.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    // The CLI's "Switch session token" menu entry.
                    Button("Switch") { switchingToken = true }
                        .buttonStyle(.plain)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            } else {
                SecureField("Handshake token", text: Binding(
                    get: { store.figmaToken },
                    set: { store.setFigmaToken($0) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ActionButton(title: "Share login", icon: "square.and.arrow.up.fill", color: .teal,
                             disabled: store.figmaBusy != nil || store.figma.accounts.isEmpty
                                       || store.handshakeToken == nil) {
                    store.figmaUpload()
                }
                ActionButton(title: "Revoke", icon: "trash.fill", color: .orange,
                             disabled: store.figmaBusy != nil || store.handshakeToken == nil
                                       || store.figmaSession?.hasSession != true) { store.figmaRevoke() }
            }
        }
    }

    private var figmaHint: String {
        guard let ses = store.figmaSession else {
            return "No Figma session is assigned to you, so there's nothing to import yet."
        }
        if !ses.hasSession {
            return "\(ses.name) has no login uploaded yet — the primary user has to share theirs first."
        }
        if let local = store.figma.activeAccount?.email, local == ses.accounts.first?.email {
            return "This Mac is already signed in as \(local). Import again to refresh the cookies."
        }
        return "Pull \(ses.sharedLabel ?? ses.name) into Figma Desktop on this Mac."
    }

    private func figmaBusyText(_ busy: String) -> String {
        switch busy {
        case "import": return "Importing the shared login… Figma will reopen signed in."
        case "upload": return "Sharing this Mac's Figma login…"
        case "revoke": return "Revoking the shared login…"
        default: return "Signing out of Figma…"
        }
    }

    private var systemTab: some View {
        VStack(spacing: 8) {
            watcherCard
            healthCard
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var settingsTab: some View {
        VStack(spacing: 4) {
            KeepAwakeRow(store: store)
            LidClosedRow(store: store)
            SettingToggle(
                icon: "eye.fill", tint: .indigo,
                title: "Auto-awake with watcher",
                subtitle: "Stay awake while the watcher runs",
                isOn: Binding(get: { store.autoAwakeWithWatcher },
                              set: { store.setAutoAwakeWithWatcher($0) }))
            SettingToggle(
                icon: "arrow.triangle.2.circlepath", tint: .green,
                title: "Auto-restart watcher",
                subtitle: "Log back in if the watcher dies",
                isOn: Binding(get: { store.autoRestart }, set: { store.setAutoRestart($0) }))
            SettingToggle(
                icon: "arrow.down.circle.fill", tint: .orange,
                title: "Auto-update CLI",
                subtitle: "Install new auto-agent-ai versions",
                isOn: Binding(get: { store.autoUpdateCLI }, set: { store.setAutoUpdateCLI($0) }))
            SettingToggle(
                icon: "powerplug.fill", tint: .blue,
                title: "Start at Login",
                subtitle: "Launch automatically on sign-in",
                isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
            notificationsSection
            AboutSection(store: store)
                .padding(.top, 4)
        }
        .padding(12)
    }

    private var notificationsSection: some View {
        VStack(spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { notifExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.pink)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.pink.opacity(0.16)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Notifications").font(.callout.weight(.medium))
                        Text("Choose which alerts to show").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(notifExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if notifExpanded {
                VStack(spacing: 2) {
                    ForEach(NotifKind.allCases, id: \.self) { kind in
                        notifRow(kind)
                    }
                }
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func notifRow(_ kind: NotifKind) -> some View {
        HStack(spacing: 9) {
            Image(systemName: kind.icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(kind.title).font(.callout)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { store.isNotifyOn(kind) },
                                     set: { store.setNotify(kind, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.pink)
        }
        .padding(.leading, 4)
        .padding(.vertical, 1)
    }

    /// Global controls, pinned below both tabs.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            footerButton("arrow.clockwise", help: "Refresh status & check for updates") {
                store.refresh()
                store.checkVersions(force: true)
                store.refreshUsage(force: true)
                store.refreshPlanUsage(force: true)
                store.refreshSessions(force: true)
                if tab == .figma { store.refreshFigma(force: true) }
            }
            footerButton("doc.text", help: "Open watch log") { store.openLog() }
            Spacer()
            footerButton("power", help: "Quit AutoAgent Status") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [s.color, s.color.opacity(0.55)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 42, height: 42)
                    .shadow(color: s.color.opacity(0.35), radius: 6, y: 2)
                Image(systemName: "key.radiowaves.forward.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("AutoAgent")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    Text("v" + appVersion)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                Text(s.headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if store.busy != nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                HStack(spacing: 5) {
                    Circle().fill(s.color).frame(width: 7, height: 7)
                    Text(s.stateLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(s.color)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(s.color.opacity(0.13), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(s.color.opacity(0.07))
    }

    // MARK: Cards

    private var roleText: String {
        guard let role = s.role else { return "Not logged in" }
        let who = s.username.map { " · \($0)" } ?? ""
        return role.capitalized + who
    }

    private var expiry: (text: String, color: Color) {
        guard let exp = s.expiresAt else {
            return (s.credentialPresent ? "Unknown" : "No credential", .secondary)
        }
        let rel = Self.relFormatter.localizedString(for: exp, relativeTo: Date())
        let abs = Self.absFormatter.string(from: exp)
        if exp <= Date() { return ("Expired \(rel)", .red) }
        if exp.timeIntervalSinceNow < 3600 { return ("\(rel) · \(abs)", .orange) }
        return ("\(rel) · \(abs)", .primary)
    }

    private var credentialCard: some View {
        Card(title: "Credential", icon: "person.badge.key.fill") {
            InfoRow(icon: "person.fill", label: "Role", value: roleText)
            InfoRow(icon: "clock.fill", label: "Token", value: expiry.text, valueColor: expiry.color)
            if let ses = store.aiSession {
                InfoRow(icon: "rectangle.stack.fill", label: "Session",
                        value: ses.members.count > 1 ? "\(ses.name) · \(ses.members.count) members" : ses.name,
                        valueColor: ses.isActive ? .primary : .orange,
                        help: ses.members.isEmpty
                            ? ses.name
                            : "\(ses.name) — shared with: " + ses.members.joined(separator: ", "))
            }
        }
    }

    private var serverHealth: (text: String, color: Color) {
        let host = (s.serverUrl ?? defaultServer).replacingOccurrences(of: "https://", with: "")
        switch s.serverOK {
        case .some(true): return ("\(host) · \(s.serverLatencyMs ?? 0) ms", .green)
        case .some(false): return ("\(host) · unreachable", .red)
        case .none: return (host, .secondary)
        }
    }

    private var cliVersion: (text: String, color: Color) {
        guard let inst = store.installedVersion else { return ("not found", .red) }
        if let latest = store.latestVersion, isNewer(latest, than: inst) {
            return ("v\(inst) → v\(latest)", .orange)
        }
        return (store.latestVersion != nil ? "v\(inst) · up to date" : "v\(inst)", .primary)
    }

    private var updateAvailable: Bool {
        guard let inst = store.installedVersion, let latest = store.latestVersion else { return false }
        return isNewer(latest, than: inst)
    }

    private func usageCell(_ label: String, _ value: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(formatTokens(value))
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            Spacer(minLength: 0)
        }
    }

    /// "Resets 12:50pm" today, otherwise "Resets Jun 24, 10pm" — local time.
    private func resetText(_ date: Date?) -> String {
        guard let date else { return "" }
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date) {
            f.dateFormat = "h:mma"
        } else {
            f.dateFormat = "MMM d, h:mma"
        }
        return "Resets " + f.string(from: date).lowercased()
    }

    private func planRow(_ limit: PlanLimit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(limit.label)
                    .font(.caption).foregroundStyle(.secondary)
                if !resetText(limit.resetsAt).isEmpty {
                    Text("· " + resetText(limit.resetsAt))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).layoutPriority(-1)
                }
                Spacer(minLength: 8)
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(limit.color)
            }
            ProgressView(value: min(max(limit.percent, 0), 100), total: 100)
                .progressViewStyle(.linear)
                .tint(limit.color)
        }
    }

    private var planCard: some View {
        Card(title: "Plan Usage", icon: "gauge.with.dots.needle.50percent") {
            if let plan = store.planUsage, !plan.limits.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(plan.limits) { planRow($0) }
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading plan limits…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var usageCard: some View {
        Card(title: "Usage Today", icon: "chart.bar.fill") {
            if let u = store.usage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "sum")
                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                    Text("Today").font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(formatTokens(u.billable))
                        .font(.callout.weight(.semibold)).foregroundStyle(.blue)
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                    Text(formatUSD(u.costUSD))
                        .font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(.green)
                }
                .help("Billable \(u.billable) tokens · est. cost priced per model (Opus/Sonnet/Haiku), approximate")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    usageCell("Input", u.input, icon: "arrow.down", color: .teal)
                    usageCell("Output", u.output, icon: "arrow.up", color: .blue)
                    usageCell("Cache create", u.cacheCreate, icon: "plus.square.on.square", color: .purple)
                    usageCell("Cache read", u.cacheRead, icon: "bolt.fill", color: .orange)
                }
                if store.usageHistory.contains(where: { $0.costUSD > 0 }) {
                    sevenDayChart
                }
                if let t = store.usageTotals {
                    periodTotals(t)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Scanning transcripts…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sevenDayChart: some View {
        let week = store.usageHistory
        let weekCost = week.reduce(0) { $0 + $1.costUSD }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Last 7 days")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(formatUSD(weekCost))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.green)
            }
            UsageBars(data: week, tint: .green)
        }
        .padding(.top, 2)
    }

    private func periodTotalRow(_ label: String, billable: Int, cost: Double) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(formatTokens(billable))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
            Text(formatUSD(cost))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.green)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }

    private func periodTotals(_ t: PeriodTotals) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.vertical, 1)
            periodTotalRow("This month", billable: t.monthBillable, cost: t.monthCost)
            periodTotalRow("All-time", billable: t.allBillable, cost: t.allCost)
        }
        .padding(.top, 2)
    }

    private var appVersionInfo: (text: String, color: Color) {
        if let latest = store.appLatestVersion, isNewer(latest, than: appVersion) {
            return ("v\(appVersion) → v\(latest)", .orange)
        }
        return (store.appLatestVersion != nil ? "v\(appVersion) · up to date" : "v\(appVersion)", .primary)
    }

    private var appUpdateAvailable: Bool {
        guard let latest = store.appLatestVersion else { return false }
        return isNewer(latest, than: appVersion)
    }

    private var healthCard: some View {
        Card(title: "Health", icon: "stethoscope") {
            InfoRow(icon: "network", label: "Server", value: serverHealth.text, valueColor: serverHealth.color)
            InfoRow(icon: "terminal.fill", label: "CLI", value: cliVersion.text, valueColor: cliVersion.color)
            InfoRow(icon: "macwindow", label: "App", value: appVersionInfo.text, valueColor: appVersionInfo.color)
            if store.updatingCLI {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Updating CLI…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if updateAvailable, let latest = store.latestVersion {
                if let notes = store.cliReleaseNotes {
                    Text(notes)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(3).help(notes)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ActionButton(title: "Update CLI to v\(latest)", icon: "arrow.down.circle.fill",
                             color: .orange) { store.updateCLI() }
            }
            if store.updatingApp {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Updating app… it will restart by itself")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if appUpdateAvailable, let latest = store.appLatestVersion {
                ActionButton(title: "Update App to v\(latest)", icon: "sparkles",
                             color: .blue) { store.updateApp() }
            }
        }
    }

    private var watcherCard: some View {
        Card(title: "Watcher", icon: "eye.fill") {
            InfoRow(
                icon: s.watcherRunning ? "checkmark.circle.fill" : "xmark.circle.fill",
                label: "Status",
                value: s.watcherRunning ? "Running · pid \(s.watcherPid ?? 0)" : "Stopped",
                valueColor: s.watcherRunning ? .green : .red
            )
            if let log = s.lastLogLine {
                Text(log)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(log)
            }
        }
    }

    // MARK: Actions

    private var actionsSection: some View {
        Group {
            if let busy = store.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Running \(busy)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ActionButton(title: "Login", icon: "person.fill", color: .teal,
                                 disabled: store.cliPath == nil) { store.loginWithSavedRole() }
                    ActionButton(title: "Logout", icon: "rectangle.portrait.and.arrow.right", color: .red,
                                 disabled: store.cliPath == nil) { confirmLogout = true }
                    // Primary user only — the CLI's "Push" menu entry: send this
                    // Mac's credential up so the assigned clients pull it.
                    if s.isOwner {
                        ActionButton(title: "Push credential", icon: "arrow.up.circle.fill", color: .indigo,
                                     disabled: store.cliPath == nil) { store.push() }
                    }
                }
            }
        }
    }

    private var updateRequiredBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("CLI update required")
                    .font(.callout.weight(.semibold))
            }
            Text("auto-agent-ai is blocked until it's updated — login, push, Figma and the watcher won't work until you update.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notes = store.cliReleaseNotes {
                Text(notes)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(4).help(notes)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.updatingCLI {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Updating CLI…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ActionButton(title: "Update CLI now", icon: "arrow.down.circle.fill",
                             color: .orange) { store.updateCLI() }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func loginBanner(_ url: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.shield.checkmark.fill")
                    .foregroundStyle(.blue)
                Text("Finish signing in")
                    .font(.callout.weight(.semibold))
            }
            Text("Tap “Open sign-in page” to finish the Microsoft sign-in in your browser.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ActionButton(title: "Open sign-in page", icon: "safari.fill", color: .blue) {
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                }
                ActionButton(title: "Copy link", icon: "doc.on.doc.fill", color: .gray) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(4)
                .help(message)
            Spacer(minLength: 4)
            Button {
                store.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Footer

    private func footerButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 24)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Keep-awake settings row: icon, title + live countdown, a switch, and a
/// row of one-tap duration chips (2h / 4h / … / ∞) that start it immediately.
struct KeepAwakeRow: View {
    @ObservedObject var store: StatusStore
    private let tint = Color.purple

    private var subtitle: String {
        if store.keepAwake {
            if let left = store.keepAwakeRemaining { return "Awake · \(left) left" }
            return "Awake · until you turn it off"
        }
        return "Tap a time to keep your Mac awake"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: store.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(store.keepAwake ? Color.white : tint)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tint.opacity(store.keepAwake ? 0.95 : 0.16))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep Mac awake")
                        .font(.callout.weight(.medium))
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(store.keepAwake ? tint : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { store.keepAwake }, set: { store.setKeepAwake($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(tint)
            }

            // One-tap duration chips — big, obvious targets.
            HStack(spacing: 5) {
                ForEach(store.keepAwakeOptions, id: \.self) { h in
                    chip(label: "\(h)h", selected: store.keepAwake && store.keepAwakeHours == h) {
                        store.pickKeepAwake(hours: h)
                    }
                }
                chip(label: "∞", selected: store.keepAwake && store.keepAwakeHours == 0) {
                    store.pickKeepAwake(hours: 0)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(store.keepAwake ? 0.06 : 0))
        )
    }

    private func chip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(selected ? Color.white : tint)
                .frame(maxWidth: .infinity, minHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(selected ? 1.0 : 0.13))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(label == "∞" ? "Stay awake until turned off" : "Stay awake for \(label)")
    }
}

/// Lid-closed (clamshell) keep-awake toggle. Flips pmset `disablesleep` so the
/// Mac keeps running with the lid shut — no external display required. Shows a
/// spinner while the (first-time) admin prompt is up.
struct LidClosedRow: View {
    @ObservedObject var store: StatusStore
    private let tint = Color.teal
    @State private var hovering = false

    private var subtitle: String {
        if store.lidClosedBusy { return "Authorizing…" }
        if store.lidClosedAwake { return "Lid can be closed — no monitor needed" }
        return "Run with the lid shut (asks for password once)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: store.lidClosedAwake ? "laptopcomputer.slash" : "laptopcomputer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(store.lidClosedAwake ? Color.white : tint)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(store.lidClosedAwake ? 0.95 : 0.16))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Keep awake with lid closed")
                    .font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(store.lidClosedAwake ? tint : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if store.lidClosedBusy {
                ProgressView().controlSize(.small)
            } else {
                Toggle("", isOn: Binding(get: { store.lidClosedAwake },
                                         set: { store.setLidClosedAwake($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(tint)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(store.lidClosedAwake ? AnyShapeStyle(tint.opacity(0.06)) : AnyShapeStyle(.quaternary.opacity(hovering ? 0.45 : 0)))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Uses pmset disablesleep (like Amphetamine). Reverted automatically when you quit.")
    }
}

/// A compact 7-bar daily cost chart; the last bar (today) is highlighted.
struct UsageBars: View {
    let data: [DayUsage]
    var tint: Color

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()

    var body: some View {
        let maxV = max(data.map(\.costUSD).max() ?? 0, 0.0001)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(data.enumerated()), id: \.offset) { i, d in
                let isToday = i == data.count - 1
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(tint.opacity(isToday ? 1.0 : 0.4))
                    .frame(height: max(3, CGFloat(d.costUSD / maxV) * 34))
                    .frame(maxWidth: .infinity)
                    .help("\(Self.dayFmt.string(from: d.date)): \(formatUSD(d.costUSD))")
            }
        }
        .frame(height: 34)
    }
}

/// A pill-style two-tab switcher with an animated sliding highlight that
/// adopts the current status color.
struct TabSwitcher: View {
    @Binding var selection: ContentView.Tab
    var tint: Color
    @Namespace private var ns

    private let tabs: [(tab: ContentView.Tab, icon: String, label: String)] = [
        (.status, "key.fill", "Status"),
        (.figma, "paintpalette.fill", "Figma"),
        (.system, "server.rack", "System"),
        (.settings, "slider.horizontal.3", "Settings"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.tab) { item in
                segment(item.tab, item.icon, item.label)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func segment(_ tab: ContentView.Tab, _ icon: String, _ label: String) -> some View {
        let selected = selection == tab
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { selection = tab }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : Color.secondary)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.72)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: tint.opacity(0.35), radius: 4, y: 1)
                        .matchedGeometryEffect(id: "tabPill", in: ns)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A polished settings row: tinted icon tile, title + subtitle, and a switch.
struct SettingToggle: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : tint)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(isOn ? 0.95 : 0.16))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.quaternary.opacity(hovering ? 0.45 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// "About the author" card with an animated Like button (heart pop + floating
/// hearts + a thanks message). The liked state persists across launches.
struct AboutSection: View {
    @ObservedObject var store: StatusStore
    @State private var liked = UserDefaults.standard.bool(forKey: "authorLiked")
    @State private var showThanks = UserDefaults.standard.bool(forKey: "authorLiked")
    @State private var pop = false
    @State private var hearts: [FloatingHeart] = []

    private let profile = URL(string: "https://github.com/haonguyenstech")!
    private let repo = URL(string: "https://github.com/haonguyenstech/autoagent-status")!

    private func metaRow(_ icon: String, _ label: String, _ value: String, mono: Bool = true) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? .caption.weight(.medium).monospacedDigit() : .caption.weight(.medium))
                .lineLimit(1).truncationMode(.middle)
        }
    }

    struct FloatingHeart: Identifiable {
        let id = UUID()
        let x: CGFloat
        let size: CGFloat
        var up = false
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [.green, .teal],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("HN").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hao Nguyen").font(.callout.weight(.semibold))
                    Text("Creator of AutoAgent Status").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { NSWorkspace.shared.open(profile) } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Open GitHub profile")
                Button { NSWorkspace.shared.open(repo) } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("View source on GitHub")
            }

            VStack(spacing: 6) {
                Divider().opacity(0.4)
                metaRow("terminal.fill", "Built on",
                        "auto-agent-ai " + (store.installedVersion.map { "v\($0)" } ?? "—"))
                metaRow("macwindow", "This app", "AutoAgent Status v\(appVersion)")
                if let role = store.status.role {
                    metaRow("person.fill", "Signed in as",
                            role.capitalized + (store.status.username.map { " · \($0)" } ?? ""), mono: false)
                }
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(.yellow)
                    Text("“Bringing AI to your life”")
                        .font(.caption2).italic().foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.top, 1)
            }

            Button { like() } label: {
                HStack(spacing: 8) {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .foregroundStyle(liked ? .pink : .secondary)
                        .scaleEffect(pop ? 1.4 : 1)
                    Text(liked ? "You liked this" : "Like")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(liked ? .pink : .primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(liked ? AnyShapeStyle(Color.pink.opacity(0.14))
                                    : AnyShapeStyle(.quaternary.opacity(0.6)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(liked ? Color.pink.opacity(0.45) : .clear, lineWidth: 1)
                )
                .overlay(alignment: .top) {
                    ZStack {
                        ForEach(hearts) { h in
                            Image(systemName: "heart.fill")
                                .font(.system(size: h.size))
                                .foregroundStyle(.pink)
                                .offset(x: h.x, y: h.up ? -52 : 6)
                                .opacity(h.up ? 0 : 1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showThanks {
                Text("Thanks for the love! ❤️")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.pink)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func like() {
        liked = true
        UserDefaults.standard.set(true, forKey: "authorLiked")

        // Heart pop
        withAnimation(.spring(response: 0.22, dampingFraction: 0.42)) { pop = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.25)) { pop = false }
        }
        withAnimation(.easeOut(duration: 0.25)) { showThanks = true }

        // Floating-hearts burst
        let xs: [CGFloat] = [-40, -24, -10, 8, 22, 38]
        let sizes: [CGFloat] = [9, 12, 8, 13, 10, 11]
        let batch = (0..<6).map { FloatingHeart(x: xs[$0], size: sizes[$0]) }
        hearts.append(contentsOf: batch)
        let ids = batch.map(\.id)
        withAnimation(.easeOut(duration: 0.9)) {
            for id in ids {
                if let idx = hearts.firstIndex(where: { $0.id == id }) { hearts[idx].up = true }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let set = Set(ids)
            hearts.removeAll { set.contains($0.id) }
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = StatusStore()
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingController(rootView: ContentView(store: store))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        store.$status.combineLatest(store.$busy, store.$keepAwake, store.$autoAwakeWithWatcher)
            .combineLatest(store.$planUsage)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &bag)

        store.refresh()
        store.checkVersions(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.store.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Undo the persistent lid-closed `disablesleep` flag so quitting never
        // leaves the Mac stuck never-sleeping.
        store.tearDownClamshell()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol = store.busy != nil ? "arrow.triangle.2.circlepath" : store.status.symbolName
        let desc = store.busy ?? store.status.headline
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: desc)

        // Compact status beside the icon: token countdown · session usage % · ☕
        var parts: [String] = []
        if store.busy == nil, let exp = store.status.expiresAt {
            let secs = exp.timeIntervalSinceNow
            if secs <= 0 {
                // While the watcher is renewing, the warning icon alone is enough
                if !store.status.watcherRunning { parts.append("expired") }
            } else {
                let h = Int(secs) / 3600
                let m = (Int(secs) % 3600) / 60
                parts.append(h > 0 ? "\(h)h \(m)m" : "\(m)m")
            }
        }
        if store.busy == nil,
           let session = store.planUsage?.limits.first(where: { $0.label == "Session" }) {
            parts.append("\(Int(session.percent.rounded()))%")
        }
        var title = parts.joined(separator: " · ")
        // Coffee marker while the Mac is held awake (manual or auto-with-watcher).
        if store.busy == nil && store.isStayingAwake {
            title += title.isEmpty ? "☕" : " ☕"
        }
        if !title.isEmpty { title = " " + title } // pad off the icon
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)])
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeft
        if button.image == nil { button.title = "AA" }
        let awakeNote = store.isStayingAwake ? " · keeping Mac awake" : ""
        var usageNote = ""
        if let p = store.planUsage, !p.limits.isEmpty {
            usageNote = " · " + p.limits
                .map { "\($0.label) \(Int($0.percent.rounded()))%" }
                .joined(separator: ", ")
        }
        button.toolTip = "AutoAgent — \(desc)\(usageNote)\(awakeNote)"
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
