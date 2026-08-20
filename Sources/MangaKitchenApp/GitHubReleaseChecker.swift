import Foundation

struct GitHubReleaseUpdate: Encodable, Equatable, Sendable {
    var tag: String
    var version: String
    var build: Int?
    var name: String
    var releaseURL: String
    var publishedAt: String?

    var displayVersion: String {
        build.map { "\(version) build \($0)" } ?? version
    }
}

struct GitHubReleaseChecker: Sendable {
    private static let repositoryOwner = "VaderChen"
    private static let repositoryName = "MangaKitchen"
    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/VaderChen/MangaKitchen/releases/latest"
    )!

    private struct ReleaseResponse: Decodable {
        var tagName: String
        var name: String?
        var htmlURL: URL
        var draft: Bool
        var prerelease: Bool
        var publishedAt: String?

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case draft
            case prerelease
            case publishedAt = "published_at"
        }
    }

    private struct ParsedVersion: Sendable {
        var marketingVersion: String
        var build: Int?
    }

    func availableUpdate() async throws -> GitHubReleaseUpdate? {
        let currentVersion = Self.currentVersion
        var request = URLRequest(
            url: Self.latestReleaseURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 8
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(
            "MangaKitchen/\(currentVersion.marketingVersion)",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GitHubReleaseCheckError.invalidResponse
        }
        let release = try JSONDecoder().decode(ReleaseResponse.self, from: data)
        guard !release.draft, !release.prerelease,
              Self.isAllowedReleaseURL(release.htmlURL),
              let latestVersion = Self.parse(tag: release.tagName),
              Self.isNewer(latestVersion, than: currentVersion) else {
            return nil
        }
        return GitHubReleaseUpdate(
            tag: release.tagName,
            version: latestVersion.marketingVersion,
            build: latestVersion.build,
            name: release.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? release.tagName,
            releaseURL: release.htmlURL.absoluteString,
            publishedAt: release.publishedAt
        )
    }

    private static var currentVersion: ParsedVersion {
        let marketingVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.1.0"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            .flatMap(Int.init)
        return ParsedVersion(marketingVersion: marketingVersion, build: build)
    }

    private static func parse(tag: String) -> ParsedVersion? {
        var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first?.lowercased() == "v" {
            value.removeFirst()
        }
        let buildRange = value.range(of: "-build-", options: .caseInsensitive)
        let version = buildRange.map { String(value[..<$0.lowerBound]) } ?? value
        let build = buildRange.flatMap { Int(value[$0.upperBound...]) }
        guard !version.isEmpty, !numericComponents(version).isEmpty else { return nil }
        return ParsedVersion(marketingVersion: version, build: build)
    }

    private static func isNewer(_ candidate: ParsedVersion, than current: ParsedVersion) -> Bool {
        let candidateComponents = numericComponents(candidate.marketingVersion)
        let currentComponents = numericComponents(current.marketingVersion)
        let count = max(candidateComponents.count, currentComponents.count)
        for index in 0..<count {
            let candidateValue = index < candidateComponents.count ? candidateComponents[index] : 0
            let currentValue = index < currentComponents.count ? currentComponents[index] : 0
            if candidateValue != currentValue { return candidateValue > currentValue }
        }
        guard let candidateBuild = candidate.build else { return false }
        return candidateBuild > (current.build ?? 0)
    }

    private static func numericComponents(_ value: String) -> [Int] {
        value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    private static func isAllowedReleaseURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com" else { return false }
        let requiredPrefix = "/\(repositoryOwner)/\(repositoryName)/releases/"
        return url.path.lowercased().hasPrefix(requiredPrefix.lowercased())
    }
}

private enum GitHubReleaseCheckError: Error {
    case invalidResponse
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
