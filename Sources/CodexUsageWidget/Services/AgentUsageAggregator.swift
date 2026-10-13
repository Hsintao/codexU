import Foundation

struct AgentUsageAggregator {
    func aggregate(_ runtimes: [RuntimeUsageSnapshot], at refreshedAt: Date) -> UsageSnapshot {
        let locals = runtimes.compactMap { $0.snapshot.local }
        let local = aggregateLocalUsage(locals)
        var messages = runtimes.flatMap { runtime in
            runtime.snapshot.messages.map { "\(runtime.displayName): \($0)" }
        }
        if !locals.isEmpty, local == nil {
            messages.append("Runtime 合计 token 超出可表示范围，合计统计暂不可用")
        }

        return UsageSnapshot(
            refreshedAt: refreshedAt,
            account: nil,
            limitId: "all-runtimes",
            limitName: "All runtimes",
            quotaReadSucceeded: false,
            fiveHourQuota: nil,
            sevenDayQuota: nil,
            monthlyQuota: nil,
            credits: nil,
            cloudLifetimeTokens: nil,
            local: local,
            taskBoard: nil,
            messages: messages
        )
    }

    private func aggregateLocalUsage(_ locals: [LocalUsage]) -> LocalUsage? {
        guard !locals.isEmpty else { return nil }

        var lifetimeTokens: Int64 = 0
        var todayTokens: Int64 = 0
        var sevenDayTokens: Int64 = 0
        var threadCount = 0
        for local in locals {
            let lifetime = lifetimeTokens.addingReportingOverflow(local.lifetimeTokens)
            let today = todayTokens.addingReportingOverflow(local.todayTokens)
            let sevenDay = sevenDayTokens.addingReportingOverflow(local.sevenDayTokens)
            let threads = threadCount.addingReportingOverflow(local.threadCount)
            guard !lifetime.overflow, !today.overflow, !sevenDay.overflow, !threads.overflow else { return nil }
            lifetimeTokens = lifetime.partialValue
            todayTokens = today.partialValue
            sevenDayTokens = sevenDay.partialValue
            threadCount = threads.partialValue
        }
        let lastUpdatedAt = locals.compactMap(\.lastUpdatedAt).max()
        let dailyBuckets = aggregateDailyBuckets(locals.flatMap(\.dailyBuckets))
        let detailedUsage = aggregateDetailedUsage(locals.compactMap(\.detailedUsage))
        let projectBoard = aggregateProjectBoards(locals.compactMap(\.projectBoard))
        let toolUsages = aggregateToolUsages(locals.flatMap(\.toolUsages))
        let skillUsages = aggregateSkillUsages(locals.flatMap(\.skillUsages))
        let recentThreads = locals.flatMap(\.recentThreads)
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            .prefix(12)

        return LocalUsage(
            lifetimeTokens: lifetimeTokens,
            todayTokens: todayTokens,
            sevenDayTokens: sevenDayTokens,
            threadCount: threadCount,
            lastUpdatedAt: lastUpdatedAt,
            dailyBuckets: dailyBuckets,
            recentThreads: Array(recentThreads),
            detailedUsage: detailedUsage,
            usageTrend: nil,
            inferencePerformance: nil,
            projectBoard: projectBoard,
            toolUsages: toolUsages,
            skillUsages: skillUsages
        )
    }

    private func aggregateDailyBuckets(_ buckets: [DailyTokenBucket]) -> [DailyTokenBucket] {
        var totals: [String: (label: String, tokens: Int64)] = [:]
        for bucket in buckets {
            var current = totals[bucket.id] ?? (bucket.label, 0)
            current.tokens += bucket.tokens
            totals[bucket.id] = current
        }
        return totals
            .map { DailyTokenBucket(id: $0.key, label: $0.value.label, tokens: $0.value.tokens) }
            .sorted { $0.id < $1.id }
    }

    private func aggregateDetailedUsage(_ values: [DetailedUsage]) -> DetailedUsage? {
        guard !values.isEmpty else { return nil }
        var today = PricedTokenUsage.zero
        var sevenDay = PricedTokenUsage.zero
        var month = PricedTokenUsage.zero
        var lifetime = PricedTokenUsage.zero
        var parsedFileCount = 0
        var tokenEventCount = 0

        for value in values {
            today.add(tokens: value.today.tokens, costUSD: value.today.estimatedCostUSD, usesReferencePricing: value.today.usesReferencePricing, hasEstimatedCost: value.today.hasEstimatedCost)
            sevenDay.add(tokens: value.sevenDay.tokens, costUSD: value.sevenDay.estimatedCostUSD, usesReferencePricing: value.sevenDay.usesReferencePricing, hasEstimatedCost: value.sevenDay.hasEstimatedCost)
            month.add(tokens: value.month.tokens, costUSD: value.month.estimatedCostUSD, usesReferencePricing: value.month.usesReferencePricing, hasEstimatedCost: value.month.hasEstimatedCost)
            lifetime.add(tokens: value.lifetime.tokens, costUSD: value.lifetime.estimatedCostUSD, usesReferencePricing: value.lifetime.usesReferencePricing, hasEstimatedCost: value.lifetime.hasEstimatedCost)
            parsedFileCount += value.parsedFileCount
            tokenEventCount += value.tokenEventCount
        }

        return DetailedUsage(
            today: today,
            sevenDay: sevenDay,
            month: month,
            lifetime: lifetime,
            parsedFileCount: parsedFileCount,
            tokenEventCount: tokenEventCount
        )
    }

