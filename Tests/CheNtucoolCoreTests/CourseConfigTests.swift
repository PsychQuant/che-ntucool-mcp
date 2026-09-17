import XCTest
@testable import CheNtucoolCore

final class CourseConfigTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("che-ntucool-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ json: String, name: String = "ntucool.json") throws -> String {
        let url = tmp.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        return url.path
    }

    func testDecodesFullConfig() throws {
        let path = try write("""
        {
          "course_id": 64652,
          "modules": { "W01": 946894, "W02": 946895 },
          "title_formats": { "quiz": "W{week} 隨堂測驗", "slides": "W{week} 投影片" },
          "timezone": "+08:00"
        }
        """)
        let config = try CourseConfig.load(explicitPath: path, environment: [:], cwd: "/nonexistent")
        XCTAssertEqual(config.courseId, 64652)
        XCTAssertEqual(config.modules["W01"], 946894)
        XCTAssertEqual(config.titleFormats?["quiz"], "W{week} 隨堂測驗")
        XCTAssertEqual(config.timezone, "+08:00")
    }

    func testTimezoneDefaultsToTaipei() throws {
        let path = try write(#"{"course_id": 1, "modules": {}}"#)
        let config = try CourseConfig.load(explicitPath: path, environment: [:], cwd: "/nonexistent")
        XCTAssertEqual(config.timezone, "+08:00")
        XCTAssertNil(config.titleFormats)
    }

    func testExplicitPathBeatsEnvBeatsCwd() throws {
        let explicit = try write(#"{"course_id": 1, "modules": {}}"#, name: "a.json")
        let env = try write(#"{"course_id": 2, "modules": {}}"#, name: "b.json")
        _ = try write(#"{"course_id": 3, "modules": {}}"#)   // ./ntucool.json in tmp

        XCTAssertEqual(
            try CourseConfig.load(explicitPath: explicit, environment: ["CHE_NTUCOOL_CONFIG": env], cwd: tmp.path).courseId, 1
        )
        XCTAssertEqual(
            try CourseConfig.load(explicitPath: nil, environment: ["CHE_NTUCOOL_CONFIG": env], cwd: tmp.path).courseId, 2
        )
        XCTAssertEqual(
            try CourseConfig.load(explicitPath: nil, environment: [:], cwd: tmp.path).courseId, 3
        )
    }

    func testMissingEverywhereThrowsExplainingWhereItLooked() {
        XCTAssertThrowsError(try CourseConfig.load(explicitPath: nil, environment: [:], cwd: tmp.path)) { error in
            guard case CourseConfigError.notFound(let searched) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(searched, [tmp.appendingPathComponent("ntucool.json").path])
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("--config"), text)
            XCTAssertTrue(text.contains("CHE_NTUCOOL_CONFIG"), text)
            XCTAssertTrue(text.contains("ntucool.json"), text)
        }
    }

    func testExplicitPathThatDoesNotExistIsAnError() {
        let ghost = tmp.appendingPathComponent("ghost.json").path
        XCTAssertThrowsError(try CourseConfig.load(explicitPath: ghost, environment: [:], cwd: tmp.path)) { error in
            guard case CourseConfigError.notFound(let searched) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(searched, [ghost])
        }
    }

    func testMalformedJSONIsAnInvalidError() throws {
        let path = try write(#"{"course_id": "not a number"}"#)
        XCTAssertThrowsError(try CourseConfig.load(explicitPath: path, environment: [:], cwd: "/nonexistent")) { error in
            guard case CourseConfigError.invalid(let at, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(at, path)
        }
    }
}
