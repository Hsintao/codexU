import Foundation

/// Reads Kimi Coding Plan quota from the official usage endpoint.
///
/// Official quota credentials come
/// either from the locally stored Kimi Code credential (`~/.kimi-code`) or from
/// a key the user entered in Settings. Local token statistics are read separately
/// from structured usage records in Kimi Code session logs.
struct KimiRuntimeProvider: RuntimeUsageProvider {
    let scope: RuntimeScope = .kimi

    func loadSnapshot(context: RuntimeLoadContext) -> RuntimeUsageSnapshot {
        var messages: [String] = []
        let local = KimiLocalUsageReader().loadLocalUsage(context: context, messages: &messages)
        let quotaSnapshot = loadQuotaSnapshot(context: context)
        return replacingLocal(quotaSnapshot, local: local, messages: messages)
    }

    func loadQuotaSnapshot(context: RuntimeLoadContext) -> RuntimeUsageSnapshot {
        var messages: [String] = []
        let resolution = KimiCredentialStore().resolveCredential(context: context, messages: &messages)

        switch resolution {
        case .failure(let failure):
            messages.append(failure.message)
            return makeSnapshot(context: context, quota: nil, credentialMissing: true, messages: messages)
        case .success(let credential):
            let outcome = KimiUsageClient().fetchQuota(
                credential: credential,
                context: context,
                messages: &messages
            )
            switch outcome {
            case .failure(let failure):
                messages.append(failure.message)
                return makeSnapshot(context: context, quota: nil, credentialMissing: false, messages: messages)
            case .success(let quota):
                return makeSnapshot(context: context, quota: quota, credentialMissing: false, messages: messages)
            }
        }
    }

    /// Local token statistics come from the Kimi Code session log, so this
    /// slice never needs the credential.
    func loadLocalSnapshot(context: RuntimeLoadContext) -> RuntimeUsageSnapshot {
        var messages: [String] = []
        let local = KimiLocalUsageReader().loadLocalUsage(context: context, messages: &messages)
        return makeSnapshot(context: context, quota: nil, credentialMissing: false, local: local, messages: messages)
    }

    func loadTaskBoard(context: RuntimeLoadContext) -> TaskBoard? {
        nil
    }

    /// Merges the local usage slice into a quota snapshot without dropping the
    /// quota's own messages.
    private func replacingLocal(
        _ runtime: RuntimeUsageSnapshot,
        local: LocalUsage?,
        messages: [String]
    ) -> RuntimeUsageSnapshot {
        let combined = runtime.snapshot.messages + messages
        let snapshot = UsageSnapshot(
            refreshedAt: runtime.snapshot.refreshedAt,
            account: runtime.snapshot.account,
            limitId: runtime.snapshot.limitId,
            limitName: runtime.snapshot.limitName,
            quotaReadSucceeded: runtime.snapshot.quotaReadSucceeded,
            fiveHourQuota: runtime.snapshot.fiveHourQuota,
            sevenDayQuota: runtime.snapshot.sevenDayQuota,
            monthlyQuota: runtime.snapshot.monthlyQuota,
            credits: runtime.snapshot.credits,
            cloudLifetimeTokens: runtime.snapshot.cloudLifetimeTokens,
            local: local,
            taskBoard: runtime.snapshot.taskBoard,
            messages: combined
        )
        return RuntimeUsageSnapshot(
            scope: runtime.scope,
            snapshot: snapshot,
            status: runtime.status,
            quotaSourceLabel: runtime.quotaSourceLabel,
            usageSourceLabel: local == nil ? runtime.usageSourceLabel : "Kimi Code local session logs"
        )
    }

    private func makeSnapshot(
        context: RuntimeLoadContext,
        quota: KimiQuota?,
        credentialMissing: Bool,
        local: LocalUsage? = nil,
        messages: [String]
    ) -> RuntimeUsageSnapshot {
        let hasQuota = quota?.hasAnyWindow ?? false
        let status: RuntimeMenuStatus
        if hasQuota {
            status = .available
        } else if credentialMissing {
            // No usable credential is a fixable setup state, not a broken
            // runtime, so it reads as "needs a snapshot" rather than "denied".
            status = .snapshotNeeded
        } else {
            status = .unavailable
        }

        let snapshot = UsageSnapshot(
            refreshedAt: context.now,
            account: hasQuota ? AccountInfo(type: "local", planType: "Kimi Coding Plan", emailPresent: false) : nil,
            limitId: scope.runtimeId,
            limitName: "Kimi Coding Plan",
            quotaReadSucceeded: hasQuota,
            fiveHourQuota: quota?.fiveHour,
            sevenDayQuota: quota?.sevenDay,
            monthlyQuota: quota?.monthly,
            credits: nil,
            cloudLifetimeTokens: nil,
            local: local,
            taskBoard: nil,
            messages: messages
        )

        return RuntimeUsageSnapshot(
            scope: scope,
            snapshot: snapshot,
            status: status,
            quotaSourceLabel: hasQuota ? "Kimi Coding Plan API" : "Kimi Coding Plan API; quota unavailable",
            usageSourceLabel: local == nil ? "Kimi local session logs" : "Kimi Code local session logs"
        )
    }
}

