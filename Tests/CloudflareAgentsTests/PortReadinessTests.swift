import XCTest

final class PortReadinessTests: XCTestCase {
    func testManifestScoresStayAboveCurrentBaseline() throws {
        let manifest = try loadManifest()

        let swiftClient = score(manifest, scope: "swiftClient")
        let fullUpstream = score(manifest, scope: "fullUpstreamSdk")

        XCTAssertGreaterThanOrEqual(swiftClient.percent, 0.75)
        XCTAssertGreaterThanOrEqual(fullUpstream.percent, 0.30)
    }

    func testPortedItemsHaveEvidenceAndUpstreamReferences() throws {
        let manifest = try loadManifest()

        for item in manifest.items where item.status == "ported" {
            XCTAssertFalse(item.evidence.isEmpty, "\(item.id) is ported but has no local evidence")
            XCTAssertFalse(item.upstreamRefs.isEmpty, "\(item.id) is ported but has no upstream references")
        }
    }

    func testSwiftClientItemsHavePositiveWeightsAndCoverageInRange() throws {
        let manifest = try loadManifest()
        let swiftItems = manifest.items.filter { $0.scopes.contains("swiftClient") }

        XCTAssertFalse(swiftItems.isEmpty)
        for item in swiftItems {
            XCTAssertGreaterThan(item.weight, 0, "\(item.id) must have a positive weight")
            XCTAssertGreaterThanOrEqual(item.coverage, 0, "\(item.id) coverage must be >= 0")
            XCTAssertLessThanOrEqual(item.coverage, 1, "\(item.id) coverage must be <= 1")
        }
    }

    func testReadmeMentionsManifestUpstreamVersion() throws {
        let manifest = try loadManifest()
        let readme = try String(contentsOf: packageRoot.appendingPathComponent("README.md"))

        XCTAssertTrue(
            readme.contains("v\(manifest.generatedFrom.upstreamVersion)"),
            "README should mention the current upstream target version"
        )
    }

    private func loadManifest() throws -> PortReadinessManifest {
        let url = packageRoot.appendingPathComponent("PortReadiness/port-readiness.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PortReadinessManifest.self, from: data)
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func score(_ manifest: PortReadinessManifest, scope: String) -> (covered: Double, total: Double, percent: Double) {
        let items = manifest.items.filter { $0.scopes.contains(scope) }
        let total = items.reduce(0) { $0 + $1.weight }
        let covered = items.reduce(0) { $0 + $1.weight * $1.coverage }
        return (covered, total, total == 0 ? 0 : covered / total)
    }
}

private struct PortReadinessManifest: Decodable {
    let generatedFrom: PortReadinessGeneratedFrom
    let items: [PortReadinessItem]
}

private struct PortReadinessGeneratedFrom: Decodable {
    let upstreamVersion: String
}

private struct PortReadinessItem: Decodable {
    let id: String
    let scopes: [String]
    let status: String
    let coverage: Double
    let weight: Double
    let upstreamRefs: [String]
    let evidence: [String]
}
