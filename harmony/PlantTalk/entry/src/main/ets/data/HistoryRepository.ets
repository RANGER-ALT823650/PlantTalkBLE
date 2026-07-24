import { HistoryReading, HistorySaveResult } from '../model/PlantModels';

export interface HistoryRepository {
  getLastSequence(deviceId: string): Promise<number>;

  saveHistoryBatch(
    readings: HistoryReading[],
    deviceId: string,
    acknowledgedThrough: number
  ): Promise<HistorySaveResult>;

  getReadingCount(deviceId: string): Promise<number>;
}

export interface BleControlWriter {
  writeWithResponse(payload: Uint8Array): Promise<void>;
}
