import CoreBluetooth
import Foundation
import Observation

@MainActor
@Observable
final class PlantBluetoothManager: NSObject {
    private enum ControlWriteCompletion {
        case none
        case startHistorySync
        case requestNext(after: UInt32)
        case complete(totalStored: Int)
        case requestImmediateSample(timeout: TimeInterval)
    }

    private struct ControlWrite {
        let data: Data
        let completion: ControlWriteCompletion
    }

    enum ConnectionState: Equatable {
        case bluetoothUnavailable(String)
        case idle
        case scanning
        case connecting
        case connected
        case error(String)

        var title: String {
            switch self {
            case .bluetoothUnavailable(let reason): reason
            case .idle: "未连接"
            case .scanning: "正在搜索 Plant Sensor…"
            case .connecting: "正在连接…"
            case .connected: "已连接"
            case .error(let message): message
            }
        }
    }

    enum HistorySyncState: Equatable {
        case unavailable
        case idle
        case preparing
        case downloading(received: Int)
        case saving(count: Int)
        case completed(totalStored: Int)
        case error(String)

        var title: String {
            switch self {
            case .unavailable: "当前固件不支持历史同步"
            case .idle: "等待连接后同步"
            case .preparing: "正在读取同步游标…"
            case .downloading(let received): "已接收本批 \(received) 条"
            case .saving(let count): "正在保存 \(count) 条历史记录…"
            case .completed(let totalStored): "同步完成，本机共 \(totalStored) 条"
            case .error(let message): "历史同步失败：\(message)"
            }
        }

        var isActive: Bool {
            switch self {
            case .preparing, .downloading, .saving: true
            default: false
            }
        }
    }

    enum ImmediateSampleError: LocalizedError {
        case notReady
        case alreadyInProgress
        case timedOut
        case disconnected
        case commandFailed(String)
        case firmwareRejected(code: UInt16)

        var errorDescription: String? {
            switch self {
            case .notReady:
                "尚未连接到可立即采样的植物设备。"
            case .alreadyInProgress:
                "已有一次立即采样正在等待结果。"
            case .timedOut:
                "ESP32 未在 8 秒内返回新的实时读数。"
            case .disconnected:
                "等待立即采样结果时 BLE 已断开。"
            case .commandFailed(let message):
                "发送立即采样命令失败：\(message)"
            case .firmwareRejected(let code):
                "ESP32 拒绝立即采样命令（错误码 \(code)）；请确认已烧录支持命令 0x13 的固件。"
            }
        }
    }

    private static let serviceUUID = CBUUID(string: "7A1E0001-7C6D-4A8B-9E1F-2D3C4B5A6000")
    private static let dataCharacteristicUUID = CBUUID(string: "7A1E0002-7C6D-4A8B-9E1F-2D3C4B5A6000")
    private static let controlCharacteristicUUID = CBUUID(string: "7A1E0003-7C6D-4A8B-9E1F-2D3C4B5A6000")
    private static let historyCharacteristicUUID = CBUUID(string: "7A1E0004-7C6D-4A8B-9E1F-2D3C4B5A6000")

    private let database: PlantDatabase?
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var dataCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var historyCharacteristic: CBCharacteristic?
    private var historyBatch: [HistoryReading] = []
    private var historyBatchRejection: String?
    private var requestedAfterSequence: UInt32 = 0
    private var activeControlWrite: ControlWrite?
    private var queuedControlWrites: [ControlWrite] = []
    @ObservationIgnored private var scanTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var historySyncTask: Task<Void, Never>?
    @ObservationIgnored private var immediateReadingTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var immediateReadingContinuation: CheckedContinuation<PlantReading, Error>?
    @ObservationIgnored private var immediateReadingRequestSentAt: Date?
    /// Records one explicit user request made while CoreBluetooth is still
    /// becoming ready. It is cleared as soon as scanning starts, so the iOS app
    /// never reconnects in the background and races the website for the ESP32.
    @ObservationIgnored private var connectWhenBluetoothIsReady = false
    @ObservationIgnored private var lastKnownDeviceID: String?

    private(set) var state: ConnectionState = .idle
    private(set) var reading: PlantReading?
    private(set) var historySyncState: HistorySyncState = .idle

    /// Keeps historical tools scoped to the last plant device even after BLE
    /// disconnects. Live tools still require `state == .connected`.
    var currentOrLastKnownDeviceID: String? {
        peripheral?.identifier.uuidString ?? lastKnownDeviceID
    }

    /// A live reading can only be used for the device currently connected in
    /// this process. Historical conversations retain their separately bound ID.
    var connectedDeviceID: String? {
        guard state == .connected else { return nil }
        return peripheral?.identifier.uuidString
    }

