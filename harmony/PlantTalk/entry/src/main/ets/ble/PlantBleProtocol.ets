import {
  HistoryBatchEnd,
  HistoryReading,
  PlantReading
} from '../model/PlantModels';

export class PlantGattProfile {
  static readonly DEVICE_NAME: string = 'Plant Sensor';
  static readonly SERVICE_UUID: string = '7A1E0001-7C6D-4A8B-9E1F-2D3C4B5A6000';
  static readonly LIVE_UUID: string = '7A1E0002-7C6D-4A8B-9E1F-2D3C4B5A6000';
  static readonly CONTROL_UUID: string = '7A1E0003-7C6D-4A8B-9E1F-2D3C4B5A6000';
  static readonly HISTORY_UUID: string = '7A1E0004-7C6D-4A8B-9E1F-2D3C4B5A6000';
}

export enum HistoryPacketType {
  RECORD = 0x01,
  BATCH_END = 0x02,
  FAILURE = 0x03
}

export enum HistoryCommandType {
  REQUEST_AFTER_SEQUENCE = 0x10,
  ACKNOWLEDGE_THROUGH_SEQUENCE = 0x11,
  SET_UNIX_TIME = 0x12,
  REQUEST_IMMEDIATE_SAMPLE = 0x13
}

export enum HistoryProtocolErrorCode {
  INVALID_LENGTH = 'invalidLength',
  UNSUPPORTED_VERSION = 'unsupportedVersion',
  CHECKSUM_MISMATCH = 'checksumMismatch',
  UNKNOWN_PACKET_TYPE = 'unknownPacketType',
  INVALID_TIMESTAMP = 'invalidTimestamp',
  INVALID_SEQUENCE = 'invalidSequence',
  INVALID_LIMIT = 'invalidLimit',
  INCOMPLETE_BATCH = 'incompleteBatch',
  OUTDATED_BATCH_METADATA = 'outdatedBatchMetadata'
}

export class HistoryProtocolError extends Error {
  code: HistoryProtocolErrorCode;

  constructor(code: HistoryProtocolErrorCode, message: string) {
    super(message);
    this.name = 'HistoryProtocolError';
    this.code = code;
  }
}

export class DecodedHistoryPacket {
  type: HistoryPacketType;
  record: HistoryReading | null;
  batchEnd: HistoryBatchEnd | null;
  failureCode: number | null;

  constructor(
    type: HistoryPacketType,
    record: HistoryReading | null = null,
    batchEnd: HistoryBatchEnd | null = null,
    failureCode: number | null = null
  ) {
    this.type = type;
    this.record = record;
    this.batchEnd = batchEnd;
    this.failureCode = failureCode;
  }
}

export class PlantBleProtocol {
  static readonly VERSION: number = 1;
  static readonly LIVE_PACKET_LENGTH: number = 16;
  static readonly HISTORY_PACKET_LENGTH: number = 20;
  static readonly REQUESTED_BATCH_SIZE: number = 64;
  private static readonly UINT32_MAX: number = 0xFFFFFFFF;

  static decodeLivePacket(bytes: Uint8Array, receivedAtMs: number = Date.now()): PlantReading {
    if (bytes.byteLength !== PlantBleProtocol.LIVE_PACKET_LENGTH) {
      throw new HistoryProtocolError(
        HistoryProtocolErrorCode.INVALID_LENGTH,
        '实时数据包必须为 16 字节'
      );
    }
    if (bytes[0] !== PlantBleProtocol.VERSION) {
      throw new HistoryProtocolError(
        HistoryProtocolErrorCode.UNSUPPORTED_VERSION,
        `不支持的实时协议版本：${bytes[0]}`
      );
    }

    const view = PlantBleProtocol.viewOf(bytes);
    const flags = bytes[1];
    const hasTemperatureAndHumidity = (flags & 0x01) !== 0;
    const hasLight = (flags & 0x02) !== 0;
    return new PlantReading(
      hasTemperatureAndHumidity ? view.getFloat32(4, true) : null,
      hasTemperatureAndHumidity ? view.getFloat32(8, true) : null,
      view.getUint16(2, true),
      hasLight ? view.getFloat32(12, true) : null,
      receivedAtMs
    );
  }