    private func aggregateProjectBoards(_ boards: [ProjectBoard]) -> ProjectBoard? {
        let projects = boards.flatMap(\.allProjects)
        guard !projects.isEmpty else { return nil }

        var map: [String: AggregatedProject] = [:]
        for project in projects {
            var current = map[project.id] ?? AggregatedProject(project)
            current.add(project)
            map[project.id] = current
        }

        let all = map.values.map { $0.makeProject() }
            .sorted {
                if $0.tokens == $1.tokens {
                    return ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast)
                }
                return $0.tokens > $1.tokens
            }
        return ProjectBoard(recentProjects: Array(all.prefix(8)), allProjects: all)
    }

    private func aggregateToolUsages(_ tools: [ToolUsage]) -> [ToolUsage] {
        var map: [String: ToolUsage] = [:]
        for tool in tools {
            if let existing = map[tool.id] {
                map[tool.id] = ToolUsage(
                    id: existing.id,
                    name: existing.name,
                    category: existing.category,
                    callCount: existing.callCount + tool.callCount,
                    estimatedTokens: addOptional(existing.estimatedTokens, tool.estimatedTokens),
                    estimatedCostUSD: addOptional(existing.estimatedCostUSD, tool.estimatedCostUSD)
                )
            } else {
                map[tool.id] = tool
            }
        }
        return map.values.sorted { $0.callCount > $1.callCount }
    }

    private func aggregateSkillUsages(_ skills: [SkillUsage]) -> [SkillUsage] {
        var map: [String: SkillUsage] = [:]
        for skill in skills {
            if let existing = map[skill.id] {
                map[skill.id] = SkillUsage(
                    id: existing.id,
                    name: existing.name,
                    path: existing.path,
                    sourceLabel: existing.sourceLabel,
                    loadCount: existing.loadCount + skill.loadCount,
                    threadCount: existing.threadCount + skill.threadCount,
                    staticTokenEstimate: existing.staticTokenEstimate ?? skill.staticTokenEstimate,
                    staticByteCount: existing.staticByteCount ?? skill.staticByteCount,
                    lastLoadedAt: maxDate(existing.lastLoadedAt, skill.lastLoadedAt)
                )
            } else {
                map[skill.id] = skill
            }
        }
        return map.values.sorted { $0.loadCount > $1.loadCount }
    }
}

private struct AggregatedProject {
    let id: String
    let name: String
    let fullPath: String
    var tokens: Int64 = 0
    private var knownCostUSD: Double = 0
    private var hasEstimatedCost = true
    var estimatedCostUSD: Double? { hasEstimatedCost ? knownCostUSD : nil }
    var threadCount: Int = 0
    var lastActiveAt: Date?
    var sourceQuality: UsageSourceQuality = .detailed

    init(_ project: ProjectUsage) {
        id = project.id
        name = project.name
        fullPath = project.fullPath
    }

    mutating func add(_ project: ProjectUsage) {
        tokens += project.tokens
        if let cost = project.estimatedCostUSD {
            knownCostUSD += cost
        } else {
            hasEstimatedCost = false
        }
        threadCount += project.threadCount
        lastActiveAt = maxDate(lastActiveAt, project.lastActiveAt)
        if project.sourceQuality == .approximate {
            sourceQuality = .approximate
        }
    }

    func makeProject() -> ProjectUsage {
        ProjectUsage(
            id: id,
            name: name,
            fullPath: fullPath,
            tokens: tokens,
            estimatedCostUSD: estimatedCostUSD,
            threadCount: max(threadCount, 1),
            lastActiveAt: lastActiveAt,
            sourceQuality: sourceQuality
        )
    }
}

private func addOptional(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
    guard let lhs, let rhs else { return nil }
    let sum = lhs.addingReportingOverflow(rhs)
    return sum.overflow ? nil : sum.partialValue
}

private func addOptional(_ lhs: Double?, _ rhs: Double?) -> Double? {
    guard let lhs, let rhs else { return nil }
    return lhs + rhs
}

private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
    switch (lhs, rhs) {
    case let (left?, right?):
        return max(left, right)
    case let (left?, nil):
        return left
    case let (nil, right?):
        return right
    case (nil, nil):
        return nil
    }
}