    init(database: PlantDatabase? = nil) {
        self.database = database
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func connect() {
        guard centralManager.state == .poweredOn else {
            connectWhenBluetoothIsReady = true
            updateBluetoothState(centralManager.state)
            return
        }

        connectWhenBluetoothIsReady = false
        disconnect(resetState: false)
        state = .scanning
        // 不在系统扫描阶段限定 Service UUID。部分 ESP32 BLE 栈会把完整
        // 128-bit UUID 放入 scan response，iOS 的服务过滤可能因此漏掉设备。
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.state == .scanning else { return }
            self.centralManager.stopScan()
            self.state = .error("未找到 Plant Sensor，请检查 ESP32 BLE 固件")
        }
    }

    func disconnect() {
        connectWhenBluetoothIsReady = false
        disconnect(resetState: true)
    }

    /// Takes one extra sample without changing the firmware's normal
    /// five-minute schedule. Completion waits for a new live notification,
    /// not merely for CoreBluetooth to acknowledge the control write.
    func requestImmediateReading(timeout: TimeInterval = 8) async throws -> PlantReading {
        guard state == .connected,
              peripheral != nil,
              dataCharacteristic != nil,
              controlCharacteristic != nil else {
            throw ImmediateSampleError.notReady
        }
        guard immediateReadingContinuation == nil else {
            throw ImmediateSampleError.alreadyInProgress
        }

        return try await withCheckedThrowingContinuation { continuation in
            immediateReadingContinuation = continuation
            enqueueControlWrite(
                HistoryTransferProtocol.makeImmediateSampleRequest(),
                completion: .requestImmediateSample(timeout: timeout)
            )
        }
    }

    private func disconnect(resetState: Bool) {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        historySyncTask?.cancel()
        historySyncTask = nil
        failImmediateReading(with: ImmediateSampleError.disconnected)
        centralManager.stopScan()
        if let peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        dataCharacteristic = nil
        controlCharacteristic = nil
        historyCharacteristic = nil
        historyBatch.removeAll(keepingCapacity: true)
        historyBatchRejection = nil
        activeControlWrite = nil
        queuedControlWrites.removeAll(keepingCapacity: true)
        historySyncState = .idle
        if resetState {
            state = .idle
        }
    }

    func retryHistorySync() {
        guard state == .connected else { return }
        synchronizeHistoryAfterLiveReading()
    }

    private func updateBluetoothState(_ bluetoothState: CBManagerState) {
        switch bluetoothState {
        case .poweredOn:
            if case .bluetoothUnavailable = state { state = .idle }
            if connectWhenBluetoothIsReady,
               state != .scanning,
               state != .connecting,
               state != .connected {
                connect()
            }
        case .poweredOff:
            state = .bluetoothUnavailable("蓝牙已关闭")
        case .unauthorized:
            state = .bluetoothUnavailable("没有蓝牙权限")
        case .unsupported:
            state = .bluetoothUnavailable("此设备不支持 BLE")
        case .resetting:
            state = .bluetoothUnavailable("蓝牙正在重置")
        case .unknown:
            state = .bluetoothUnavailable("正在检查蓝牙状态")
        @unknown default:
            state = .bluetoothUnavailable("未知蓝牙状态")
        }
    }
}

extension PlantBluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            updateBluetoothState(central.state)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let isPlantSensor = localName == "Plant Sensor"
                || peripheral.name == "Plant Sensor"
                || advertisedServices.contains(Self.serviceUUID)

            guard isPlantSensor else { return }

            scanTimeoutTask?.cancel()
            scanTimeoutTask = nil
            central.stopScan()
            self.peripheral = peripheral
            lastKnownDeviceID = peripheral.identifier.uuidString
            peripheral.delegate = self
            state = .connecting
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            state = .connected
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            failImmediateReading(with: ImmediateSampleError.disconnected)
            state = .error("连接失败：\(error?.localizedDescription ?? "未知错误")")
            self.peripheral = nil
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            failImmediateReading(with: ImmediateSampleError.disconnected)
            self.peripheral = nil
            dataCharacteristic = nil
            controlCharacteristic = nil
            historyCharacteristic = nil
            historySyncTask?.cancel()
            historySyncTask = nil
            historyBatch.removeAll(keepingCapacity: true)
            historyBatchRejection = nil
            activeControlWrite = nil
            queuedControlWrites.removeAll(keepingCapacity: true)
            historySyncState = .idle
            state = error == nil ? .idle : .error("连接已断开")

        }
    }
}

