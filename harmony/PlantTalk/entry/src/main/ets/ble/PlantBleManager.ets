import {
  abilityAccessCtrl,
  Permissions
} from '@kit.AbilityKit';
import {
  access,
  ble,
  constant
} from '@kit.ConnectivityKit';
import { HistoryRepository } from '../data/HistoryRepository';
import { PlantReading } from '../model/PlantModels';
import {
  HistorySyncCore,
  HistorySyncEffect,
  HistorySyncEffectType
} from './HistorySyncCore';
import {
  PlantBleProtocol,
  PlantGattProfile
} from './PlantBleProtocol';

export enum PlantBleConnectionState {
  IDLE = 'idle',
  REQUESTING_PERMISSION = 'requestingPermission',
  SCANNING = 'scanning',
  CONNECTING = 'connecting',
  DISCOVERING = 'discovering',
  CONNECTED = 'connected',
  UNAVAILABLE = 'unavailable',
  ERROR = 'error'
}

export class PlantBleCallbacks {
  onConnectionStateChanged:
    (state: PlantBleConnectionState, title: string) => void =
    (_state: PlantBleConnectionState, _title: string): void => {};
  onReading: (reading: PlantReading) => void =
    (_reading: PlantReading): void => {};
  onHistoryStateChanged: (title: string) => void =
    (_title: string): void => {};
}

/**
 * User-driven HarmonyOS GATT central for Plant Sensor.
 *
 * The manager never reconnects automatically. A user tap starts one bounded
 * scan, then connects to the first advertisement whose name or raw service
 * UUID identifies Plant Sensor.
 */
export class PlantBleManager {
  private static readonly BLE_PERMISSION: Permissions =
    'ohos.permission.ACCESS_BLUETOOTH';
  private static readonly SCAN_TIMEOUT_MS: number = 12_000;
  private static readonly SERVICE_UUID_LITTLE_ENDIAN: number[] = [
    0x00, 0x60, 0x5A, 0x4B, 0x3C, 0x2D, 0x1F, 0x9E,
    0x8B, 0x4A, 0x6D, 0x7C, 0x01, 0x00, 0x1E, 0x7A
  ];
  private static readonly SERVICE_UUID_BIG_ENDIAN: number[] = [
    0x7A, 0x1E, 0x00, 0x01, 0x7C, 0x6D, 0x4A, 0x8B,
    0x9E, 0x1F, 0x2D, 0x3C, 0x4B, 0x5A, 0x60, 0x00
  ];

  private readonly context: Context;
  private readonly repository: HistoryRepository;
  private readonly callbacks: PlantBleCallbacks;
  private readonly historyCore: HistorySyncCore = new HistorySyncCore();

  private state: PlantBleConnectionState = PlantBleConnectionState.IDLE;
  private operationGeneration: number = 0;
  private scanTimeoutId: number = -1;
  private scanCallbackRegistered: boolean = false;
  private deviceId: string = '';
  private gattClient: ble.GattClientDevice | null = null;
  private liveCharacteristic: ble.BLECharacteristic | null = null;
  private controlCharacteristic: ble.BLECharacteristic | null = null;
  private historyCharacteristic: ble.BLECharacteristic | null = null;
  private historyStartInProgress: boolean = false;
  private historyPackets: Uint8Array[] = [];
  private historyProcessing: boolean = false;

  private readonly scanCallback =
    (results: Array<ble.ScanResult>): void => {
      this.handleScanResults(results);
    };

  private readonly connectionCallback =
    (change: ble.BLEConnectionChangeState): void => {
      this.handleConnectionChange(change);
    };

  private readonly characteristicCallback =
    (characteristic: ble.BLECharacteristic): void => {
      this.handleCharacteristicChange(characteristic);
    };

  constructor(
    context: Context,
    repository: HistoryRepository,
    callbacks: PlantBleCallbacks
  ) {
    this.context = context;
    this.repository = repository;
    this.callbacks = callbacks;
    this.publishConnectionState(
      PlantBleConnectionState.IDLE,
      '未连接'
    );
  }

  get connectionState(): PlantBleConnectionState {
    return this.state;
  }

