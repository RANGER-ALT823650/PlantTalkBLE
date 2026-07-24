import {
  HistoryBatchEnd,
  HistoryReading,
  HistorySaveResult
} from '../model/PlantModels';
import {
  DecodedHistoryPacket,
  HistoryPacketType,
  PlantBleProtocol
} from './PlantBleProtocol';

export enum HistorySyncEffectType {
  NONE = 'none',
  WRITE_CONTROL = 'writeControl',
  COMMIT_BATCH = 'commitBatch',
  COMPLETE = 'complete',
  REJECT_BATCH = 'rejectBatch'
}

export class HistorySyncEffect {
  type: HistorySyncEffectType;
  payload: Uint8Array | null;
  readings: HistoryReading[];
  batchEnd: HistoryBatchEnd | null;
  durableSequence: number;
  message: string;

  constructor(type: HistorySyncEffectType) {
    this.type = type;
    this.payload = null;
    this.readings = [];
    this.batchEnd = null;
    this.durableSequence = 0;
    this.message = '';
  }

  static writeControl(payload: Uint8Array): HistorySyncEffect {
    const effect = new HistorySyncEffect(HistorySyncEffectType.WRITE_CONTROL);
    effect.payload = payload;
    return effect;
  }

  static commit(readings: HistoryReading[], end: HistoryBatchEnd): HistorySyncEffect {
    const effect = new HistorySyncEffect(HistorySyncEffectType.COMMIT_BATCH);
    effect.readings = readings.slice();
    effect.batchEnd = end;
    return effect;
  }

  static complete(durableSequence: number): HistorySyncEffect {
    const effect = new HistorySyncEffect(HistorySyncEffectType.COMPLETE);
    effect.durableSequence = durableSequence;
    return effect;
  }

  static reject(message: string): HistorySyncEffect {
    const effect = new HistorySyncEffect(HistorySyncEffectType.REJECT_BATCH);
    effect.message = message;
    return effect;
  }
}

enum PendingControlCompletion {
  NONE = 'none',
  WAIT_FOR_BATCH = 'waitForBatch',
  AFTER_ACK = 'afterAck'
}

/**
 * Pure history-transfer state machine.
 *
 * The platform BLE adapter executes WRITE_CONTROL with response. The database
 * adapter executes COMMIT_BATCH in one transaction. Only after the commit
 * succeeds does this core emit an ACK, preserving the iOS/firmware invariant.
 */
export class HistorySyncCore {
  private requestedAfterSequence: number = 0;
  private readings: HistoryReading[] = [];
  private rejectionMessage: string | null = null;
  private awaitingCommit: boolean = false;
  private pendingEnd: HistoryBatchEnd | null = null;
  private pendingDurableSequence: number = 0;
  private pendingControl: PendingControlCompletion = PendingControlCompletion.NONE;

  begin(afterSequence: number): HistorySyncEffect {
    this.reset();
    this.requestedAfterSequence = afterSequence;
    this.pendingControl = PendingControlCompletion.WAIT_FOR_BATCH;
    return HistorySyncEffect.writeControl(
      PlantBleProtocol.makeHistoryRequest(afterSequence)
    );
  }

  acceptPacket(bytes: Uint8Array): HistorySyncEffect {
    let packet: DecodedHistoryPacket;
    try {
      packet = PlantBleProtocol.decodeHistoryPacket(bytes);
    } catch (error) {
      const message = error instanceof Error ? error.message : '历史数据包解析失败';
      if (this.rejectionMessage === null) {
        this.rejectionMessage = message;
      }
      return HistorySyncEffect.reject(this.rejectionMessage);
    }

    // iOS ignores record/batch notifications while its database Task is active.
    // Keeping that state explicit prevents a late notification from mutating the
    // batch that has already been handed to the repository.
    if (
      this.awaitingCommit &&
      packet.type !== HistoryPacketType.FAILURE
    ) {
      return new HistorySyncEffect(HistorySyncEffectType.NONE);
    }

    if (this.rejectionMessage !== null) {
      const message = this.rejectionMessage;
      if (packet.type === HistoryPacketType.BATCH_END) {
        this.resetBatch();
      }
      return HistorySyncEffect.reject(message);
    }

    switch (packet.type) {
      case HistoryPacketType.RECORD:
        if (packet.record === null) {
          return this.rejectCurrentBatch('历史记录包缺少记录内容');
        }
        return this.acceptRecord(packet.record);

      case HistoryPacketType.BATCH_END:
        if (packet.batchEnd === null) {
          return this.rejectCurrentBatch('批次结束包缺少完整性信息');
        }
        return this.finishBatch(packet.batchEnd);

      case HistoryPacketType.FAILURE:
        return this.failCurrentBatch(
          `ESP32 拒绝历史同步请求（错误码 ${packet.failureCode ?? 0}）`
        );

      default:
        return this.rejectCurrentBatch('未知历史同步状态');
    }
  }