extension PlantBluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                state = .error("读取服务失败：\(error.localizedDescription)")
                return
            }
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                state = .error("找不到植物传感器服务")
                return
            }
            peripheral.discoverCharacteristics([
                Self.dataCharacteristicUUID,
                Self.controlCharacteristicUUID,
                Self.historyCharacteristicUUID
            ], for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if let error {
                state = .error("读取特征失败：\(error.localizedDescription)")
                return
            }
            guard let characteristics = service.characteristics,
                  let characteristic = characteristics.first(where: {
                $0.uuid == Self.dataCharacteristicUUID
            }) else {
                state = .error("找不到传感器数据特征")
                return
            }

            dataCharacteristic = characteristic
            controlCharacteristic = characteristics.first { $0.uuid == Self.controlCharacteristicUUID }
            historyCharacteristic = characteristics.first { $0.uuid == Self.historyCharacteristicUUID }
            peripheral.setNotifyValue(true, for: characteristic)
            peripheral.readValue(for: characteristic)

            if let historyCharacteristic, controlCharacteristic != nil, database != nil {
                historySyncState = .idle
                enqueueControlWrite(
                    HistoryTransferProtocol.makeSetUnixTime(),
                    completion: .startHistorySync
                )
                peripheral.setNotifyValue(true, for: historyCharacteristic)
            } else {
                historySyncState = .unavailable
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == Self.historyCharacteristicUUID else { return }
            if let error {
                historySyncState = .error("无法订阅历史数据：\(error.localizedDescription)")
                return
            }
            guard characteristic.isNotifying else {
                historySyncState = .error("设备拒绝历史数据通知")
                return
            }
            synchronizeHistoryAfterLiveReading()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if let error {
                if characteristic.uuid == Self.historyCharacteristicUUID {
                    historySyncState = .error("读取历史数据失败：\(error.localizedDescription)")
                } else {
                    state = .error("读取数据失败：\(error.localizedDescription)")
                }
                return
            }
            guard let data = characteristic.value else { return }

            if characteristic.uuid == Self.historyCharacteristicUUID {
                handleHistoryPacket(data)
                return
            }

            if characteristic.uuid == Self.dataCharacteristicUUID {
                guard let decoded = PlantPacketDecoder.decode(data) else {
                    state = .error("收到无法识别的实时数据包")
                    return
                }
                reading = decoded
                state = .connected
                completeImmediateReadingIfNeeded(with: decoded)
                synchronizeHistoryAfterLiveReading()
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == Self.controlCharacteristicUUID,
                  let completedWrite = activeControlWrite else { return }
            activeControlWrite = nil

            if let error {
                queuedControlWrites.removeAll(keepingCapacity: true)
                failImmediateReading(with: ImmediateSampleError.commandFailed(error.localizedDescription))
                historySyncState = .error("发送同步命令失败：\(error.localizedDescription)")
                return
            }

            switch completedWrite.completion {
            case .none:
                break
            case .startHistorySync:
                synchronizeHistoryAfterLiveReading()
            case .requestNext(let sequence):
                requestHistory(after: sequence)
            case .complete(let totalStored):
                historySyncState = .completed(totalStored: totalStored)
            case .requestImmediateSample(let timeout):
                beginWaitingForImmediateReading(timeout: timeout)
            }
            sendNextControlWriteIfNeeded()
        }
    }
}

private extension PlantBluetoothManager {
    func synchronizeHistoryAfterLiveReading() {
        guard state == .connected,
              !historySyncState.isActive,
              historySyncTask == nil,
              activeControlWrite == nil,
              queuedControlWrites.isEmpty else {
            return
        }
        startHistorySync()
    }

    func startHistorySync() {
        guard let database,
              let peripheral,
              controlCharacteristic != nil,
              historyCharacteristic?.isNotifying == true else {
            return
        }

        historySyncTask?.cancel()
        historySyncState = .preparing
        let deviceID = peripheral.identifier.uuidString
        historySyncTask = Task { [weak self] in
            do {
                let sequence = try await database.lastSequence(for: deviceID)
                guard !Task.isCancelled else { return }
                self?.historySyncTask = nil
                self?.requestHistory(after: sequence)
            } catch {
                guard !Task.isCancelled else { return }
                self?.historySyncState = .error(error.localizedDescription)
            }
        }
    }

    func requestHistory(after sequence: UInt32) {
        guard peripheral != nil, controlCharacteristic != nil else { return }
        requestedAfterSequence = sequence
        historyBatch.removeAll(keepingCapacity: true)
        historyBatchRejection = nil
        historySyncState = .downloading(received: 0)
        enqueueControlWrite(
            HistoryTransferProtocol.makeRequest(after: sequence),
            completion: .none
        )
    }