  async toggleConnection(): Promise<void> {
    if (this.isConnectionAttemptActive()) {
      this.disconnect();
      return;
    }

    const generation = this.beginNewOperation();
    this.publishConnectionState(
      PlantBleConnectionState.REQUESTING_PERMISSION,
      '正在申请蓝牙权限…'
    );

    let permissionGranted = false;
    try {
      permissionGranted = await this.requestBluetoothPermission();
    } catch (error) {
      if (generation === this.operationGeneration) {
        this.publishConnectionState(
          PlantBleConnectionState.ERROR,
          `申请蓝牙权限失败：${PlantBleManager.errorMessage(error)}`
        );
      }
      return;
    }

    if (generation !== this.operationGeneration) {
      return;
    }
    if (!permissionGranted) {
      this.publishConnectionState(
        PlantBleConnectionState.UNAVAILABLE,
        '没有蓝牙权限；可在系统设置中重新授权'
      );
      return;
    }

    let bluetoothState: access.BluetoothState;
    try {
      bluetoothState = access.getState();
    } catch (error) {
      this.publishConnectionState(
        PlantBleConnectionState.ERROR,
        `无法读取蓝牙状态：${PlantBleManager.errorMessage(error)}`
      );
      return;
    }
    if (
      bluetoothState !== access.BluetoothState.STATE_ON &&
      bluetoothState !== access.BluetoothState.STATE_BLE_ON
    ) {
      this.publishConnectionState(
        PlantBleConnectionState.UNAVAILABLE,
        '蓝牙已关闭'
      );
      return;
    }

    this.startScan(generation);
  }

  disconnect(): void {
    this.beginNewOperation();
    this.stopScan();
    this.releaseGattClient();
    this.resetTransferState();
    this.publishConnectionState(
      PlantBleConnectionState.IDLE,
      '未连接'
    );
  }

  private async requestBluetoothPermission(): Promise<boolean> {
    const result = await abilityAccessCtrl
      .createAtManager()
      .requestPermissionsFromUser(
        this.context,
        [PlantBleManager.BLE_PERMISSION]
      );
    return result.authResults.length > 0 &&
      result.authResults[0] ===
        abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  }

  private startScan(generation: number): void {
    this.stopScan();
    try {
      ble.on('BLEDeviceFind', this.scanCallback);
      this.scanCallbackRegistered = true;
      this.publishConnectionState(
        PlantBleConnectionState.SCANNING,
        '正在搜索 Plant Sensor…'
      );
      // Match in the callback instead of applying a service filter. Some ESP32
      // stacks place the 128-bit UUID only in the scan response.
      ble.startBLEScan([]);
      this.scanTimeoutId = setTimeout(() => {
        if (
          generation !== this.operationGeneration ||
          this.state !== PlantBleConnectionState.SCANNING
        ) {
          return;
        }
        this.stopScan();
        this.publishConnectionState(
          PlantBleConnectionState.ERROR,
          '未找到 Plant Sensor，请检查 ESP32 BLE 固件'
        );
      }, PlantBleManager.SCAN_TIMEOUT_MS);
    } catch (error) {
      this.stopScan();
      this.publishConnectionState(
        PlantBleConnectionState.ERROR,
        `启动蓝牙扫描失败：${PlantBleManager.errorMessage(error)}`
      );
    }
  }

  private handleScanResults(results: Array<ble.ScanResult>): void {
    if (this.state !== PlantBleConnectionState.SCANNING) {
      return;
    }
    for (const result of results) {
      const isPlantSensor =
        result.deviceName === PlantGattProfile.DEVICE_NAME ||
        PlantBleManager.containsPlantServiceUuid(result.data);
      if (!isPlantSensor) {
        continue;
      }
      this.connectTo(result.deviceId);
      return;
    }
  }

  private connectTo(deviceId: string): void {
    if (
      this.state !== PlantBleConnectionState.SCANNING ||
      deviceId.length === 0
    ) {
      return;
    }
    this.stopScan();
    this.deviceId = deviceId;
    try {
      const client = ble.createGattClientDevice(deviceId);
      this.gattClient = client;
      client.on('BLEConnectionStateChange', this.connectionCallback);
      this.publishConnectionState(
        PlantBleConnectionState.CONNECTING,
        '正在连接 Plant Sensor…'
      );
      client.connect();
    } catch (error) {
      this.failConnection(
        `连接 Plant Sensor 失败：${PlantBleManager.errorMessage(error)}`
      );
    }
  }

  private handleConnectionChange(
    change: ble.BLEConnectionChangeState
  ): void {
    if (
      this.gattClient === null ||
      change.deviceId !== this.deviceId
    ) {
      return;
    }
    if (
      change.state ===
        constant.ProfileConnectionState.STATE_CONNECTED
    ) {
      const generation = this.operationGeneration;
      this.publishConnectionState(
        PlantBleConnectionState.DISCOVERING,
        '正在读取植物传感器服务…'
      );
      this.discoverServices(generation);
      return;
    }
    if (
      change.state ===
        constant.ProfileConnectionState.STATE_DISCONNECTED
    ) {
      this.releaseGattClient();
      this.resetTransferState();
      this.publishConnectionState(
        PlantBleConnectionState.ERROR,
        'Plant Sensor 连接已断开'
      );
    }
  }

