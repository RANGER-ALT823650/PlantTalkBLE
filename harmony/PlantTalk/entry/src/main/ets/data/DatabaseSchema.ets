/**
 * Final schema for a fresh HarmonyOS install.
 *
 * iOS reached this shape through eight GRDB migrations. HarmonyOS starts with
 * the final shape, but keeps an explicit schema version so later releases can
 * add incremental upgrades without rebuilding user data.
 */
export class DatabaseSchema {
  static readonly FILE_NAME: string = 'plant-talk.db';
  static readonly VERSION: number = 1;

  static readonly CREATE_STATEMENTS: string[] = [
    `CREATE TABLE IF NOT EXISTS sensor_readings (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      device_id TEXT NOT NULL,
      sequence INTEGER NOT NULL,
      recorded_at INTEGER NOT NULL,
      received_at INTEGER NOT NULL,
      timestamp_estimated INTEGER NOT NULL DEFAULT 0,
      soil_raw INTEGER NOT NULL,
      temperature REAL,
      humidity REAL,
      light_lux REAL,
      UNIQUE(device_id, sequence)
    )`,
    `CREATE INDEX IF NOT EXISTS sensor_readings_device_time
      ON sensor_readings(device_id, recorded_at)`,
    `CREATE TABLE IF NOT EXISTS device_sync_state (
      device_id TEXT PRIMARY KEY,
      last_sequence INTEGER NOT NULL,
      last_sync_at INTEGER NOT NULL
    )`,
    `CREATE TABLE IF NOT EXISTS ai_conversations (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'text',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )`,
    `CREATE INDEX IF NOT EXISTS ai_conversations_updated_at
      ON ai_conversations(updated_at)`,
    `CREATE INDEX IF NOT EXISTS ai_conversations_kind_updated_at
      ON ai_conversations(kind, updated_at)`,
    `CREATE TABLE IF NOT EXISTS ai_messages (
      id TEXT PRIMARY KEY,
      conversation_id TEXT NOT NULL
        REFERENCES ai_conversations(id) ON DELETE CASCADE,
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )`,
    `CREATE INDEX IF NOT EXISTS ai_messages_conversation_time
      ON ai_messages(conversation_id, created_at)`,
    `CREATE TABLE IF NOT EXISTS ai_message_tool_invocations (
      id TEXT PRIMARY KEY,
      message_id TEXT NOT NULL
        REFERENCES ai_messages(id) ON DELETE CASCADE,
      position INTEGER NOT NULL,
      provider_call_id TEXT,
      tool_name TEXT NOT NULL,
      summary TEXT NOT NULL,
      arguments_json TEXT NOT NULL,
      result_json TEXT NOT NULL,
      executed_at INTEGER NOT NULL,
      UNIQUE(message_id, position)
    )`,
    `CREATE INDEX IF NOT EXISTS ai_message_tool_invocations_message_position
      ON ai_message_tool_invocations(message_id, position)`,
    `CREATE TABLE IF NOT EXISTS ai_memory_message_sequences (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      message_id TEXT NOT NULL UNIQUE
        REFERENCES ai_messages(id) ON DELETE CASCADE,
      legacy_row_id INTEGER
    )`,
    `CREATE TABLE IF NOT EXISTS ai_message_images (
      id TEXT PRIMARY KEY,
      message_id TEXT NOT NULL
        REFERENCES ai_messages(id) ON DELETE CASCADE,
      position INTEGER NOT NULL,
      mime_type TEXT NOT NULL,
      data BLOB NOT NULL,
      UNIQUE(message_id, position)
    )`,
    `CREATE INDEX IF NOT EXISTS ai_message_images_message_position
      ON ai_message_images(message_id, position)`
  ];
}
