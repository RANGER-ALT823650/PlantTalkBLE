export class PlantReading {
  temperature: number | null;
  humidity: number | null;
  soilRaw: number;
  lightLux: number | null;
  receivedAtMs: number;

  constructor(
    temperature: number | null,
    humidity: number | null,
    soilRaw: number,
    lightLux: number | null,
    receivedAtMs: number
  ) {
    this.temperature = temperature;
    this.humidity = humidity;
    this.soilRaw = soilRaw;
    this.lightLux = lightLux;
    this.receivedAtMs = receivedAtMs;
  }
}

export class HistoryReading {
  sequence: number;
  recordedAtMs: number;
  timestampEstimated: boolean;
  soilRaw: number;
  temperature: number | null;
  humidity: number | null;
  lightLux: number | null;

  constructor(
    sequence: number,
    recordedAtMs: number,
    timestampEstimated: boolean,
    soilRaw: number,
    temperature: number | null,
    humidity: number | null,
    lightLux: number | null
  ) {
    this.sequence = sequence;
    this.recordedAtMs = recordedAtMs;
    this.timestampEstimated = timestampEstimated;
    this.soilRaw = soilRaw;
    this.temperature = temperature;
    this.humidity = humidity;
    this.lightLux = lightLux;
  }
}

export class HistoryBatchEnd {
  recordCount: number;
  firstSequence: number;
  lastSequence: number;
  remainingCount: number;
  newestSequence: number;

  constructor(
    recordCount: number,
    firstSequence: number,
    lastSequence: number,
    remainingCount: number,
    newestSequence: number
  ) {
    this.recordCount = recordCount;
    this.firstSequence = firstSequence;
    this.lastSequence = lastSequence;
    this.remainingCount = remainingCount;
    this.newestSequence = newestSequence;
  }
}

export class HistorySaveResult {
  receivedCount: number;
  insertedCount: number;
  durableSequence: number;

  constructor(receivedCount: number, insertedCount: number, durableSequence: number) {
    this.receivedCount = receivedCount;
    this.insertedCount = insertedCount;
    this.durableSequence = durableSequence;
  }
}

export enum ChatRole {
  SYSTEM = 'system',
  USER = 'user',
  ASSISTANT = 'assistant'
}

export enum AIConversationKind {
  TEXT = 'text',
  REALTIME = 'realtime'
}

export class AIConversation {
  id: string;
  title: string;
  kind: AIConversationKind;
  createdAtMs: number;
  updatedAtMs: number;

  constructor(
    id: string,
    title: string,
    kind: AIConversationKind,
    createdAtMs: number,
    updatedAtMs: number
  ) {
    this.id = id;
    this.title = title;
    this.kind = kind;
    this.createdAtMs = createdAtMs;
    this.updatedAtMs = updatedAtMs;
  }
}

export class ChatImageAttachment {
  id: string;
  mimeType: string;
  data: Uint8Array;

  constructor(id: string, mimeType: string, data: Uint8Array) {
    this.id = id;
    this.mimeType = mimeType;
    this.data = data;
  }
}

export class ToolInvocation {
  id: string;
  providerCallID: string | null;
  toolName: string;
  summary: string;
  argumentsJSON: string;
  resultJSON: string;
  executedAtMs: number;

  constructor(
    id: string,
    providerCallID: string | null,
    toolName: string,
    summary: string,
    argumentsJSON: string,
    resultJSON: string,
    executedAtMs: number
  ) {
    this.id = id;
    this.providerCallID = providerCallID;
    this.toolName = toolName;
    this.summary = summary;
    this.argumentsJSON = argumentsJSON;
    this.resultJSON = resultJSON;
    this.executedAtMs = executedAtMs;
  }
}

export class ChatMessage {
  id: string;
  conversationID: string;
  role: ChatRole;
  content: string;
  createdAtMs: number;
  imageAttachments: ChatImageAttachment[];
  toolInvocations: ToolInvocation[];

  constructor(
    id: string,
    conversationID: string,
    role: ChatRole,
    content: string,
    createdAtMs: number
  ) {
    this.id = id;
    this.conversationID = conversationID;
    this.role = role;
    this.content = content;
    this.createdAtMs = createdAtMs;
    this.imageAttachments = [];
    this.toolInvocations = [];
  }
}