  private async discoverServices(generation: number): Promise<void> {
    const client = this.gattClient;
    if (client === null) {
      return;
    }
    try {
      const services = await client.getServices();
      if (!this.isCurrentOperation(generation, client)) {
        return;
      }
      const service = services.find((candidate: ble.GattService) =>
        PlantBleManager.uuidEquals(
          candidate.serviceUuid,
          PlantGattProfile.SERVICE_UUID
        )
      );
      if (service === undefined) {
        throw new Error('找不到植物传感器服务');
      }

      const live = PlantBleManager.findCharacteristic(
        service,
        PlantGattProfile.LIVE_UUID
      );
      if (live === null) {
        throw new Error('找不到传感器实时数据特征');
      }
      this.liveCharacteristic = live;
      this.controlCharacteristic = PlantBleManager.findCharacteristic(
        service,
        PlantGattProfile.CONTROL_UUID
      );
      this.historyCharacteristic = PlantBleManager.findCharacteristic(
        service,
        PlantGattProfile.HISTORY_UUID
      );

      client.on(
        'BLECharacteristicChange',
        this.characteristicCallback
      );
      await client.setCharacteristicChangeNotification(live, true);
      if (!this.isCurrentOperation(generation, client)) {
        return;
      }

      const history = this.historyCharacteristic;
      if (history !== null && this.controlCharacteristic !== null) {
        await client.setCharacteristicChangeNotification(history, true);
      }
      if (!this.isCurrentOperation(generation, client)) {
        return;
      }

      this.publishConnectionState(
        PlantBleConnectionState.CONNECTED,
        '已连接 Plant Sensor'
      );

      // Read the current live value exactly as the latest iOS app does.
      try {
        const currentValue = await client.readCharacteristicValue(live);
        if (this.isCurrentOperation(generation, client)) {
          this.acceptLiveCharacteristic(currentValue);
        }
      } catch (_readError) {
        // Notifications remain active even when the optional initial read is
        // unsupported by an older firmware revision.
      }

      if (history !== null && this.controlCharacteristic !== null) {
        this.callbacks.onHistoryStateChanged('正在校准设备时间…');
        await this.writeControl(
          PlantBleProtocol.makeSetUnixTime(),
          generation
        );
        if (this.isCurrentOperation(generation, client)) {
          await this.startHistorySync(generation);
        }
      } else {
        this.callbacks.onHistoryStateChanged(
          '当前固件不支持历史同步'
        );
      }
    } catch (error) {
      if (generation === this.operationGeneration) {
        this.failConnection(
          `初始化 Plant Sensor 失败：${PlantBleManager.errorMessage(error)}`
        );
      }
    }
  }

  private handleCharacteristicChange(
    characteristic: ble.BLECharacteristic
  ): void {
    if (
      PlantBleManager.uuidEquals(
        characteristic.characteristicUuid,
        PlantGattProfile.LIVE_UUID
      )
    ) {
      this.acceptLiveCharacteristic(characteristic);
      return;
    }
    if (
      PlantBleManager.uuidEquals(
        characteristic.characteristicUuid,
        PlantGattProfile.HISTORY_UUID
      )
    ) {
      const copiedPacket = PlantBleManager.copyBytes(
        characteristic.characteristicValue
      );
      this.historyPackets.push(copiedPacket);
      this.drainHistoryPackets(this.operationGeneration);
    }
  }

  private acceptLiveCharacteristic(
    characteristic: ble.BLECharacteristic
  ): void {
    try {
      const reading = PlantBleProtocol.decodeLivePacket(
        new Uint8Array(characteristic.characteristicValue)
      );
      this.callbacks.onReading(reading);
      if (this.state === PlantBleConnectionState.CONNECTED) {
        this.publishConnectionState(
          PlantBleConnectionState.CONNECTED,
          '已连接 Plant Sensor'
        );
      }
    } catch (error) {
      this.callbacks.onHistoryStateChanged(
        `实时数据包无效：${PlantBleManager.errorMessage(error)}`
      );
    }
  }

