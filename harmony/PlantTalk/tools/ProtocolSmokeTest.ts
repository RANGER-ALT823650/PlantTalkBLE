import {
  HistoryProtocolError,
  HistoryProtocolErrorCode,
  PlantBleProtocol
} from '../entry/src/main/ets/ble/PlantBleProtocol';
import {
  HistoryBatchEnd,
  HistoryReading,
  HistorySaveResult
} from '../entry/src/main/ets/model/PlantModels';
import {
  HistorySyncCore,
  HistorySyncEffectType
} from '../entry/src/main/ets/ble/HistorySyncCore';

function assertBytes(actual: Uint8Array, expected: number[], label: string): void {
  const actualText = Array.from(actual).join(',');
  const expectedText = expected.join(',');
  if (actualText !== expectedText) {
    throw new Error(`${label}: expected [${expectedText}], got [${actualText}]`);
  }
}

function assertEqual<T>(actual: T, expected: T, label: string): void {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${String(expected)}, got ${String(actual)}`);
  }
}

assertBytes(
  PlantBleProtocol.makeHistoryRequest(100, 64),
  [0x01, 0x10, 0x64, 0x00, 0x00, 0x00, 0x40, 0x00],
  'history request'
);
assertBytes(
  PlantBleProtocol.makeHistoryAcknowledgement(164),
  [0x01, 0x11, 0xA4, 0x00, 0x00, 0x00],
  'history ACK'
);
assertBytes(
  PlantBleProtocol.makeSetUnixTime(1_750_000_000_000),
  [0x01, 0x12, 0x80, 0xE1, 0x4E, 0x68],
  'set Unix time'
);
assertBytes(
  PlantBleProtocol.makeImmediateSampleRequest(),
  [0x01, 0x13],
  'immediate sample'
);

const recordBytes = new Uint8Array([
  0x01, 0x01, 0x03, 0x86,
  0x2A, 0x00, 0x00, 0x00,
  0x80, 0xE1, 0x4E, 0x68,
  0x06, 0x09,
  0x55, 0x0A,
  0x42, 0x18,
  0x0C, 0x03
]);
const decodedRecord = PlantBleProtocol.decodeHistoryPacket(recordBytes).record;
if (decodedRecord === null) {
  throw new Error('record packet did not decode as a record');
}
assertEqual(decodedRecord.sequence, 42, 'record sequence');
assertEqual(decodedRecord.recordedAtMs, 1_750_000_000_000, 'record timestamp');
assertEqual(decodedRecord.soilRaw, 2310, 'record soil');
assertEqual(decodedRecord.temperature, 26.45, 'record temperature');
assertEqual(decodedRecord.humidity, 62.1, 'record humidity');
assertEqual(decodedRecord.lightLux, 780, 'record light');

const batchEndBytes = new Uint8Array([
  0x01, 0x02, 0x40, 0x46,
  0xA4, 0x00, 0x00, 0x00,
  0x24, 0x00, 0x00, 0x00,
  0xC8, 0x00, 0x00, 0x00,
  0x65, 0x00, 0x00, 0x00
]);
const decodedEnd = PlantBleProtocol.decodeHistoryPacket(batchEndBytes).batchEnd;
if (decodedEnd === null) {
  throw new Error('batch-end packet did not decode as a batch end');
}
assertEqual(decodedEnd.recordCount, 64, 'batch count');
assertEqual(decodedEnd.firstSequence, 101, 'batch first sequence');
assertEqual(decodedEnd.lastSequence, 164, 'batch last sequence');
assertEqual(decodedEnd.remainingCount, 36, 'batch remaining count');
assertEqual(decodedEnd.newestSequence, 200, 'batch newest sequence');

const validGapBatch: HistoryReading[] = [
  new HistoryReading(105, 1_750_000_000_000, false, 2000, 22, 60, 700),
  new HistoryReading(106, 1_750_000_300_000, false, 2001, 22.1, 60.2, 705)
];
PlantBleProtocol.validateHistoryBatch(
  validGapBatch,
  100,
  new HistoryBatchEnd(2, 105, 106, 0, 106)
);

let rejectedDiscontinuity = false;
try {
  PlantBleProtocol.validateHistoryBatch(
    [
      validGapBatch[0],
      new HistoryReading(107, 1_750_000_300_000, false, 2001, 22.1, 60.2, 705)
    ],
    100,
    new HistoryBatchEnd(2, 105, 107, 0, 107)
  );
} catch (error) {
  rejectedDiscontinuity =
    error instanceof HistoryProtocolError &&
    error.code === HistoryProtocolErrorCode.INCOMPLETE_BATCH;
}
assertEqual(rejectedDiscontinuity, true, 'discontinuous batch rejection');

function makeEmptyBatchEnd(
  cursor: number,
  remainingCount: number,
  newestSequence: number
): Uint8Array {
  const bytes = new Uint8Array(20);
  const view = new DataView(bytes.buffer);
  bytes[0] = 0x01;
  bytes[1] = 0x02;
  bytes[2] = 0x00;
  view.setUint32(4, cursor, true);
  view.setUint32(8, remainingCount, true);
  view.setUint32(12, newestSequence, true);
  view.setUint32(16, 0, true);
  bytes[3] = PlantBleProtocol.crc8Atm(bytes);
  return bytes;
}

const terminalCore = new HistorySyncCore();
assertEqual(
  terminalCore.begin(100).type,
  HistorySyncEffectType.WRITE_CONTROL,
  'history sync begin'
);
terminalCore.onControlWriteSucceeded();
const terminalCommit = terminalCore.acceptPacket(makeEmptyBatchEnd(100, 1, 100));
assertEqual(
  terminalCommit.type,
  HistorySyncEffectType.COMMIT_BATCH,
  'empty terminal batch still commits'
);
if (terminalCommit.batchEnd === null) {
  throw new Error('empty terminal batch is missing metadata');
}
assertEqual(
  terminalCore.onCommitSucceeded(
    new HistorySaveResult(0, 0, 100),
    terminalCommit.batchEnd
  ).type,
  HistorySyncEffectType.WRITE_CONTROL,
  'empty terminal batch ACK after commit'
);
assertEqual(
  terminalCore.onControlWriteSucceeded().type,
  HistorySyncEffectType.COMPLETE,
  'cursor already at newest completes despite stale remaining count'
);

const continuationCore = new HistorySyncCore();
continuationCore.begin(100);
continuationCore.onControlWriteSucceeded();
const continuationCommit = continuationCore.acceptPacket(makeEmptyBatchEnd(100, 1, 101));
if (continuationCommit.batchEnd === null) {
  throw new Error('continuation batch is missing metadata');
}
continuationCore.onCommitSucceeded(
  new HistorySaveResult(0, 0, 100),
  continuationCommit.batchEnd
);
assertEqual(
  continuationCore.onControlWriteSucceeded().type,
  HistorySyncEffectType.WRITE_CONTROL,
  'remaining newer data requests next batch'
);

console.log('PlantBleProtocol smoke test passed');
