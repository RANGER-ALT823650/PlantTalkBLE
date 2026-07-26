import { HistoryReading, HistorySaveResult } from '../model/PlantModels';

export interface DailySensorSummary {
  date: string;
  count: number;
  avgTemperature: number | null;
  avgHumidity: number | null;
  avgSoilRaw: number;
  avgLightLux: number | null;
}

export interface HistoryRepository {
  getLastSequence(deviceId: string): Promise<number>;

  saveHistoryBatch(
    readings: HistoryReading[],
    deviceId: string,
    acknowledgedThrough: number
  ): Promise<HistorySaveResult>;

  getReadingCount(deviceId: string): Promise<number>;

  getLatestReading(deviceId: string): Promise<HistoryReading | null>;

  getReadingsInRange(
    deviceId: string,
    startTimeMs: number,
    endTimeMs: number
  ): Promise<HistoryReading[]>;

  getDailySummaries(deviceId: string): Promise<DailySensorSummary[]>;

  deleteAllHistory(deviceId: string): Promise<void>;
}

export interface BleControlWriter {
  writeWithResponse(payload: Uint8Array): Promise<void>;
}