/// Quota windows as returned by the Kimi Coding Plan usage endpoint.
struct KimiQuota: Equatable {
    let fiveHour: RateWindow?
    let sevenDay: RateWindow?
    let monthly: RateWindow?

    var hasAnyWindow: Bool {
        fiveHour != nil || sevenDay != nil || monthly != nil
    }
}

struct KimiCredentialFailure: Error {
    let message: String
}

struct KimiCredential: Equatable {
    let accessToken: String
    let baseURL: String
    /// True when the token came from the locally stored Kimi Code credential,
    /// which means Kimi CLI owns and rotates the file.
    let isLocallyStored: Bool
}

enum KimiCredentialResolution {
    case success(KimiCredential)
    case failure(KimiCredentialFailure)
}

struct KimiUsageFailure: Error {
    let message: String
}

enum KimiUsageOutcome {
    case success(KimiQuota)
    case failure(KimiUsageFailure)
}

final class KimiCredentialCache {
    static let shared = KimiCredentialCache()

    // One active source bounds retained secrets; the lock also coalesces refreshes
    // across provider instances while the CLI remains the sole file writer.
    fileprivate let lock = NSLock()
    fileprivate var entry: Entry?

    fileprivate struct Entry {
        let sourceURL: URL
        let original: KimiCredentialStore.StoredCredential
        let refreshed: KimiCredentialStore.StoredCredential
    }
}

/// Resolves a usable Kimi credential, refreshing the locally stored access
/// token when it has expired. The store never writes back into `~/.kimi-code`,
/// so the Kimi CLI remains the sole owner of its own credential file.
struct KimiCredentialStore {
    static let defaultBaseURL = "https://api.kimi.com/coding/v1"
    private static let oauthHost = "https://auth.kimi.com"
    /// The OAuth token endpoint accepts a form-encoded refresh grant. The
    /// `/v1/oauth/token` path used by the workload-identity flow is not served.
    private static let tokenEndpoint = "/api/oauth/token"
    /// The access token is short-lived (900s). Refresh slightly early to avoid
    /// racing the expiry while a request is in flight.
    private static let refreshLeewaySeconds: TimeInterval = 30
    private static let maximumCredentialBytes = 64 * 1_024

    private let fileManager = FileManager.default
    private let cache: KimiCredentialCache
    private let execute: (URLRequest) -> Result<KimiSynchronousRequest.Response, KimiSynchronousRequest.Failure>

    init() {
        self.init(cache: .shared, execute: KimiSynchronousRequest.perform)
    }

    init(
        cache: KimiCredentialCache,
        execute: @escaping (URLRequest) -> Result<KimiSynchronousRequest.Response, KimiSynchronousRequest.Failure> = KimiSynchronousRequest.perform
    ) {
        self.cache = cache
        self.execute = execute
    }