  private async startHistorySync(generation: number): Promise<void> {
    if (
      this.historyStartInProgress ||
      this.state !== PlantBleConnectionState.CONNECTED ||
      this.deviceId.length === 0
    ) {
      return;
    }
    this.historyStartInProgress = true;
    this.historyProcessing = true;
    this.callbacks.onHistoryStateChanged('正在读取同步游标…');
    try {
      const sequence = await this.repository.getLastSequence(this.deviceId);
      if (
        generation !== this.operationGeneration ||
        this.state !== PlantBleConnectionState.CONNECTED
      ) {
        return;
      }
      this.callbacks.onHistoryStateChanged('正在下载历史记录…');
      await this.executeHistoryEffect(
        this.historyCore.begin(sequence),
        generation
      );
    } catch (error) {
      if (generation === this.operationGeneration) {
        this.callbacks.onHistoryStateChanged(
          `历史同步失败：${PlantBleManager.errorMessage(error)}`
        );
      }
    } finally {
      this.historyStartInProgress = false;
      this.historyProcessing = false;
      if (
        generation === this.operationGeneration &&
        this.historyPackets.length > 0
      ) {
        this.drainHistoryPackets(generation);
      }
    }
  }

  private async drainHistoryPackets(generation: number): Promise<void> {
    if (this.historyProcessing) {
      return;
    }
    this.historyProcessing = true;
    try {
      while (
        this.historyPackets.length > 0 &&
        generation === this.operationGeneration &&
        this.gattClient !== null
      ) {
        const packet = this.historyPackets.shift();
        if (packet === undefined) {
          break;
        }
        const effect = this.historyCore.acceptPacket(packet);
        await this.executeHistoryEffect(effect, generation);
      }
    } finally {
      this.historyProcessing = false;
    }
  }

  private async executeHistoryEffect(
    initialEffect: HistorySyncEffect,
    generation: number
  ): Promise<void> {
    let effect = initialEffect;
    while (
      generation === this.operationGeneration &&
      this.gattClient !== null
    ) {
      switch (effect.type) {
        case HistorySyncEffectType.NONE:
          return;

        case HistorySyncEffectType.WRITE_CONTROL:
          if (effect.payload === null) {
            effect = this.historyCore.onControlWriteFailed(
              '同步状态缺少控制命令'
            );
            break;
          }
          try {
            await this.writeControl(effect.payload, generation);
            effect = this.historyCore.onControlWriteSucceeded();
          } catch (error) {
            effect = this.historyCore.onControlWriteFailed(
              PlantBleManager.errorMessage(error)
            );
          }
          break;

        case HistorySyncEffectType.COMMIT_BATCH:
          if (effect.batchEnd === null) {
            effect = this.historyCore.onCommitFailed(
              '同步状态缺少批次结束信息'
            );
            break;
          }
          this.callbacks.onHistoryStateChanged(
            `正在保存 ${effect.readings.length} 条历史记录…`
          );
          try {
            const result = await this.repository.saveHistoryBatch(
              effect.readings,
              this.deviceId,
              effect.batchEnd.lastSequence
            );
            if (generation !== this.operationGeneration) {
              return;
            }
            effect = this.historyCore.onCommitSucceeded(
              result,
              effect.batchEnd
            );
          } catch (error) {
            effect = this.historyCore.onCommitFailed(
              PlantBleManager.errorMessage(error)
            );
          }
          break;

        case HistorySyncEffectType.COMPLETE:
          try {
            const total = await this.repository.getReadingCount(
              this.deviceId
            );
            if (generation === this.operationGeneration) {
              this.callbacks.onHistoryStateChanged(
                `同步完成，本机共 ${total} 条`
              );
            }
          } catch (error) {
            this.callbacks.onHistoryStateChanged(
              `历史同步已提交，但统计失败：${PlantBleManager.errorMessage(error)}`
            );
          }
          return;

        case HistorySyncEffectType.REJECT_BATCH:
          this.callbacks.onHistoryStateChanged(
            `历史同步失败：${effect.message}`
          );
          return;

        default:
          return;
      }
    }
  }

  private async writeControl(
    payload: Uint8Array,
    generation: number
  ): Promise<void> {
    const client = this.gattClient;
    const characteristic = this.controlCharacteristic;
    if (
      client === null ||
      characteristic === null ||
      generation !== this.operationGeneration
    ) {
      throw new Error('BLE 控制特征当前不可用');
    }
    const exactBuffer = new ArrayBuffer(payload.byteLength);
    const exactBytes = new Uint8Array(exactBuffer);
    exactBytes.set(payload);
    characteristic.characteristicValue = exactBuffer;
    await client.writeCharacteristicValue(
      characteristic,
      ble.GattWriteType.WRITE
    );
    if (!this.isCurrentOperation(generation, client)) {
      throw new Error('BLE 连接已结束');
    }
  }