  static decodeHistoryPacket(bytes: Uint8Array): DecodedHistoryPacket {
    if (bytes.byteLength !== PlantBleProtocol.HISTORY_PACKET_LENGTH) {
      throw new HistoryProtocolError(
        HistoryProtocolErrorCode.INVALID_LENGTH,
        '历史数据包必须为 20 字节'
      );
    }
    if (bytes[0] !== PlantBleProtocol.VERSION) {
      throw new HistoryProtocolError(
        HistoryProtocolErrorCode.UNSUPPORTED_VERSION,
        `不支持的历史协议版本：${bytes[0]}`
      );
    }
    if (PlantBleProtocol.crc8Atm(bytes) !== bytes[3]) {
      throw new HistoryProtocolError(
        HistoryProtocolErrorCode.CHECKSUM_MISMATCH,
        '历史数据包校验失败'
      );
    }

    const view = PlantBleProtocol.viewOf(bytes);
    const rawType = bytes[1];
    switch (rawType) {
      case HistoryPacketType.RECORD: {
        const flags = bytes[2];
        const sequence = view.getUint32(4, true);
        const timestampSeconds = view.getUint32(8, true);
        if (sequence === 0) {
          throw new HistoryProtocolError(
            HistoryProtocolErrorCode.INVALID_SEQUENCE,
            '历史记录序号必须大于 0'
          );
        }
        if (timestampSeconds === 0) {
          throw new HistoryProtocolError(
            HistoryProtocolErrorCode.INVALID_TIMESTAMP,
            '历史记录时间戳必须大于 0'
          );
        }
        const reading = new HistoryReading(
          sequence,
          timestampSeconds * 1000,
          (flags & 0x04) !== 0,
          view.getUint16(12, true),
          (flags & 0x01) !== 0 ? view.getInt16(14, true) / 100 : null,
          (flags & 0x01) !== 0 ? view.getUint16(16, true) / 100 : null,
          (flags & 0x02) !== 0 ? view.getUint16(18, true) : null
        );
        return new DecodedHistoryPacket(HistoryPacketType.RECORD, reading);
      }
      case HistoryPacketType.BATCH_END: {
        const end = new HistoryBatchEnd(
          bytes[2],
          view.getUint32(16, true),
          view.getUint32(4, true),
          view.getUint32(8, true),
          view.getUint32(12, true)
        );
        return new DecodedHistoryPacket(HistoryPacketType.BATCH_END, null, end);
      }
      case HistoryPacketType.FAILURE:
        return new DecodedHistoryPacket(
          HistoryPacketType.FAILURE,
          null,
          null,
          view.getUint16(4, true)
        );
      default:
        throw new HistoryProtocolError(
          HistoryProtocolErrorCode.UNKNOWN_PACKET_TYPE,
          `未知历史数据包类型：${rawType}`
        );
    }
  }

  static validateHistoryBatch(
    readings: HistoryReading[],
    requestedAfterSequence: number,
    end: HistoryBatchEnd
  ): void {
    PlantBleProtocol.assertUInt32(requestedAfterSequence, '请求游标');
    if (end.recordCount > PlantBleProtocol.REQUESTED_BATCH_SIZE) {
      PlantBleProtocol.throwIncompleteBatch();
    }

    if (end.recordCount === 0) {
      if (
        readings.length !== 0 ||
        end.firstSequence !== 0 ||
        end.lastSequence !== requestedAfterSequence
      ) {
        if (end.firstSequence === 0 && readings.length !== 0) {
          throw new HistoryProtocolError(
            HistoryProtocolErrorCode.OUTDATED_BATCH_METADATA,
            'ESP32 固件缺少批次完整性信息，请先更新固件'
          );
        }
        PlantBleProtocol.throwIncompleteBatch();
      }
      return;
    }

    if (end.firstSequence <= requestedAfterSequence) {
      PlantBleProtocol.throwIncompleteBatch();
    }
    if (
      readings.length !== end.recordCount ||
      readings[0].sequence !== end.firstSequence ||
      readings[readings.length - 1].sequence !== end.lastSequence
    ) {
      if (end.firstSequence === 0) {
        throw new HistoryProtocolError(
          HistoryProtocolErrorCode.OUTDATED_BATCH_METADATA,
          'ESP32 固件缺少批次完整性信息，请先更新固件'
        );
      }
      PlantBleProtocol.throwIncompleteBatch();
    }

    for (let index = 1; index < readings.length; index++) {
      const previous = readings[index - 1].sequence;
      const current = readings[index].sequence;
      if (previous >= PlantBleProtocol.UINT32_MAX || current !== previous + 1) {
        PlantBleProtocol.throwIncompleteBatch();
      }
    }
  }