    func resolveCredential(context: RuntimeLoadContext, messages: inout [String]) -> KimiCredentialResolution {
        if let error = context.kimiCredentialError {
            return .failure(KimiCredentialFailure(message: error))
        }
        if let manualKey = context.kimiAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !manualKey.isEmpty {
            return .success(KimiCredential(accessToken: manualKey, baseURL: Self.defaultBaseURL, isLocallyStored: false))
        }

        cache.lock.lock()
        defer { cache.lock.unlock() }
        let sourceURL = context.homeDirectory
            .appendingPathComponent(".kimi-code", isDirectory: true)
            .appendingPathComponent("credentials", isDirectory: true)
            .appendingPathComponent("kimi-code.json")
            .standardizedFileURL
        guard let stored = readStoredCredential(url: sourceURL, messages: &messages) else {
            cache.entry = nil
            return .failure(KimiCredentialFailure(
                message: "未找到 Kimi Code 凭证；请登录 Kimi Code，或在设置中填写 API Key"
            ))
        }

        if cache.entry?.sourceURL != sourceURL || cache.entry?.original != stored {
            cache.entry = nil
        }
        let active = cache.entry?.refreshed ?? stored
        if !isExpired(active, now: context.now) {
            return .success(KimiCredential(
                accessToken: active.accessToken,
                baseURL: Self.defaultBaseURL,
                isLocallyStored: true
            ))
        }

        guard let refreshToken = active.refreshToken, !refreshToken.isEmpty else {
            return .failure(KimiCredentialFailure(
                message: "Kimi Code 登录已过期，请重新登录 Kimi Code，或在设置中填写 API Key"
            ))
        }

        switch refresh(stored: active, refreshToken: refreshToken, context: context, messages: &messages) {
        case .success(let refreshed):
            cache.entry = .init(sourceURL: sourceURL, original: stored, refreshed: refreshed)
            return .success(KimiCredential(accessToken: refreshed.accessToken, baseURL: Self.defaultBaseURL, isLocallyStored: true))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    fileprivate struct StoredCredential: Equatable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        let clientID: String?
    }

    private func readStoredCredential(
        url: URL,
        messages: inout [String]
    ) -> StoredCredential? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= Self.maximumCredentialBytes else {
            return nil
        }

        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            messages.append("Kimi Code 凭证无法解析")
            return nil
        }

        guard let accessToken = kimiStringValue(object["access_token"]) ?? kimiStringValue(object["accessToken"]) else {
            messages.append("Kimi Code 登录状态已失效")
            return nil
        }

        return StoredCredential(
            accessToken: accessToken,
            refreshToken: kimiStringValue(object["refresh_token"]) ?? kimiStringValue(object["refreshToken"]),
            expiresAt: kimiDateValue(object["expires_at"]) ?? kimiDateValue(object["expiresAt"]),
            clientID: kimiClientID(from: accessToken) ?? kimiStringValue(object["client_id"])
        )
    }

    private func isExpired(_ credential: StoredCredential, now: Date) -> Bool {
        guard let expiresAt = credential.expiresAt else {
            // Without an expiry the token is assumed usable; a 401 will surface
            // the real state instead of forcing an unnecessary refresh.
            return false
        }
        return now.addingTimeInterval(Self.refreshLeewaySeconds) >= expiresAt
    }

    /// The Kimi CLI embeds the OAuth client id in the access token payload, so
    /// the refresh grant does not need any separately configured constant.
    private func kimiClientID(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = kimiStringValue(object["client_id"]) else {
            return nil
        }
        return clientID
    }

    private func refresh(
        stored: StoredCredential,
        refreshToken: String,
        context: RuntimeLoadContext,
        messages: inout [String]
    ) -> Result<StoredCredential, KimiCredentialFailure> {
        guard let clientID = stored.clientID, !clientID.isEmpty else {
            return .failure(KimiCredentialFailure(
                message: "Kimi Code 登录已过期，且无法从凭证中确定客户端标识；请重新登录 Kimi Code"
            ))
        }

        guard let url = URL(string: Self.oauthHost + Self.tokenEndpoint) else {
            return .failure(KimiCredentialFailure(message: "Kimi 凭证刷新地址无效"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = KimiSynchronousRequest.formEncodedBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])

        let result = execute(request)
        switch result {
        case .failure(let failure):
            return .failure(KimiCredentialFailure(message: failure.message))
        case .success(let response):
            guard response.status == 200 else {
                if response.status == 401 || response.status == 400 {
                    return .failure(KimiCredentialFailure(
                        message: "Kimi Code 登录已失效，请重新登录 Kimi Code，或在设置中填写 API Key"
                    ))
                }
                messages.append("Kimi Code 凭证刷新失败（HTTP \(response.status)）")
                return .failure(KimiCredentialFailure(
                    message: "Kimi Code 凭证刷新失败（HTTP \(response.status)），请稍后重试或重新登录"
                ))
            }
            guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let accessToken = kimiStringValue(object["access_token"]),
                  let refreshedToken = kimiStringValue(object["refresh_token"]),
                  let expiresIn = kimiDoubleValue(object["expires_in"]),
                  expiresIn.isFinite, expiresIn > 0 else {
                return .failure(KimiCredentialFailure(message: "Kimi Code 凭证刷新返回无法解析"))
            }
            // The refreshed token is held in memory only. Persisting it would
            // race the Kimi CLI, which owns and rotates the credential file.
            return .success(StoredCredential(
                accessToken: accessToken,
                refreshToken: refreshedToken,
                expiresAt: context.now.addingTimeInterval(expiresIn),
                clientID: clientID
            ))
        }
    }
}

