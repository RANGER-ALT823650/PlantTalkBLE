import { relationalStore } from '@kit.ArkData';
import { DatabaseSchema } from './DatabaseSchema';
import { HistoryRepository } from './HistoryRepository';
import {
  HistoryReading,
  HistorySaveResult
} from '../model/PlantModels';

/**
 * HarmonyOS relational-store implementation of the BLE history repository.
 *
 * A validated history batch and its synchronization cursor are committed in
 * the same transaction. Callers may therefore send an ACK only after
 * saveHistoryBatch resolves successfully.
 */
export class RelationalHistoryRepository implements HistoryRepository {
  private readonly store: relationalStore.RdbStore;
  private writeTail: Promise<void> =
    new Promise<void>((resolve: () => void) => resolve());

  private constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  static async open(context: Context): Promise<RelationalHistoryRepository> {
    const config: relationalStore.StoreConfig = {
      name: DatabaseSchema.FILE_NAME,
      securityLevel: relationalStore.SecurityLevel.S2,
      encrypt: false,
      allowRebuild: false
    };
    const store = await relationalStore.getRdbStore(context, config);
    await store.executeSql('PRAGMA foreign_keys = ON');
    await RelationalHistoryRepository.prepareSchema(store);
    return new RelationalHistoryRepository(store);
  }

  async getLastSequence(deviceId: string): Promise<number> {
    const resultSet = await this.store.querySql(
      `SELECT last_sequence
       FROM device_sync_state
       WHERE device_id = ?`,
      [deviceId]
    );
    try {
      if (resultSet.rowCount === 0 || !resultSet.goToFirstRow()) {
        return 0;
      }
      return RelationalHistoryRepository.clampUInt32(
        resultSet.getLong(resultSet.getColumnIndex('last_sequence'))
      );
    } finally {
      resultSet.close();
    }
  }

  async getReadingCount(deviceId: string): Promise<number> {
    const resultSet = await this.store.querySql(
      `SELECT COUNT(*) AS reading_count
       FROM sensor_readings
       WHERE device_id = ?`,
      [deviceId]
    );
    try {
      if (!resultSet.goToFirstRow()) {
        return 0;
      }
      return Math.max(
        0,
        Math.trunc(
          resultSet.getLong(resultSet.getColumnIndex('reading_count'))
        )
      );
    } finally {
      resultSet.close();
    }
  }

  async saveHistoryBatch(
    readings: HistoryReading[],
    deviceId: string,
    acknowledgedThrough: number
  ): Promise<HistorySaveResult> {
    RelationalHistoryRepository.assertDeviceId(deviceId);
    RelationalHistoryRepository.assertUInt32(
      acknowledgedThrough,
      '历史同步游标'
    );
    for (const reading of readings) {
      RelationalHistoryRepository.validateReading(reading);
    }

    let releaseWrite: () => void = () => {};
    const precedingWrite = this.writeTail;
    this.writeTail = new Promise<void>((resolve: () => void) => {
      releaseWrite = resolve;
    });
    await precedingWrite;
    try {
      return await this.saveHistoryBatchInTransaction(
        readings,
        deviceId,
        acknowledgedThrough
      );
    } finally {
      releaseWrite();
    }
  }