  static makeHistoryRequest(
    afterSequence: number,
    limit: number = PlantBleProtocol.REQUESTED_BATCH_SIZE
  ): Uint8Array {
    PlantBleProtocol.assertUInt32(afterSequence, '请求游标');
    if (!Number.isInteger(limit) || limit < 1 || limit > PlantBleProtocol.REQUESTED_BATCH_SIZE) {
      throw new HistoryProtocolError(
        HistoryProtocolErrorCode.INVALID_LIMIT,
        '历史批次大小必须在 1...64 之间'
      );
    }
    const bytes = new Uint8Array(8);
    const view = PlantBleProtocol.viewOf(bytes);
    bytes[0] = PlantBleProtocol.VERSION;
    bytes[1] = HistoryCommandType.REQUEST_AFTER_SEQUENCE;
    view.setUint32(2, afterSequence, true);
    view.setUint16(6, limit, true);
    return bytes;
  }

  static makeHistoryAcknowledgement(sequence: number): Uint8Array {
    PlantBleProtocol.assertUInt32(sequence, 'ACK 序号');
    const bytes = new Uint8Array(6);
    const view = PlantBleProtocol.viewOf(bytes);
    bytes[0] = PlantBleProtocol.VERSION;
    bytes[1] = HistoryCommandType.ACKNOWLEDGE_THROUGH_SEQUENCE;
    view.setUint32(2, sequence, true);
    return bytes;
  }

  static makeSetUnixTime(nowMs: number = Date.now()): Uint8Array {
    const seconds = Math.max(
      0,
      Math.min(PlantBleProtocol.UINT32_MAX, Math.trunc(nowMs / 1000))
    );
    const bytes = new Uint8Array(6);
    const view = PlantBleProtocol.viewOf(bytes);
    bytes[0] = PlantBleProtocol.VERSION;
    bytes[1] = HistoryCommandType.SET_UNIX_TIME;
    view.setUint32(2, seconds, true);
    return bytes;
  }

  static makeImmediateSampleRequest(): Uint8Array {
    return new Uint8Array([
      PlantBleProtocol.VERSION,
      HistoryCommandType.REQUEST_IMMEDIATE_SAMPLE
    ]);
  }

  static crc8Atm(bytes: Uint8Array): number {
    let crc = 0;
    for (let index = 0; index < bytes.length; index++) {
      if (index === 3) {
        continue;
      }
      crc ^= bytes[index];
      for (let bit = 0; bit < 8; bit++) {
        crc = (crc & 0x80) === 0
          ? (crc << 1) & 0xFF
          : ((crc << 1) ^ 0x07) & 0xFF;
      }
    }
    return crc;
  }

  private static viewOf(bytes: Uint8Array): DataView {
    return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  }

  private static assertUInt32(value: number, label: string): void {
    if (
      !Number.isInteger(value) ||
      value < 0 ||
      value > PlantBleProtocol.UINT32_MAX
    ) {
      throw new HistoryProtocolError(
        HistoryProtocolErrorCode.INVALID_SEQUENCE,
        `${label}必须是 UInt32`
      );
    }
  }

  private static throwIncompleteBatch(): never {
    throw new HistoryProtocolError(
      HistoryProtocolErrorCode.INCOMPLETE_BATCH,
      '历史数据批次不完整，将在下次同步时重传'
    );
  }
}
