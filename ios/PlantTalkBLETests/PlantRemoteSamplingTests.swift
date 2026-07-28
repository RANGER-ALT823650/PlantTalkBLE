import Foundation
import XCTest
@testable import PlantTalkBLE

/// 远程采样（云端指令信箱）客户端的解析与配置测试。
///
/// 网络往返不在这里测：那需要跑起真实的 FC 与 ESP32。这里锁定的是
/// 最容易静默出错的部分——状态判定与数值解码。
final class PlantRemoteSamplingTests: XCTestCase {

    // MARK: - 配置

    private func makeDefaults(
        url: String? = "https://example.fcapp.run",
        token: String? = "token",
        deviceID: String? = nil
    ) -> UserDefaults {
        let suiteName = "remote-sampling-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        if let url { defaults.set(url, forKey: PlantRemoteSampling.urlDefaultsKey) }
        if let token { defaults.set(token, forKey: PlantRemoteSampling.tokenDefaultsKey) }
        if let deviceID { defaults.set(deviceID, forKey: PlantRemoteSampling.deviceIDDefaultsKey) }
        return defaults
    }

    func testConfigurationFallsBackToSharedDeviceID() throws {
        let config = try XCTUnwrap(
            PlantRemoteSampling.loadConfiguration(from: makeDefaults())
        )
        XCTAssertEqual(config.deviceID, PlantRemoteSampling.fallbackDeviceID)
        XCTAssertEqual(config.token, "token")
    }

    func testConfigurationUsesExplicitDeviceID() throws {
        let config = try XCTUnwrap(
            PlantRemoteSampling.loadConfiguration(from: makeDefaults(deviceID: "balcony-01"))
        )
        XCTAssertEqual(config.deviceID, "balcony-01")
    }

    func testConfigurationRequiresToken() {
        // 云端强制校验 AUTH_TOKEN，没有密钥的请求必被拒。
        // 在这里就判定为未配置，比发出去再收 401 更早给出可行的提示。
        XCTAssertNil(PlantRemoteSampling.loadConfiguration(from: makeDefaults(token: "")))
        XCTAssertNil(PlantRemoteSampling.loadConfiguration(from: makeDefaults(token: nil)))
    }

    func testConfigurationRequiresURL() {
        XCTAssertNil(PlantRemoteSampling.loadConfiguration(from: makeDefaults(url: "")))
        XCTAssertNil(PlantRemoteSampling.loadConfiguration(from: makeDefaults(url: nil)))
    }

    func testBlankDeviceIDFallsBackInsteadOfSendingEmptyString() throws {
        let config = try XCTUnwrap(
            PlantRemoteSampling.loadConfiguration(from: makeDefaults(deviceID: "   "))
        )
        XCTAssertEqual(config.deviceID, PlantRemoteSampling.fallbackDeviceID)
    }

    // MARK: - 状态判定