  private async saveHistoryBatchInTransaction(
    readings: HistoryReading[],
    deviceId: string,
    acknowledgedThrough: number
  ): Promise<HistorySaveResult> {
    const transactionId = await this.store.beginTrans();
    try {
      const receivedAtMs = Date.now();
      let insertedCount = 0;

      for (const reading of readings) {
        await this.store.execute(
          `INSERT INTO sensor_readings (
            device_id,
            sequence,
            recorded_at,
            received_at,
            timestamp_estimated,
            soil_raw,
            temperature,
            humidity,
            light_lux
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(device_id, sequence) DO NOTHING`,
          transactionId,
          [
            deviceId,
            reading.sequence,
            reading.recordedAtMs,
            receivedAtMs,
            reading.timestampEstimated ? 1 : 0,
            reading.soilRaw,
            reading.temperature,
            reading.humidity,
            reading.lightLux
          ]
        );
        const changedValue = await this.store.execute(
          'SELECT changes()',
          transactionId
        );
        insertedCount += RelationalHistoryRepository.requireNumber(
          changedValue,
          '新增记录数'
        );
      }

      // Empty terminal batches intentionally pass through this UPSERT. That
      // keeps "ACK means cursor is durable" true even when no rows arrived.
      await this.store.execute(
        `INSERT INTO device_sync_state (
          device_id,
          last_sequence,
          last_sync_at
        ) VALUES (?, ?, ?)
        ON CONFLICT(device_id) DO UPDATE SET
          last_sequence = MAX(last_sequence, excluded.last_sequence),
          last_sync_at = excluded.last_sync_at`,
        transactionId,
        [deviceId, acknowledgedThrough, receivedAtMs]
      );

      const durableValue = await this.store.execute(
        `SELECT COALESCE(MAX(last_sequence), 0)
         FROM device_sync_state
         WHERE device_id = ?`,
        transactionId,
        [deviceId]
      );
      const durableSequence = RelationalHistoryRepository.clampUInt32(
        RelationalHistoryRepository.requireNumber(
          durableValue,
          '持久化同步游标'
        )
      );
      await this.store.commit(transactionId);
      return new HistorySaveResult(
        readings.length,
        insertedCount,
        durableSequence
      );
    } catch (error) {
      try {
        await this.store.rollback(transactionId);
      } catch (_rollbackError) {
        // Preserve the original write or commit failure for the BLE layer.
      }
      throw RelationalHistoryRepository.normalizedError(
        error,
        '保存历史记录失败'
      );
    }
  }

  private static async prepareSchema(
    store: relationalStore.RdbStore
  ): Promise<void> {
    if (store.version > DatabaseSchema.VERSION) {
      throw new Error(
        `数据库版本 ${store.version} 高于当前支持版本 ${DatabaseSchema.VERSION}`
      );
    }

    const transactionId = await store.beginTrans();
    try {
      for (const statement of DatabaseSchema.CREATE_STATEMENTS) {
        await store.execute(statement, transactionId);
      }
      await store.commit(transactionId);
      if (store.version < DatabaseSchema.VERSION) {
        store.version = DatabaseSchema.VERSION;
      }
    } catch (error) {
      try {
        await store.rollback(transactionId);
      } catch (_rollbackError) {
        // Preserve the schema preparation error.
      }
      throw RelationalHistoryRepository.normalizedError(
        error,
        '初始化数据库失败'
      );
    }
  }

  private static requireNumber(
    value: relationalStore.ValueType,
    label: string
  ): number {
    if (typeof value !== 'number' || !Number.isFinite(value)) {
      throw new Error(`${label}没有返回有效数字`);
    }
    return Math.max(0, Math.trunc(value));
  }

  private static normalizedError(
    error: Object,
    fallbackMessage: string
  ): Error {
    if (error instanceof Error) {
      return error;
    }
    return new Error(fallbackMessage);
  }

  private static validateReading(reading: HistoryReading): void {
    RelationalHistoryRepository.assertUInt32(reading.sequence, '历史记录序号');
    if (reading.sequence === 0) {
      throw new Error('历史记录序号必须大于 0');
    }
    if (!Number.isFinite(reading.recordedAtMs) || reading.recordedAtMs <= 0) {
      throw new Error('历史记录时间戳无效');
    }
    if (
      !Number.isInteger(reading.soilRaw) ||
      reading.soilRaw < 0 ||
      reading.soilRaw > 0xFFFF
    ) {
      throw new Error('土壤湿度原始值超出 UInt16 范围');
    }
  }

  private static assertDeviceId(deviceId: string): void {
    if (deviceId.trim().length === 0) {
      throw new Error('BLE 设备标识不能为空');
    }
  }

  private static assertUInt32(value: number, label: string): void {
    if (
      !Number.isInteger(value) ||
      value < 0 ||
      value > 0xFFFFFFFF
    ) {
      throw new Error(`${label}超出 UInt32 范围`);
    }
  }

  private static clampUInt32(value: number): number {
    if (!Number.isFinite(value)) {
      return 0;
    }
    return Math.max(0, Math.min(0xFFFFFFFF, Math.trunc(value)));
  }
}
