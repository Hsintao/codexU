import Foundation

/// Fixture-driven coverage for the Kimi runtime's quota path.
///
/// Fixtures use an injected transport or a loopback HTTP server; the self-test
/// never touches the real Kimi API or the user's live credential.
enum KimiQuotaSelfTest {
    static func run() -> Bool {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("codexu-kimi-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        let credentialStore = KimiCredentialStore(cache: KimiCredentialCache(), execute: { _ in
            expect(false, "credential-only fixtures must not issue OAuth requests")
            return .failure(.init(message: "unexpected OAuth request", isTimeout: false))
        })

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

            // -- 1. Authoritative snake_case payload (verified against the live API) --
            let live = """
            {
              "limits": [
                {"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
                 "detail": {"limit": "100", "remaining": "100", "resetTime": "2026-10-11T20:29:43.450762Z"}}
              ],
              "usages": {
                "limit_5h": {"used_ratio": 0, "reset_time": "2026-10-11T20:29:43Z"},
                "limit_month_total": {"used_ratio": 0.3087, "reset_time": "2026-10-24T03:29:43Z"},
                "limit_month_code": {"used_ratio": 0.3087, "reset_time": "2026-10-24T03:29:43Z"}
              }
            }
            """
            let payload = try jsonObject(live)
            let quota = KimiUsageParser().parse(payload: payload)
            expect(quota.hasAnyWindow, "the authoritative payload must produce quota windows")
            expect(quota.fiveHour?.usedPercent == 0, "limit_5h used_ratio 0 must map to 0% used")
            expect(quota.fiveHour?.remainingPercent == 100, "limit_5h must report 100% remaining")
            expect(quota.fiveHour?.windowDurationMins == 300, "limit_5h must carry a 5 hour window")
            expect(quota.monthly?.usedPercent != nil
                   && abs((quota.monthly?.usedPercent ?? 0) - 30.87) < 0.001,
                   "limit_month_total 0.3087 must map to 30.87% used")
            expect(abs((quota.monthly?.remainingPercent ?? 0) - 69.13) < 0.01,
                   "limit_month_total must report 69.13% remaining")
            expect(quota.sevenDay == nil, "an absent limit_7d must stay nil instead of becoming 0")
            expect(quota.fiveHour?.resetsAt != nil, "reset_time must parse into a date")

            // -- 2. Seven day window when the server reports one --
            let weekly = """
            {"usages": {
                "limit_5h": {"used_ratio": 0.25, "reset_time": "2026-10-11T20:29:43Z"},
                "limit_7d": {"used_ratio": 0.6, "reset_time": "2026-10-18T03:29:43Z"}
            }}
            """
            let weeklyQuota = KimiUsageParser().parse(payload: try jsonObject(weekly))
            expect(weeklyQuota.sevenDay?.windowDurationMins == 10_080, "limit_7d must carry a 7 day window")
            expect(abs((weeklyQuota.sevenDay?.usedPercent ?? 0) - 60) < 0.001, "limit_7d ratio must map to percent")
            expect(weeklyQuota.monthly == nil, "a missing monthly window must stay nil")

            // -- 3. Ratio tolerance: 1.0 means fully consumed, not 100x --
            let full = #"{"usages": {"limit_5h": {"used_ratio": 1.0}}}"#
            let fullQuota = KimiUsageParser().parse(payload: try jsonObject(full))
            expect(fullQuota.fiveHour?.usedPercent == 100, "used_ratio 1.0 must mean fully used")
            expect(fullQuota.fiveHour?.remainingPercent == 0, "used_ratio 1.0 must leave 0% remaining")

            // -- 4. String ratios and out-of-range values must clamp --
            let stringy = #"{"usages": {"limit_5h": {"used_ratio": "0.5"}, "limit_7d": {"used_ratio": 250}}}"#
            let stringyQuota = KimiUsageParser().parse(payload: try jsonObject(stringy))
            expect(abs((stringyQuota.fiveHour?.usedPercent ?? 0) - 50) < 0.001, "string used_ratio must parse")
            expect(stringyQuota.sevenDay?.usedPercent == 100, "out of range ratios must clamp to 100")