    func handleHistoryPacket(_ data: Data) {
        do {
            switch try HistoryTransferProtocol.decode(data) {
            case .record(let reading):
                guard historySyncTask == nil, historyBatchRejection == nil else { return }
                let expectedSequence = historyBatch.last.map { $0.sequence &+ 1 }
                guard expectedSequence.map({ reading.sequence == $0 })
                    ?? (reading.sequence > requestedAfterSequence) else {
                    throw HistoryTransferProtocol.DecodeError.invalidSequence
                }
                historyBatch.append(reading)
                historySyncState = .downloading(received: historyBatch.count)

            case .batchEnd(let end):
                guard historySyncTask == nil else { return }
                if historyBatchRejection != nil {
                    historyBatch.removeAll(keepingCapacity: true)
                    historyBatchRejection = nil
                    return
                }
                try HistoryTransferProtocol.validateBatch(
                    historyBatch,
                    requestedAfterSequence: requestedAfterSequence,
                    endedBy: end
                )
                persistCurrentBatch(end)

            case .failure(let code):
                historyBatch.removeAll(keepingCapacity: true)
                historyBatchRejection = nil
                failImmediateReading(with: ImmediateSampleError.firmwareRejected(code: code))
                historySyncState = .error("ESP32 返回错误码 \(code)")
            }
        } catch {
            rejectCurrentHistoryBatch(error.localizedDescription)
        }
    }

    /// Once any record in a batch is corrupt or discontinuous, later packets
    /// from that same burst must be ignored. Otherwise a valid-looking suffix
    /// could be mistaken for a complete batch after the earlier records were
    /// discarded.
    func rejectCurrentHistoryBatch(_ message: String) {
        historyBatch.removeAll(keepingCapacity: true)
        historyBatchRejection = message
        historySyncState = .error(message)
    }

    func persistCurrentBatch(_ end: HistoryTransferProtocol.BatchEnd) {
        guard let database, let peripheral else { return }
        let batch = historyBatch
        historyBatch.removeAll(keepingCapacity: true)
        historyBatchRejection = nil
        let deviceID = peripheral.identifier.uuidString
        historySyncState = .saving(count: batch.count)

        historySyncTask = Task { [weak self] in
            do {
                let result = try await database.saveHistoryBatch(
                    batch,
                    deviceID: deviceID,
                    acknowledgedThrough: end.lastSequence
                )
                guard !Task.isCancelled, let self else { return }
                self.historySyncTask = nil

                if end.remainingCount > 0 && result.durableSequence < end.newestSequence {
                    self.sendAcknowledgement(
                        through: result.durableSequence,
                        completion: .requestNext(after: result.durableSequence)
                    )
                } else {
                    let total = try await database.readingCount(for: deviceID)
                    guard !Task.isCancelled else { return }
                    self.sendAcknowledgement(
                        through: result.durableSequence,
                        completion: .complete(totalStored: total)
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.historySyncTask = nil
                self?.historySyncState = .error(error.localizedDescription)
            }
        }
    }

    private func sendAcknowledgement(
        through sequence: UInt32,
        completion: ControlWriteCompletion
    ) {
        enqueueControlWrite(
            HistoryTransferProtocol.makeAcknowledgement(through: sequence),
            completion: completion
        )
    }

    private func enqueueControlWrite(_ data: Data, completion: ControlWriteCompletion) {
        queuedControlWrites.append(ControlWrite(data: data, completion: completion))
        sendNextControlWriteIfNeeded()
    }

    func beginWaitingForImmediateReading(timeout: TimeInterval) {
        guard immediateReadingContinuation != nil else { return }
        immediateReadingRequestSentAt = .now
        immediateReadingTimeoutTask?.cancel()
        immediateReadingTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.failImmediateReading(with: ImmediateSampleError.timedOut)
        }
    }

    func completeImmediateReadingIfNeeded(with reading: PlantReading) {
        guard let requestedAt = immediateReadingRequestSentAt,
              reading.receivedAt >= requestedAt else {
            return
        }
        finishImmediateReading(.success(reading))
    }

    func failImmediateReading(with error: Error) {
        finishImmediateReading(.failure(error))
    }

    func finishImmediateReading(_ result: Result<PlantReading, Error>) {
        immediateReadingTimeoutTask?.cancel()
        immediateReadingTimeoutTask = nil
        immediateReadingRequestSentAt = nil
        let continuation = immediateReadingContinuation
        immediateReadingContinuation = nil
        continuation?.resume(with: result)
    }

    func sendNextControlWriteIfNeeded() {
        guard activeControlWrite == nil,
              !queuedControlWrites.isEmpty,
              let peripheral,
              let controlCharacteristic else { return }
        let write = queuedControlWrites.removeFirst()
        activeControlWrite = write
        peripheral.writeValue(write.data, for: controlCharacteristic, type: .withResponse)
    }
}
