import { relationalStore } from '@kit.ArkData';
import { DatabaseSchema } from './DatabaseSchema';
import { HistoryRepository, DailySensorSummary } from './HistoryRepository';
import {
  HistoryReading,
  HistorySaveResult
} from '../model/PlantModels';

export interface DailySummaryAccumulator {
  count: number;
  sumTemp: number;
  countTemp: number;
  sumHum: number;
  countHum: number;
  sumSoil: number;
  sumLight: number;
  countLight: number;
}

/**
 * HarmonyOS relational-store implementation of the BLE history repository.
 *
 * Uses standard RDB transaction methods (beginTransaction, commit, rollBack)
 * and SQL APIs compatible with non-vector databases.
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
    try {
      await store.executeSql('PRAGMA foreign_keys = ON');
    } catch (_e) {
      // Ignore if PRAGMA is not supported in executeSql
    }
    await RelationalHistoryRepository.prepareSchema(store);
    return new RelationalHistoryRepository(store);
  }

  /**
   * Returns the underlying RdbStore instance for reuse in other repositories.
   */
  getStore(): relationalStore.RdbStore {
    return this.store;
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
      const colIdx = resultSet.getColumnIndex('last_sequence');
      if (colIdx < 0) {
        return 0;
      }
      return RelationalHistoryRepository.clampUInt32(resultSet.getLong(colIdx));
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
      const colIdx = resultSet.getColumnIndex('reading_count');
      if (colIdx < 0) {
        return 0;
      }
      return Math.max(0, Math.trunc(resultSet.getLong(colIdx)));
    } finally {
      resultSet.close();
    }
  }

  async getLatestReading(deviceId: string): Promise<HistoryReading | null> {
    const resultSet = await this.store.querySql(
      `SELECT sequence, recorded_at, timestamp_estimated, soil_raw, temperature, humidity, light_lux
       FROM sensor_readings
       WHERE device_id = ?
       ORDER BY sequence DESC
       LIMIT 1`,
      [deviceId]
    );
    try {
      if (!resultSet.goToFirstRow()) {
        return null;
      }
      return RelationalHistoryRepository.rowToReading(resultSet);
    } finally {
      resultSet.close();
    }
  }

  async getReadingsInRange(
    deviceId: string,
    startTimeMs: number,
    endTimeMs: number
  ): Promise<HistoryReading[]> {
    const resultSet = await this.store.querySql(
      `SELECT sequence, recorded_at, timestamp_estimated, soil_raw, temperature, humidity, light_lux
       FROM sensor_readings
       WHERE device_id = ? AND recorded_at >= ? AND recorded_at <= ?
       ORDER BY sequence ASC`,
      [deviceId, startTimeMs, endTimeMs]
    );
    const results: HistoryReading[] = [];
    try {
      while (resultSet.goToNextRow()) {
        results.push(RelationalHistoryRepository.rowToReading(resultSet));
      }
      return results;
    } finally {
      resultSet.close();
    }
  }

  async getDailySummaries(deviceId: string): Promise<DailySensorSummary[]> {
    const resultSet = await this.store.querySql(
      `SELECT
         sequence, recorded_at, timestamp_estimated, soil_raw, temperature, humidity, light_lux
       FROM sensor_readings
       WHERE device_id = ?
       ORDER BY recorded_at ASC`,
      [deviceId]
    );

    const summariesMap: Map<string, DailySummaryAccumulator> = new Map();

    try {
      while (resultSet.goToNextRow()) {
        const reading = RelationalHistoryRepository.rowToReading(resultSet);
        const d = new Date(reading.recordedAtMs);
        const dateStr = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
        
        let entry = summariesMap.get(dateStr);
        if (!entry) {
          entry = {
            count: 0,
            sumTemp: 0,
            countTemp: 0,
            sumHum: 0,
            countHum: 0,
            sumSoil: 0,
            sumLight: 0,
            countLight: 0
          };
          summariesMap.set(dateStr, entry);
        }

        entry.count++;
        entry.sumSoil += reading.soilRaw;

        if (reading.temperature !== null) {
          entry.sumTemp += reading.temperature;
          entry.countTemp++;
        }
        if (reading.humidity !== null) {
          entry.sumHum += reading.humidity;
          entry.countHum++;
        }
        if (reading.lightLux !== null) {
          entry.sumLight += reading.lightLux;
          entry.countLight++;
        }
      }
    } finally {
      resultSet.close();
    }

    const summaries: DailySensorSummary[] = [];
    summariesMap.forEach((entry: DailySummaryAccumulator, dateStr: string) => {
      summaries.push({
        date: dateStr,
        count: entry.count,
        avgTemperature: entry.countTemp > 0 ? entry.sumTemp / entry.countTemp : null,
        avgHumidity: entry.countHum > 0 ? entry.sumHum / entry.countHum : null,
        avgSoilRaw: Math.round(entry.sumSoil / entry.count),
        avgLightLux: entry.countLight > 0 ? entry.sumLight / entry.countLight : null
      });
    });

    return summaries;
  }

  async deleteAllHistory(deviceId: string): Promise<void> {
    this.store.beginTransaction();
    try {
      await this.store.executeSql('DELETE FROM sensor_readings WHERE device_id = ?', [deviceId]);
      await this.store.executeSql('DELETE FROM device_sync_state WHERE device_id = ?', [deviceId]);
      this.store.commit();
    } catch (error) {
      this.store.rollBack();
      throw RelationalHistoryRepository.normalizedError(error, '删除历史记录失败');
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
    const receivedAtMs = Date.now();
    let insertedCount = 0;

    this.store.beginTransaction();
    try {
      for (const reading of readings) {
        const bucket: relationalStore.ValuesBucket = {
          'device_id': deviceId,
          'sequence': reading.sequence,
          'recorded_at': reading.recordedAtMs,
          'received_at': receivedAtMs,
          'timestamp_estimated': reading.timestampEstimated ? 1 : 0,
          'soil_raw': reading.soilRaw,
          'temperature': reading.temperature,
          'humidity': reading.humidity,
          'light_lux': reading.lightLux
        };

        const rowId = await this.store.insert(
          'sensor_readings',
          bucket,
          relationalStore.ConflictResolution.ON_CONFLICT_IGNORE
        );

        if (rowId !== -1) {
          insertedCount++;
        }
      }

      await this.store.executeSql(
        `INSERT INTO device_sync_state (
          device_id,
          last_sequence,
          last_sync_at
        ) VALUES (?, ?, ?)
        ON CONFLICT(device_id) DO UPDATE SET
          last_sequence = MAX(last_sequence, excluded.last_sequence),
          last_sync_at = excluded.last_sync_at`,
        [deviceId, acknowledgedThrough, receivedAtMs]
      );

      const resultSet = await this.store.querySql(
        `SELECT COALESCE(MAX(last_sequence), 0) AS durable_seq
         FROM device_sync_state
         WHERE device_id = ?`,
        [deviceId]
      );
      let durableSequence = 0;
      try {
        if (resultSet.goToFirstRow()) {
          const colIdx = resultSet.getColumnIndex('durable_seq');
          if (colIdx >= 0) {
            durableSequence = RelationalHistoryRepository.clampUInt32(resultSet.getLong(colIdx));
          }
        }
      } finally {
        resultSet.close();
      }

      this.store.commit();
      return new HistorySaveResult(
        readings.length,
        insertedCount,
        durableSequence
      );
    } catch (error) {
      try {
        this.store.rollBack();
      } catch (_rollbackError) {
        // Preserve original write error
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

    if (store.version < DatabaseSchema.VERSION) {
      store.beginTransaction();
      try {
        for (const statement of DatabaseSchema.CREATE_STATEMENTS) {
          await store.executeSql(statement);
        }
        store.version = DatabaseSchema.VERSION;
        store.commit();
      } catch (error) {
        try {
          store.rollBack();
        } catch (_rollbackError) {
          // Ignore rollback error
        }
        throw RelationalHistoryRepository.normalizedError(
          error,
          '初始化数据库失败'
        );
      }
    }
  }

  private static rowToReading(resultSet: relationalStore.ResultSet): HistoryReading {
    const seqIdx = resultSet.getColumnIndex('sequence');
    const timeIdx = resultSet.getColumnIndex('recorded_at');
    const estIdx = resultSet.getColumnIndex('timestamp_estimated');
    const soilIdx = resultSet.getColumnIndex('soil_raw');
    const tempIdx = resultSet.getColumnIndex('temperature');
    const humIdx = resultSet.getColumnIndex('humidity');
    const lightIdx = resultSet.getColumnIndex('light_lux');

    const sequence = seqIdx >= 0 ? resultSet.getLong(seqIdx) : 0;
    const recordedAtMs = timeIdx >= 0 ? resultSet.getLong(timeIdx) : 0;
    const timestampEstimated = estIdx >= 0 ? resultSet.getLong(estIdx) === 1 : false;
    const soilRaw = soilIdx >= 0 ? resultSet.getLong(soilIdx) : 0;
    const temperature = (tempIdx >= 0 && !resultSet.isColumnNull(tempIdx)) ? resultSet.getDouble(tempIdx) : null;
    const humidity = (humIdx >= 0 && !resultSet.isColumnNull(humIdx)) ? resultSet.getDouble(humIdx) : null;
    const lightLux = (lightIdx >= 0 && !resultSet.isColumnNull(lightIdx)) ? resultSet.getDouble(lightIdx) : null;

    return new HistoryReading(
      sequence,
      recordedAtMs,
      timestampEstimated,
      soilRaw,
      temperature,
      humidity,
      lightLux
    );
  }

  private static normalizedError(
    error: Error | Object,
    fallbackMessage: string
  ): Error {
    console.error(`[RelationalDB Error] ${fallbackMessage}:`, JSON.stringify(error));
    if (error instanceof Error) {
      return error;
    }
    const errObj = error as Record<string, Object>;
    const code = errObj && errObj['code'] !== undefined ? ` (code: ${errObj['code']})` : '';
    const msg = errObj && errObj['message'] !== undefined ? `: ${errObj['message']}` : '';
    return new Error(`${fallbackMessage}${code}${msg}`);
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
