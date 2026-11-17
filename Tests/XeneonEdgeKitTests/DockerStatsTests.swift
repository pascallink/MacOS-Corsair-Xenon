// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import XeneonEdgeKit

@Suite struct DockerStatsTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    @Test func parsesMemTotal() {
        #expect(DockerParser.memTotal(fromInfo: data(#"{"MemTotal":16746086400,"x":1}"#)) == 16_746_086_400)
        #expect(DockerParser.memTotal(fromInfo: data("{}")) == nil)
        #expect(DockerParser.memTotal(fromInfo: data("kaputt")) == nil)
    }

    @Test func parsesContainerIDs() {
        let json = #"[{"Id":"abc","Names":["/a"]},{"Id":"def"},{"x":1}]"#
        #expect(DockerParser.containerIDs(fromList: data(json)) == ["abc", "def"])
        #expect(DockerParser.containerIDs(fromList: data("[]")) == [])
        #expect(DockerParser.containerIDs(fromList: data("{}")) == nil)
        #expect(DockerParser.containerIDs(fromList: data("{")) == nil)
    }

    @Test func memoryV2SubtractsInactiveFile() {
        let json = #"{"memory_stats":{"usage":1000,"stats":{"inactive_file":300}}}"#
        #expect(DockerParser.memoryUsed(fromStats: data(json)) == 700)
    }

    @Test func memoryV1UsesTotalInactiveFile() {
        let json = #"{"memory_stats":{"usage":1000,"stats":{"total_inactive_file":400}}}"#
        #expect(DockerParser.memoryUsed(fromStats: data(json)) == 600)
    }

    @Test func memoryWithoutStatsKeepsUsage() {
        #expect(DockerParser.memoryUsed(fromStats: data(#"{"memory_stats":{"usage":500}}"#)) == 500)
    }

    @Test func inactiveLargerThanUsageClampsToZero() {
        let json = #"{"memory_stats":{"usage":100,"stats":{"inactive_file":300}}}"#
        #expect(DockerParser.memoryUsed(fromStats: data(json)) == 0)
    }

    @Test func missingOrBrokenStatsYieldNil() {
        #expect(DockerParser.memoryUsed(fromStats: data("{}")) == nil)
        #expect(DockerParser.memoryUsed(fromStats: data(#"{"memory_stats":{}}"#)) == nil)
        #expect(DockerParser.memoryUsed(fromStats: data("nicht json")) == nil)
    }

    @Test func usageRatios() {
        let u = DockerUsage(memoryUsed: 250, memoryTotal: 1000, diskUsed: 25, diskTotal: 100)
        #expect(u.memoryUsage == 0.25)
        #expect(u.diskUsage == 0.25)
        #expect(DockerUsage().memoryUsage == 0)
        #expect(DockerUsage().diskUsage == 0)
        #expect(DockerUsage(memoryUsed: 5, memoryTotal: 1).memoryUsage == 1)
    }

    @Test func httpBodyNeedsStatus200() {
        let ok = data("HTTP/1.0 200 OK\r\nContent-Type: x\r\n\r\n{\"a\":1}")
        #expect(DockerStatsReader.httpBody(fromResponse: ok) == data(#"{"a":1}"#))
        #expect(DockerStatsReader.httpBody(fromResponse: data("HTTP/1.0 404 Not Found\r\n\r\nx")) == nil)
        #expect(DockerStatsReader.httpBody(fromResponse: data("Muell")) == nil)
    }

    @Test func readerWithoutSocketYieldsNil() {
        let missing = "/does/not/exist/\(UUID().uuidString).sock"
        let reader = DockerStatsReader(socketPaths: [missing], diskImagePath: "/does/not/exist")
        #expect(reader.read() == nil)
        #expect(DockerStatsReader.get("/info", socketPath: missing) == nil)
    }

    @Test func missingDiskImageGivesNoSizes() {
        #expect(DockerStatsReader.imageSizes(at: "/does/not/exist/\(UUID().uuidString)") == nil)
    }

    @Test func oldConfigWithoutDockerKeysDecodesToDefaults() throws {
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(cfg.showDocker == false)
        #expect(cfg.dockerDiskImagePath == "")
    }
}