            // A ratio remains a ratio above 1; it must not become a percentage.
            let overQuota = KimiUsageParser().parse(payload: try jsonObject(
                #"{"usages":{"limit_5h":{"used_ratio":1.01}}}"#
            ))
            expect(overQuota.fiveHour?.usedPercent == 100, "a ratio above 1 must clamp to 100% used")
            expect(overQuota.fiveHour?.remainingPercent == 0, "an over-quota ratio must leave no remaining quota")

            // -- 5. Legacy flat payload still reads, without inventing windows --
            let legacy = """
            {"data": [{"model_name": "all", "limit": 1000, "used": 400},
                      {"model_name": "kimi-for-coding", "limit": 100, "used": 30}],
             "limits": [{"detail": {"name": "5h", "limit": 100, "used": 30},
                         "window": {"duration": 5, "time_unit": "HOUR"}}]}
            """
            let legacyQuota = KimiUsageParser().parse(payload: try jsonObject(legacy))
            expect(legacyQuota.fiveHour?.windowDurationMins == 300, "legacy 5 hour window must be classified")
            expect(legacyQuota.monthly == nil, "the legacy shape must not fabricate a monthly window")

            // The legacy usage summary is weekly, independently of limits[].
            let legacyWeekly = KimiUsageParser().parse(payload: try jsonObject(
                #"{"usage":{"limit":"100","used":"60"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"20"}}]}"#
            ))
            expect(legacyWeekly.fiveHour?.usedPercent == 20, "declared 5h usage must retain its own value")
            expect(legacyWeekly.sevenDay?.usedPercent == 60, "the legacy weekly summary must not be dropped")
            expect(legacyWeekly.sevenDay?.windowDurationMins == 10_080, "the weekly summary must carry a 7d duration")
            let weeklyOnly = KimiUsageParser().parse(payload: try jsonObject(
                #"{"usage":{"limit":100,"remaining":40}}"#
            ))
            expect(weeklyOnly.fiveHour == nil, "a weekly-only response must not invent a 5h window")
            expect(weeklyOnly.sevenDay?.usedPercent == 60, "a weekly-only response must retain its quota")
            let unclassified = KimiUsageParser().parse(payload: try jsonObject(
                #"{"data":[{"model_name":"all","limit":100,"used":40},{"model_name":"model-a","limit":100,"used":20}],"limits":[{"detail":{"limit":100,"used":30}}]}"#
            ))
            expect(!unclassified.hasAnyWindow, "unclassified model/count entries must not invent time windows")
            let legacyRatio = KimiUsageParser().parse(payload: try jsonObject(
                #"{"limits":[{"window":{"duration":5,"timeUnit":"HOUR"},"detail":{"used_ratio":1.01}}]}"#
            ))
            expect(legacyRatio.fiveHour?.usedPercent == 100, "a legacy ratio above 1 must also clamp to 100% used")