  onCommitSucceeded(
    result: HistorySaveResult,
    end: HistoryBatchEnd
  ): HistorySyncEffect {
    if (!this.awaitingCommit) {
      return this.rejectCurrentBatch('收到未匹配的数据库提交结果');
    }
    this.awaitingCommit = false;
    if (result.durableSequence < end.lastSequence) {
      return this.rejectCurrentBatch('数据库提交后的持久化游标落后于本批末序号');
    }
    this.pendingEnd = end;
    this.pendingDurableSequence = result.durableSequence;
    this.pendingControl = PendingControlCompletion.AFTER_ACK;
    return HistorySyncEffect.writeControl(
      PlantBleProtocol.makeHistoryAcknowledgement(result.durableSequence)
    );
  }

  onCommitFailed(message: string): HistorySyncEffect {
    this.awaitingCommit = false;
    return this.rejectCurrentBatch(`保存历史记录失败：${message}`);
  }

  onControlWriteSucceeded(): HistorySyncEffect {
    if (this.pendingControl === PendingControlCompletion.WAIT_FOR_BATCH) {
      this.pendingControl = PendingControlCompletion.NONE;
      return new HistorySyncEffect(HistorySyncEffectType.NONE);
    }
    if (
      this.pendingControl !== PendingControlCompletion.AFTER_ACK ||
      this.pendingEnd === null
    ) {
      return new HistorySyncEffect(HistorySyncEffectType.NONE);
    }

    const end = this.pendingEnd;
    const durableSequence = this.pendingDurableSequence;
    this.pendingControl = PendingControlCompletion.NONE;
    this.pendingEnd = null;
    this.pendingDurableSequence = 0;
    this.resetBatch();

    if (
      end.remainingCount > 0 &&
      durableSequence < end.newestSequence
    ) {
      this.requestedAfterSequence = durableSequence;
      this.pendingControl = PendingControlCompletion.WAIT_FOR_BATCH;
      return HistorySyncEffect.writeControl(
        PlantBleProtocol.makeHistoryRequest(durableSequence)
      );
    }
    return HistorySyncEffect.complete(durableSequence);
  }

  onControlWriteFailed(message: string): HistorySyncEffect {
    this.pendingControl = PendingControlCompletion.NONE;
    return this.rejectCurrentBatch(`写入 BLE 控制命令失败：${message}`);
  }

  reset(): void {
    this.requestedAfterSequence = 0;
    this.pendingEnd = null;
    this.pendingDurableSequence = 0;
    this.pendingControl = PendingControlCompletion.NONE;
    this.awaitingCommit = false;
    this.resetBatch();
  }

  private acceptRecord(reading: HistoryReading): HistorySyncEffect {
    if (this.readings.length === 0) {
      if (reading.sequence <= this.requestedAfterSequence) {
        return this.rejectCurrentBatch('本批第一条记录没有越过持久化游标');
      }
    } else {
      const previous = this.readings[this.readings.length - 1].sequence;
      if (previous >= 0xFFFFFFFF || reading.sequence !== previous + 1) {
        return this.rejectCurrentBatch('本批历史记录序号不连续');
      }
    }
    this.readings.push(reading);
    return new HistorySyncEffect(HistorySyncEffectType.NONE);
  }

  private finishBatch(end: HistoryBatchEnd): HistorySyncEffect {
    try {
      PlantBleProtocol.validateHistoryBatch(
        this.readings,
        this.requestedAfterSequence,
        end
      );
    } catch (error) {
      const message = error instanceof Error ? error.message : '历史数据批次不完整';
      return this.rejectCurrentBatch(message);
    }

    const committedReadings = this.readings.slice();
    this.readings = [];
    this.rejectionMessage = null;
    this.awaitingCommit = true;

    // Empty batches still go through the repository transaction and BLE ACK.
    // This mirrors iOS exactly and keeps "ACK means durable" true for every
    // successfully validated batch, including the terminal empty batch.
    return HistorySyncEffect.commit(committedReadings, end);
  }

  private rejectCurrentBatch(message: string): HistorySyncEffect {
    if (this.rejectionMessage === null) {
      this.rejectionMessage = message;
    }
    return HistorySyncEffect.reject(this.rejectionMessage);
  }

  private failCurrentBatch(message: string): HistorySyncEffect {
    this.readings = [];
    this.rejectionMessage = null;
    this.awaitingCommit = false;
    return HistorySyncEffect.reject(message);
  }

  private resetBatch(): void {
    this.readings = [];
    this.rejectionMessage = null;
  }
}