/// Minimal synchronous HTTP helper. Providers expose synchronous loaders, so
/// the Kimi requests are bridged back to the caller instead of leaking async
/// work into the refresh coordinator.
struct KimiSynchronousRequest {
    struct Response {
        let status: Int
        let body: Data
    }

    struct Failure: Error {
        let message: String
        let isTimeout: Bool
    }

    static func formEncodedBody(_ fields: [String: String]) -> Data? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = fields.map { key, value -> String in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    static func perform(_ request: URLRequest) -> Result<Response, Failure> {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<Response, Failure> = .failure(Failure(message: "Kimi 请求未完成", isTimeout: false))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                let isTimeout = (error as NSError).code == NSURLErrorTimedOut
                outcome = .failure(Failure(
                    message: isTimeout ? "Kimi 请求超时" : "Kimi 网络请求失败",
                    isTimeout: isTimeout
                ))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failure(Failure(message: "Kimi 返回了无法识别的响应", isTimeout: false))
                return
            }
            outcome = .success(Response(status: http.statusCode, body: data ?? Data()))
        }
        task.resume()

        let deadline = DispatchTime.now() + request.timeoutInterval + 1
        if semaphore.wait(timeout: deadline) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            return .failure(Failure(message: "Kimi 请求超时", isTimeout: true))
        }
        session.finishTasksAndInvalidate()
        return outcome
    }
}