            // -- 6. Unrecognised payload must not pretend to have quota --
            let empty = KimiUsageParser().parse(payload: try jsonObject(#"{"foo": "bar"}"#))
            expect(!empty.hasAnyWindow, "an unrecognised payload must report no quota rather than zeros")

            let emptyUsages = KimiUsageParser().parse(payload: try jsonObject(#"{"usages": {}}"#))
            expect(!emptyUsages.hasAnyWindow, "an empty usages object must report no quota")

            // -- 7. Credential store: missing credential stays unavailable --
            let home = root.appendingPathComponent("home", isDirectory: true)
            try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
            let context = RuntimeLoadContext(
                now: Date(),
                homeDirectory: home,
                cacheDirectory: root.appendingPathComponent("cache", isDirectory: true),
                statistics: StatisticsContext(preference: .default, now: Date())
            )
            var messages: [String] = []
            switch credentialStore.resolveCredential(context: context, messages: &messages) {
            case .success:
                failures.append("a missing Kimi credential must not resolve")
            case .failure(let failure):
                expect(failure.message.contains("凭证"),
                       "a missing credential must explain itself in user-facing language")
            }

            // -- 8. A user supplied key takes precedence and needs no local file --
            let manualContext = RuntimeLoadContext(
                now: Date(),
                homeDirectory: home,
                cacheDirectory: root.appendingPathComponent("cache", isDirectory: true),
                statistics: StatisticsContext(preference: .default, now: Date()),
                kimiAPIKey: "sk-kimi-manual"
            )
            var manualMessages: [String] = []
            switch credentialStore.resolveCredential(context: manualContext, messages: &manualMessages) {
            case .success(let credential):
                expect(credential.accessToken == "sk-kimi-manual", "the manually entered key must be used as-is")
                expect(!credential.isLocallyStored, "a manual key must not be treated as the local credential")
            case .failure:
                failures.append("a manual key must resolve without a local Kimi Code credential")
            }

            // -- 9. A fresh local credential is used without a refresh round trip --
            let credentialDirectory = home
                .appendingPathComponent(".kimi-code", isDirectory: true)
                .appendingPathComponent("credentials", isDirectory: true)
            try fileManager.createDirectory(at: credentialDirectory, withIntermediateDirectories: true)
            let futureExpiry = Int(Date().addingTimeInterval(3_600).timeIntervalSince1970)
            let freshCredential = """
            {"access_token": "eyJhbGciOiJFUzI1NiJ9.eyJjbGllbnRfaWQiOiJ0ZXN0LWNsaWVudCJ9.sig",
             "refresh_token": "refresh", "expires_at": \(futureExpiry), "scope": "kimi-code"}
            """
            try Data(freshCredential.utf8).write(to: credentialDirectory.appendingPathComponent("kimi-code.json"))
            var freshMessages: [String] = []
            switch credentialStore.resolveCredential(context: context, messages: &freshMessages) {
            case .success(let credential):
                expect(credential.isLocallyStored, "a stored credential must be flagged as locally owned")
            case .failure(let failure):
                failures.append("a fresh local credential must resolve: \(failure.message)")
            }

            // -- 10. An expired token without a refresh token must fail clearly --
            let pastExpiry = Int(Date().addingTimeInterval(-3_600).timeIntervalSince1970)
            let expiredCredential = """
            {"access_token": "eyJhbGciOiJFUzI1NiJ9.eyJjbGllbnRfaWQiOiJ0ZXN0LWNsaWVudCJ9.sig",
             "expires_at": \(pastExpiry), "scope": "kimi-code"}
            """
            try Data(expiredCredential.utf8).write(to: credentialDirectory.appendingPathComponent("kimi-code.json"))
            var expiredMessages: [String] = []
            switch credentialStore.resolveCredential(context: context, messages: &expiredMessages) {
            case .success:
                failures.append("an expired token without a refresh token must not resolve")
            case .failure(let failure):
                expect(failure.message.contains("过期"),
                       "an expired credential must explain that it expired")
            }

            // -- 11. Malformed credential file must be reported, not silently ignored --
            try Data("{ not json".utf8).write(to: credentialDirectory.appendingPathComponent("kimi-code.json"))
            var malformedMessages: [String] = []
            switch credentialStore.resolveCredential(context: context, messages: &malformedMessages) {
            case .success:
                failures.append("a malformed credential file must not resolve")
            case .failure(let failure):
                expect(failure.message.contains("凭证") || malformedMessages.contains(where: { $0.contains("无法解析") }),
                       "a malformed credential file must be reported")
            }

            // -- 12. An oversized credential file must be refused --
            try Data(repeating: 32, count: 64 * 1_024 + 1).write(to: credentialDirectory.appendingPathComponent("kimi-code.json"))
            var oversizedMessages: [String] = []
            switch credentialStore.resolveCredential(context: context, messages: &oversizedMessages) {
            case .success:
                failures.append("an oversized credential file must be refused")
            case .failure:
                break
            }

            // -- 12b. A logged-out credential (blanked by the Kimi CLI) must be
            // reported as an expired login, and the runtime must fall back to
            // the fixable "needs snapshot" state rather than a hard failure.
            let blanked = #"{"access_token":"","refresh_token":"","expires_at":0,"scope":"kimi-code"}"#
            try Data(blanked.utf8).write(to: credentialDirectory.appendingPathComponent("kimi-code.json"))
            var blankedMessages: [String] = []
            switch credentialStore.resolveCredential(context: context, messages: &blankedMessages) {
            case .success:
                failures.append("a blanked credential must not resolve")
            case .failure(let failure):
                expect(failure.message.contains("凭证"),
                       "a blanked credential must explain the credential state")
            }
            expect(blankedMessages.contains(where: { $0.contains("登录状态") }),
                   "a blanked credential must be reported as an expired login")
            let blankedSnapshot = KimiRuntimeProvider().loadQuotaSnapshot(context: context)
            expect(blankedSnapshot.status == .snapshotNeeded,
                   "a missing credential must read as snapshot needed, not unavailable")
            expect(!blankedSnapshot.snapshot.quotaReadSucceeded,
                   "a missing credential must not report a successful quota read")
            expect(blankedSnapshot.snapshot.fiveHourQuota == nil
                   && blankedSnapshot.snapshot.sevenDayQuota == nil
                   && blankedSnapshot.snapshot.monthlyQuota == nil,
                   "a missing credential must not fabricate quota windows")

            try runOAuthScenario(root: root, expect: expect)

            // -- 13. End to end against a stub server: quota, then 401, then 404 --
            let stub = try KimiStubServer()
            defer { stub.stop() }
            var stubFailures: [String] = []
            func stubExpect(_ condition: @autoclosure () -> Bool, _ message: String) {
                if !condition() { stubFailures.append(message) }
            }
            try runStubScenario(stub: stub, root: root, expect: stubExpect)
            failures.append(contentsOf: stubFailures)

            // Each deliberately wrong HTTP outcome must reach the accumulator,
            // rather than merely printing an error and returning success.
            let wrongOutcomes: [(Int, String, Int, String)] = [
                (200, "0.2", 500, #"{"error":"server error"}"#),
                (401, "unauthorized", 200, #"{"usages":{"limit_5h":{"used_ratio":0.2}}}"#),
                (404, "not found", 200, #"{"usages":{"limit_5h":{"used_ratio":0.2}}}"#),
                (200, "{}", 200, #"{"usages":{"limit_5h":{"used_ratio":0.2}}}"#)
            ]
            for (status, marker, wrongStatus, wrongBody) in wrongOutcomes {
                let wrongStub = try KimiStubServer(responseOverride: { actualStatus, body in
                    actualStatus == status && body.contains(marker) ? (wrongStatus, wrongBody) : (actualStatus, body)
                })
                defer { wrongStub.stop() }
                var detected: [String] = []
                func detect(_ condition: @autoclosure () -> Bool, _ message: String) {
                    if !condition() { detected.append(message) }
                }
                try runStubScenario(stub: wrongStub, root: root, expect: detect)
                expect(detected.count == 1, "the deliberately wrong HTTP \(status)/\(marker) outcome must record one failure")
            }
        } catch {
            failures.append("Kimi self-test threw: \(error)")
        }

        if failures.isEmpty {
            print("Kimi quota self-test passed")
            return true
        }
        failures.forEach { print("Kimi quota self-test failed: \($0)") }
        return false
    }

    private static func runStubScenario(
        stub: KimiStubServer,
        root: URL,
        expect: (@autoclosure () -> Bool, String) -> Void
    ) throws {
        let context = RuntimeLoadContext(
            now: Date(),
            homeDirectory: root,
            cacheDirectory: root.appendingPathComponent("cache2", isDirectory: true),
            statistics: StatisticsContext(preference: .default, now: Date()),
            kimiAPIKey: "sk-kimi-stub"
        )
        let client = KimiUsageClient()
        let credential = KimiCredential(
            accessToken: "sk-kimi-stub",
            baseURL: "http://127.0.0.1:\(stub.port)/coding/v1",
            isLocallyStored: false
        )

        stub.respond(status: 200, body: """
        {"usages": {"limit_5h": {"used_ratio": 0.2, "reset_time": "2026-10-11T20:29:43Z"}}}
        """)
        var messages: [String] = []
        switch client.fetchQuota(credential: credential, context: context, messages: &messages) {
        case .success(let quota):
            expect(abs((quota.fiveHour?.usedPercent ?? 0) - 20) < 0.001, "the stub server quota must parse through the client")
        case .failure(let failure):
            expect(false, "stub fetch failed: \(failure.message)")
        }
        expect(stub.lastRequestPath == "/coding/v1/usages", "the client must call the /usages endpoint")
        expect(stub.lastAuthorization == "Bearer sk-kimi-stub", "the client must send the bearer token")

        stub.respond(status: 401, body: #"{"error":"unauthorized"}"#)
        var unauthorizedMessages: [String] = []
        switch client.fetchQuota(credential: credential, context: context, messages: &unauthorizedMessages) {
        case .success:
            expect(false, "401 must not be reported as success")
        case .failure(let failure):
            expect(failure.message.contains("401"), "a 401 must be surfaced with its status")
            expect(failure.message.contains("sk-kimi"), "a 401 on a manual key must explain the key type")
        }

        stub.respond(status: 404, body: #"{"error":"not found"}"#)
        var notFoundMessages: [String] = []
        switch client.fetchQuota(credential: credential, context: context, messages: &notFoundMessages) {
        case .success:
            expect(false, "404 must not be reported as success")
        case .failure(let failure):
            expect(failure.message.contains("api.kimi.com"), "a 404 must explain the expected base URL")
        }

        stub.respond(status: 200, body: #"{"usages": {}}"#)
        var emptyMessages: [String] = []
        switch client.fetchQuota(credential: credential, context: context, messages: &emptyMessages) {
        case .success:
            expect(false, "an empty payload must not be reported as success")
        case .failure:
            break
        }

        // The local slice is independent of the credential: with no Kimi Code
        // sessions present it must report why, rather than inventing usage.
        let snapshot = KimiRuntimeProvider().loadLocalSnapshot(
            context: RuntimeLoadContext(
                now: Date(),
                homeDirectory: root,
                cacheDirectory: root.appendingPathComponent("cache2", isDirectory: true),
                statistics: StatisticsContext(preference: .default, now: Date()),
                kimiAPIKey: "sk-kimi-stub"
            )
        )
        expect(snapshot.snapshot.local == nil,
               "a home without Kimi Code sessions must not fabricate local token usage")
        expect(snapshot.snapshot.quotaReadSucceeded == false,
               "the local slice must not claim a successful quota read")
        expect(snapshot.snapshot.messages.contains(where: { $0.contains(".kimi-code") }),
               "the local slice must name the sessions directory it looked for")
    }

    private static func runOAuthScenario(
        root: URL,
        expect: @escaping (@autoclosure () -> Bool, String) -> Void
    ) throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let home = root.appendingPathComponent("oauth-home", isDirectory: true)
        let directory = home.appendingPathComponent(".kimi-code/credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("kimi-code.json")
        let original = Data(#"{"access_token":"access-0","refresh_token":"refresh+0&=","expires_at":1999999900,"client_id":"test-client","scope":"kimi-code","token_type":"Bearer"}"#.utf8)
        try original.write(to: file)

        func context(_ home: URL, seconds: TimeInterval = 0, key: String? = nil, error: String? = nil) -> RuntimeLoadContext {
            let date = now.addingTimeInterval(seconds)
            return RuntimeLoadContext(now: date, homeDirectory: home, cacheDirectory: root.appendingPathComponent("oauth-cache"),
                                      statistics: StatisticsContext(preference: .default, now: date),
                                      kimiAPIKey: key, kimiCredentialError: error)
        }
        func token(_ outcome: KimiCredentialResolution, _ message: String) -> String? {
            switch outcome {
            case .success(let credential):
                return credential.accessToken
            case .failure(let failure):
                expect(false, "\(message): \(failure.message)")
                return nil
            }
        }

        let cache = KimiCredentialCache()
        var requests: [URLRequest] = []
        let execute: (URLRequest) -> Result<KimiSynchronousRequest.Response, KimiSynchronousRequest.Failure> = { request in
            requests.append(request)
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            let fields = URLComponents(string: "?" + body)?.queryItems ?? []
            func field(_ name: String) -> String? { fields.first { $0.name == name }?.value }
            expect(request.url?.absoluteString == "https://auth.kimi.com/api/oauth/token", "refresh must use the official OAuth endpoint")
            expect(request.httpMethod == "POST", "refresh must use a POST grant")
            expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded", "refresh must send form data")
            expect(field("grant_type") == "refresh_token", "refresh must send the refresh grant")
            expect(field("client_id") == "test-client", "the cached opaque token must retain the original client ID")
            let response: String
            switch field("refresh_token") {
            case "refresh+0&=":
                response = #"{"access_token":"access-1","refresh_token":"refresh-1","expires_in":90,"scope":"kimi-code","token_type":"Bearer"}"#
            case "refresh-1":
                response = #"{"access_token":"access-2","refresh_token":"refresh-2","expires_in":900,"scope":"kimi-code","token_type":"Bearer"}"#
            case "refresh-b0":
                response = #"{"access_token":"access-b1","refresh_token":"refresh-b1","expires_in":900,"scope":"kimi-code","token_type":"Bearer"}"#
            default:
                expect(false, "refresh must use a known, correctly form-encoded token")
                return .success(.init(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)))
            }
            return .success(.init(status: 200, body: Data(response.utf8)))
        }
        let store = KimiCredentialStore(cache: cache, execute: execute)
        var messages: [String] = []
        expect(token(store.resolveCredential(context: context(home), messages: &messages), "initial refresh") == "access-1",
               "an expired source credential must refresh")
        let nextStore = KimiCredentialStore(cache: cache, execute: execute)
        expect(token(nextStore.resolveCredential(context: context(home, seconds: 20), messages: &messages), "cached resolve") == "access-1",
               "another store sharing the cache must reuse the refreshed access token")
        expect(requests.count == 1, "a still-valid cached access token must not issue another refresh")
        expect(token(nextStore.resolveCredential(context: context(home, seconds: 61), messages: &messages), "rotated refresh") == "access-2",
               "expiry must refresh using the retained rotated refresh token")
        expect(requests.count == 2, "the refreshed expires_in must control the next refresh time")
        let unchanged = try Data(contentsOf: file)
        expect(unchanged == original, "OAuth refresh must never rewrite the CLI credential file")

        // The saved key and Keychain failure are resolved before any CLI token.
        let callsBeforeManual = requests.count
        switch nextStore.resolveCredential(context: context(home, seconds: 62, key: "sk-kimi-manual"), messages: &messages) {
        case .success(let credential):
            expect(credential.accessToken == "sk-kimi-manual" && !credential.isLocallyStored,
                   "a manual key must never reuse an OAuth cache entry")
        case .failure:
            expect(false, "a manual key must resolve independently of OAuth")
        }
        switch nextStore.resolveCredential(context: context(home, key: "sk-kimi-manual", error: "Keychain read failed"), messages: &messages) {
        case .success:
            expect(false, "a Keychain error must not select a manual or CLI credential")
        case .failure(let failure):
            expect(failure.message == "Keychain read failed", "a Keychain error must be returned to the provider")
        }
        expect(requests.count == callsBeforeManual, "manual keys and credential errors must not issue OAuth requests")

        // Identical bytes at a different source path must not reuse this account cache.
        let otherHome = root.appendingPathComponent("other-oauth-home", isDirectory: true)
        let otherDirectory = otherHome.appendingPathComponent(".kimi-code/credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        try original.write(to: otherDirectory.appendingPathComponent("kimi-code.json"))
        expect(token(nextStore.resolveCredential(context: context(otherHome, seconds: 62), messages: &messages), "other path") == "access-1",
               "cached credentials must be bound to the source path")
        expect(requests.count == callsBeforeManual + 1, "a different source path must resolve its own credential")

        let changed = Data(#"{"access_token":"access-b0","refresh_token":"refresh-b0","expires_at":1999999900,"client_id":"test-client","scope":"kimi-code","token_type":"Bearer"}"#.utf8)
        try changed.write(to: otherDirectory.appendingPathComponent("kimi-code.json"))
        expect(token(nextStore.resolveCredential(context: context(otherHome, seconds: 63), messages: &messages), "changed account") == "access-b1",
               "changing the on-disk account must invalidate the old cached token")
        let callsAfterAccountChange = requests.count
        expect(callsAfterAccountChange == callsBeforeManual + 2, "a new account must refresh its own token")
        let otherFile = otherDirectory.appendingPathComponent("kimi-code.json")
        try FileManager.default.removeItem(at: otherFile)
        switch nextStore.resolveCredential(context: context(otherHome, seconds: 64), messages: &messages) {
        case .success:
            expect(false, "a removed credential must not resolve from the cache")
        case .failure:
            break
        }
        try changed.write(to: otherFile)
        expect(token(nextStore.resolveCredential(context: context(otherHome, seconds: 65), messages: &messages), "restored account") == "access-b1",
               "a restored credential must resolve again")
        expect(requests.count == callsAfterAccountChange + 1, "removing the source must invalidate its cached identity")

        let independent = KimiCredentialStore(cache: KimiCredentialCache(), execute: execute)
        expect(token(independent.resolveCredential(context: context(home), messages: &messages), "independent cache") == "access-1",
               "an injected cache must be independent of other stores")
        expect(requests.count == callsAfterAccountChange + 2, "isolated caches must not consult shared live state")

        // An incomplete refreshed token cannot safely enter the memory cache.
        for malformed in [
            #"{"access_token":"new-access","expires_in":900}"#,
            #"{"access_token":"new-access","refresh_token":"new-refresh"}"#,
            #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":0}"#
        ] {
            let malformedStore = KimiCredentialStore(cache: KimiCredentialCache(), execute: { _ in
                .success(.init(status: 200, body: Data(malformed.utf8)))
            })
            switch malformedStore.resolveCredential(context: context(home), messages: &messages) {
            case .success:
                expect(false, "a refresh without a rotated token and positive lifetime must fail")
            case .failure:
                break
            }
        }
    }

    private static func jsonObject(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw KimiSelfTestError.invalidFixture
        }
        return object
    }
}

enum KimiSelfTestError: Error {
    case invalidFixture
    case serverStartFailed
}

/// Minimal loopback HTTP server used to exercise the Kimi client without
/// touching the network or the real credential.
final class KimiStubServer {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var responseStatus = 200
    private var responseBody = "{}"
    private var stopped = false
    private var thread: Thread?
    private let responseOverride: ((Int, String) -> (Int, String))?

    private(set) var lastRequestPath: String?
    private(set) var lastAuthorization: String?

    init(responseOverride: ((Int, String) -> (Int, String))? = nil) throws {
        self.responseOverride = responseOverride
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw KimiSelfTestError.serverStartFailed }
        listener = descriptor

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(descriptor)
            throw KimiSelfTestError.serverStartFailed
        }
        guard listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw KimiSelfTestError.serverStartFailed
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        guard named == 0 else {
            close(descriptor)
            throw KimiSelfTestError.serverStartFailed
        }
        port = UInt16(bigEndian: actual.sin_port)
        startServing()
    }

    private func startServing() {
        let server = Thread { [weak self] in self?.serve() }
        server.stackSize = 512 * 1_024
        thread = server
        server.start()
    }

    func respond(status: Int, body: String) {
        let response = responseOverride?(status, body) ?? (status, body)
        lock.lock()
        responseStatus = response.0
        responseBody = response.1
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        if !alreadyStopped {
            close(listener)
        }
    }

    private func serve() {
        while true {
            lock.lock()
            let done = stopped
            lock.unlock()
            if done { return }

            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            handle(client: client)
            close(client)
        }
    }

    private func handle(client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        let read = recv(client, &buffer, buffer.count, 0)
        guard read > 0, let request = String(bytes: buffer[0..<read], encoding: .utf8) else { return }

        let lines = request.split(separator: "\r\n", omittingEmptySubsequences: false)
        if let first = lines.first {
            let parts = first.split(separator: " ")
            if parts.count > 1 {
                lock.lock()
                lastRequestPath = String(parts[1])
                lock.unlock()
            }
        }
        for line in lines.dropFirst() {
            let lowered = line.lowercased()
            if lowered.hasPrefix("authorization:") {
                lock.lock()
                lastAuthorization = String(line.dropFirst("authorization:".count))
                    .trimmingCharacters(in: .whitespaces)
                lock.unlock()
            }
        }

        lock.lock()
        let status = responseStatus
        let body = responseBody
        lock.unlock()

        let reason = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : (status == 404 ? "Not Found" : "Error"))
        let payload = Data(body.utf8)
        var response = "HTTP/1.1 \(status) \(reason)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(payload.count)\r\n"
        response += "Connection: close\r\n\r\n"
        _ = response.withCString { pointer in send(client, pointer, strlen(pointer), 0) }
        _ = payload.withUnsafeBytes { raw in send(client, raw.baseAddress, payload.count, 0) }
    }
}