    func testCompletedStatusYieldsReading() throws {
        let outcome = PlantRemoteSampling.parseStatus([
            "status": "completed",
            "reading": [
                "recordedAt": 1_700_000_000_000,
                "soilRaw": 1234,
                "temperature": 21.5,
                "humidity": 40.0,
                "lightLux": 300.0
            ]
        ])
        guard case .completed(let reading) = outcome else {
            return XCTFail("期望 completed，实际 \(outcome)")
        }
        XCTAssertEqual(reading.soilRaw, 1234)
        XCTAssertEqual(reading.temperature ?? 0, 21.5, accuracy: 0.001)
        XCTAssertEqual(reading.lightLux ?? 0, 300, accuracy: 0.001)
        XCTAssertEqual(reading.receivedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    func testExpiredStatusSurfacesCloudReason() throws {
        let outcome = PlantRemoteSampling.parseStatus([
            "status": "expired",
            "error": "设备未在有效期内取走该指令，请确认 ESP32 已联网。"
        ])
        guard case .expired(let reason) = outcome else {
            return XCTFail("期望 expired，实际 \(outcome)")
        }
        // 过期必须与"还在等"区分开：混淆会让用户白等满超时，
        // 且拿到的提示指向错误的排查方向。
        XCTAssertTrue(reason.contains("联网"))
    }

    func testExpiredWithoutReasonStillExplainsItself() throws {
        let outcome = PlantRemoteSampling.parseStatus(["status": "expired"])
        guard case .expired(let reason) = outcome else {
            return XCTFail("期望 expired，实际 \(outcome)")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testPendingStatusKeepsWaiting() {
        XCTAssertEqual(PlantRemoteSampling.parseStatus(["status": "pending"]), .pending)
        XCTAssertEqual(PlantRemoteSampling.parseStatus([:]), .pending)
    }

    func testNotFoundIsDistinctFromPending() {
        XCTAssertEqual(PlantRemoteSampling.parseStatus(["status": "not_found"]), .notFound)
    }

    func testCompletedWithoutUsableReadingKeepsWaiting() {
        // 云端标了 completed 却没有可用读数时继续等，比立刻抛一个
        // 说不清缘由的错更有机会在下一次轮询拿到数据。
        XCTAssertEqual(PlantRemoteSampling.parseStatus(["status": "completed"]), .pending)
        XCTAssertEqual(
            PlantRemoteSampling.parseStatus(["status": "completed", "reading": [:]]),
            .pending
        )
    }

    // MARK: - 读数解码

    func testIntegerAndDecimalMetricsBothDecode() throws {
        // JSONSerialization 把整数解成 Int、小数解成 Double。
        // 只按其中一种取值，另一种会静默变成 nil。
        let reading = try XCTUnwrap(PlantRemoteSampling.parseReading([
            "recordedAt": 1_700_000_000_000,
            "soilRaw": 2000,
            "temperature": 22,      // 整数形式的温度
            "humidity": 41.25,      // 小数形式的湿度
            "lightLux": 150
        ]))
        XCTAssertEqual(reading.temperature ?? 0, 22, accuracy: 0.001)
        XCTAssertEqual(reading.humidity ?? 0, 41.25, accuracy: 0.001)
        XCTAssertEqual(reading.lightLux ?? 0, 150, accuracy: 0.001)
    }

    func testNullMetricsBecomeNilRatherThanZero() throws {
        // 固件对不可用的传感器上传 null。若解成 0，模型会把
        // "传感器坏了"讲成"光照 0 lux，环境很暗"。
        let reading = try XCTUnwrap(PlantRemoteSampling.parseReading([
            "recordedAt": 1_700_000_000_000,
            "soilRaw": 1500,
            "temperature": NSNull(),
            "humidity": NSNull(),
            "lightLux": NSNull()
        ]))
        XCTAssertNil(reading.temperature)
        XCTAssertNil(reading.humidity)
        XCTAssertNil(reading.lightLux)
        XCTAssertEqual(reading.soilRaw, 1500)
    }

    func testSnakeCaseKeysAreAccepted() throws {
        let reading = try XCTUnwrap(PlantRemoteSampling.parseReading([
            "recorded_at": 1_700_000_000_000,
            "soil_raw": 900,
            "light_lux": 42.5
        ]))
        XCTAssertEqual(reading.soilRaw, 900)
        XCTAssertEqual(reading.lightLux ?? 0, 42.5, accuracy: 0.001)
    }

    func testReadingWithoutTimestampIsRejected() {
        // 没有时间戳就无法判断读数的新鲜度，当作不可用而不是记成"现在"。
        XCTAssertNil(PlantRemoteSampling.parseReading(["soilRaw": 100]))
    }

    func testOutOfRangeSoilValueIsClamped() throws {
        let reading = try XCTUnwrap(PlantRemoteSampling.parseReading([
            "recordedAt": 1_700_000_000_000,
            "soilRaw": 999_999
        ]))
        XCTAssertEqual(reading.soilRaw, UInt16.max)
    }

    // MARK: - commandId 解析

    func testCommandIDAcceptsBothCasings() {
        XCTAssertEqual(PlantRemoteSampling.parseCommandID(["commandId": "cmd_1"]), "cmd_1")
        XCTAssertEqual(PlantRemoteSampling.parseCommandID(["command_id": "cmd_2"]), "cmd_2")
        XCTAssertNil(PlantRemoteSampling.parseCommandID(["commandId": ""]))
        XCTAssertNil(PlantRemoteSampling.parseCommandID([:]))
    }

    // MARK: - HTTP 状态码

    private func response(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.fcapp.run")!,
            statusCode: code,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    func testUnauthorizedIsReportedAsCredentialProblem() {
        // 旧实现不看状态码，401 会被当成"设备没回应"，
        // 用户按提示去查 ESP32 的 Wi-Fi，方向完全错了。
        XCTAssertThrowsError(
            try PlantRemoteSampling.validate(response: response(401), data: Data())
        ) { error in
            guard case PlantRemoteSampling.Failure.unauthorized = error else {
                return XCTFail("期望 unauthorized，实际 \(error)")
            }
        }
    }

    func testServiceUnavailableCarriesCloudHint() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "error": "Service Unavailable: 未配置 AUTH_TOKEN，接口已停止服务。"
        ])
        XCTAssertThrowsError(
            try PlantRemoteSampling.validate(response: response(503), data: body)
        ) { error in
            guard case PlantRemoteSampling.Failure.serverUnavailable(let reason) = error else {
                return XCTFail("期望 serverUnavailable，实际 \(error)")
            }
            XCTAssertTrue(reason.contains("AUTH_TOKEN"))
        }
    }

    func testSuccessfulResponsePasses() throws {
        XCTAssertNoThrow(try PlantRemoteSampling.validate(response: response(200), data: Data()))
    }
}