struct KimiUsageClient {
    func fetchQuota(
        credential: KimiCredential,
        context: RuntimeLoadContext,
        messages: inout [String]
    ) -> KimiUsageOutcome {
        guard let url = URL(string: credential.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/usages") else {
            return .failure(KimiUsageFailure(message: "Kimi 用量地址无效"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        switch KimiSynchronousRequest.perform(request) {
        case .failure(let failure):
            return .failure(KimiUsageFailure(message: failure.message))
        case .success(let response):
            guard response.status == 200 else {
                return .failure(KimiUsageFailure(message: Self.message(for: response.status, credential: credential)))
            }
            guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
                return .failure(KimiUsageFailure(message: "Kimi 用量响应无法解析"))
            }
            let quota = KimiUsageParser().parse(payload: object)
            guard quota.hasAnyWindow else {
                return .failure(KimiUsageFailure(message: "Kimi 用量响应中没有可识别的额度窗口"))
            }
            return .success(quota)
        }
    }

    private static func message(for status: Int, credential: KimiCredential) -> String {
        switch status {
        case 401:
            return credential.isLocallyStored
                ? "Kimi 认证失败（401），请重新登录 Kimi Code，或在设置中填写 API Key"
                : "Kimi 认证失败（401），请确认使用的是 Kimi Code 平台的 sk-kimi-xxx Key"
        case 403:
            return "Kimi 拒绝访问（403），请检查 API Key 是否有用量接口权限"
        case 404:
            return "未找到 Kimi 用量接口（404），请确认使用 https://api.kimi.com/coding/v1"
        case 429:
            return "Kimi 请求过于频繁（429），请稍后重试"
        default:
            return "Kimi 用量接口返回错误 \(status)"
        }
    }
}

/// Parses the Kimi Coding Plan usage payload.
///
/// The authoritative shape (matching the Kimi Code CLI) is snake_case:
/// `usages.limit_5h` / `limit_7d` / `limit_month_total` / `limit_month_code`,
/// each carrying `used_ratio` and `reset_time`. A flatter legacy shape is also
/// accepted so older deployments keep working.
struct KimiUsageParser {
    func parse(payload: [String: Any]) -> KimiQuota {
        if let usages = kimiDictionaryValue(payload["usages"]) {
            let quota = KimiQuota(
                fiveHour: kimiRateWindow(from: kimiDictionaryValue(usages["limit_5h"]), durationMins: 300),
                sevenDay: kimiRateWindow(from: kimiDictionaryValue(usages["limit_7d"]), durationMins: 10_080),
                monthly: kimiRateWindow(from: kimiDictionaryValue(usages["limit_month_total"]), durationMins: nil)
            )
            if quota.hasAnyWindow {
                return quota
            }
        }

        // Older or partial deployments expose the flat shape instead. Falling
        // back here keeps those readable without inventing windows.
        let legacy = parseLegacy(payload: payload)
        return legacy.hasAnyWindow ? legacy : KimiQuota(fiveHour: nil, sevenDay: nil, monthly: nil)
    }

    /// Legacy shape: `{ usage, limits[] }` with `used`/`limit`/`remaining`.
    private func parseLegacy(payload: [String: Any]) -> KimiQuota {
        let summary = kimiDictionaryValue(payload["usage"]).flatMap {
            legacyWindow(from: $0, durationMins: 10_080)
        }
        var windows: [RateWindow] = []

        // `limits[]` is independent of `data[]`: deployments that publish both
        // still describe the real quota windows only in `limits[]`.
        if let limits = payload["limits"] as? [Any] {
            for item in limits {
                guard let item = item as? [String: Any] else { continue }
                let detail = kimiDictionaryValue(item["detail"]) ?? item
                let durationMins = legacyWindowDuration(kimiDictionaryValue(item["window"]))
                guard let window = legacyWindow(from: detail, durationMins: durationMins) else { continue }
                windows.append(window)
            }
        }

        // Classify by the declared window duration so 5h/7d land in the same
        // slots the UI already renders for other runtimes.
        var fiveHour: RateWindow?
        var sevenDay: RateWindow?
        for window in windows {
            switch window.windowDurationMins {
            case 300:
                fiveHour = window
            case 10_080:
                sevenDay = window
            default:
                continue
            }
        }

        return KimiQuota(
            fiveHour: fiveHour,
            sevenDay: sevenDay ?? summary,
            monthly: nil
        )
    }

    private func legacyWindow(from object: [String: Any], durationMins: Int? = nil) -> RateWindow? {
        let limit = kimiDoubleValue(object["limit"] ?? object["limit_amount"])
        var used = kimiDoubleValue(object["used"] ?? object["used_amount"])
        if used == nil, let remaining = kimiDoubleValue(object["remaining"]), let limit {
            used = limit - remaining
        }
        let usedPercent: Double
        if let limit, limit > 0, let used {
            usedPercent = used / limit * 100
        } else if let ratio = kimiDoubleValue(object["used_ratio"] ?? object["usedRatio"]) {
            usedPercent = ratio * 100
        } else {
            return nil
        }
        return RateWindow(
            usedPercent: max(0, min(100, usedPercent)),
            windowDurationMins: durationMins,
            resetsAt: kimiResetDate(object)
        )
    }

    private func legacyWindowDuration(_ window: [String: Any]?) -> Int? {
        guard let window,
              let duration = kimiDoubleValue(window["duration"]) else {
            return nil
        }
        let unit = (kimiStringValue(window["time_unit"]) ?? kimiStringValue(window["timeUnit"]) ?? "").uppercased()
        let minutes: Double
        if unit.contains("MINUTE") {
            minutes = duration
        } else if unit.contains("HOUR") {
            minutes = duration * 60
        } else if unit.contains("DAY") {
            minutes = duration * 1_440
        } else if unit.contains("MONTH") {
            minutes = duration * 43_200
        } else {
            minutes = duration / 60
        }
        return Int(minutes.rounded())
    }

    private func kimiRateWindow(from entry: [String: Any]?, durationMins: Int?) -> RateWindow? {
        guard let entry else { return nil }
        guard let ratio = kimiDoubleValue(entry["used_ratio"] ?? entry["usedRatio"]) else { return nil }
        // The API expresses usage as a ratio where 1.0 means fully consumed.
        let usedPercent = ratio * 100
        return RateWindow(
            usedPercent: max(0, min(100, usedPercent)),
            windowDurationMins: durationMins,
            resetsAt: kimiResetDate(entry)
        )
    }
}

func kimiResetDate(_ object: [String: Any]) -> Date? {    if let date = kimiDateValue(object["reset_time"]) {
        return date
    }
    if let date = kimiDateValue(object["resetTime"]) {
        return date
    }
    if let seconds = kimiDoubleValue(object["reset_in"]) {
        return Date().addingTimeInterval(seconds)
    }
    return nil
}

func kimiStringValue(_ value: Any?) -> String? {
    if let string = value as? String, !string.isEmpty {
        return string
    }
    if let number = value as? NSNumber {
        return number.stringValue
    }
    return nil
}

func kimiDoubleValue(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
        return number.doubleValue
    }
    if let string = value as? String {
        return Double(string)
    }
    return nil
}

func kimiDictionaryValue(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

func kimiDateValue(_ value: Any?) -> Date? {
    if let date = value as? Date {
        return date
    }
    if let number = value as? NSNumber {
        let raw = number.doubleValue
        let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }
    guard let string = value as? String, !string.isEmpty else {
        return nil
    }
    if let seconds = Double(string) {
        let normalized = seconds > 10_000_000_000 ? seconds / 1000 : seconds
        return Date(timeIntervalSince1970: normalized)
    }

    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) {
        return date
    }

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: string)
}