  private failConnection(message: string): void {
    this.stopScan();
    this.releaseGattClient();
    this.resetTransferState();
    this.publishConnectionState(
      PlantBleConnectionState.ERROR,
      message
    );
  }

  private stopScan(): void {
    if (this.scanTimeoutId >= 0) {
      clearTimeout(this.scanTimeoutId);
      this.scanTimeoutId = -1;
    }
    try {
      ble.stopBLEScan();
    } catch (_error) {
      // stopBLEScan can fail when no system scan is active.
    }
    if (this.scanCallbackRegistered) {
      try {
        ble.off('BLEDeviceFind', this.scanCallback);
      } catch (_error) {
        // Callback cleanup is best-effort after a failed scan start.
      }
      this.scanCallbackRegistered = false;
    }
  }

  private releaseGattClient(): void {
    const client = this.gattClient;
    this.gattClient = null;
    if (client !== null) {
      try {
        client.off(
          'BLECharacteristicChange',
          this.characteristicCallback
        );
      } catch (_error) {
        // The event may not have been registered before discovery failed.
      }
      try {
        client.off(
          'BLEConnectionStateChange',
          this.connectionCallback
        );
      } catch (_error) {
        // The event may already have been cleared by the platform.
      }
      try {
        client.disconnect();
      } catch (_error) {
        // The connection may already be disconnected.
      }
      try {
        client.close();
      } catch (_error) {
        // Closing is best-effort during teardown.
      }
    }
    this.deviceId = '';
    this.liveCharacteristic = null;
    this.controlCharacteristic = null;
    this.historyCharacteristic = null;
  }

  private resetTransferState(): void {
    this.historyCore.reset();
    this.historyPackets = [];
    this.historyStartInProgress = false;
    this.historyProcessing = false;
    this.callbacks.onHistoryStateChanged('等待连接后同步');
  }

  private beginNewOperation(): number {
    this.operationGeneration += 1;
    return this.operationGeneration;
  }

  private isConnectionAttemptActive(): boolean {
    return this.state === PlantBleConnectionState.REQUESTING_PERMISSION ||
      this.state === PlantBleConnectionState.SCANNING ||
      this.state === PlantBleConnectionState.CONNECTING ||
      this.state === PlantBleConnectionState.DISCOVERING ||
      this.state === PlantBleConnectionState.CONNECTED;
  }

  private isCurrentOperation(
    generation: number,
    client: ble.GattClientDevice
  ): boolean {
    return generation === this.operationGeneration &&
      client === this.gattClient;
  }

  private publishConnectionState(
    state: PlantBleConnectionState,
    title: string
  ): void {
    this.state = state;
    this.callbacks.onConnectionStateChanged(state, title);
  }

  private static findCharacteristic(
    service: ble.GattService,
    uuid: string
  ): ble.BLECharacteristic | null {
    const characteristic = service.characteristics.find(
      (candidate: ble.BLECharacteristic) =>
        PlantBleManager.uuidEquals(
          candidate.characteristicUuid,
          uuid
        )
    );
    return characteristic ?? null;
  }

  private static uuidEquals(left: string, right: string): boolean {
    return left.replace(/[{}]/g, '').toLowerCase() ===
      right.replace(/[{}]/g, '').toLowerCase();
  }

  private static containsPlantServiceUuid(data: ArrayBuffer): boolean {
    const bytes = new Uint8Array(data);
    return PlantBleManager.containsSequence(
      bytes,
      PlantBleManager.SERVICE_UUID_LITTLE_ENDIAN
    ) || PlantBleManager.containsSequence(
      bytes,
      PlantBleManager.SERVICE_UUID_BIG_ENDIAN
    );
  }

  private static containsSequence(
    bytes: Uint8Array,
    sequence: number[]
  ): boolean {
    if (bytes.byteLength < sequence.length) {
      return false;
    }
    for (
      let start = 0;
      start <= bytes.byteLength - sequence.length;
      start++
    ) {
      let matches = true;
      for (let offset = 0; offset < sequence.length; offset++) {
        if (bytes[start + offset] !== sequence[offset]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        return true;
      }
    }
    return false;
  }

  private static copyBytes(buffer: ArrayBuffer): Uint8Array {
    const source = new Uint8Array(buffer);
    const copy = new Uint8Array(source.byteLength);
    copy.set(source);
    return copy;
  }

  private static errorMessage(error: Object): string {
    if (error instanceof Error && error.message.length > 0) {
      return error.message;
    }
    return '未知错误';
  }
}
