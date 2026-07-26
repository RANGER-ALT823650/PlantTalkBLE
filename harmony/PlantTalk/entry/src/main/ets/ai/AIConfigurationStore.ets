import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';

export const DEFAULT_CHAT_BASE_URL: string = 'https://api.openai.com/v1';
export const DEFAULT_CHAT_MODEL: string = 'gpt-4.1-mini';
export const DEFAULT_REALTIME_URL: string =
  'wss://dashscope.aliyuncs.com/api-ws/v1/realtime';
export const DEFAULT_REALTIME_MODEL: string = 'qwen3.5-omni-flash-realtime';
export const DEFAULT_REALTIME_VOICE: string = 'Tina';
export const DEFAULT_IMAGE_GENERATION_URL: string =
  'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation';
export const DEFAULT_IMAGE_GENERATION_MODEL: string = '';
export const QWEN_IMAGE_EDIT_MODEL: string = 'qwen-image-edit';
export const DEFAULT_IMAGE_GENERATION_PROMPT: string =
  '参考这张植物照片，生成一张同一株植物的精致艺术插画：保留植物本身的形态与主要特征，' +
  '背景干净柔和，光线通透自然，整体清新治愈。';
export const DEFAULT_SYSTEM_PROMPT: string =
  '你是一株通过传感器感知周围环境的植物。请使用第一人称、自然且简洁地与照料者交流。' +
  '你可以根据温度、空气湿度、土壤湿度 ADC 原始值和光照数据分析当前状态，' +
  '但不要把未经校准的 ADC 原始值当成准确百分比。数据不足时明确说明，' +
  '不要虚构传感器读数或植物品种。';

const PREFERENCES_NAME: string = 'plant-talk-ai-settings';
const CHAT_API_KEY_ALIAS: string = 'plant-talk-chat-api-key';
const REALTIME_API_KEY_ALIAS: string = 'plant-talk-realtime-api-key';
const IMAGE_GENERATION_API_KEY_ALIAS: string = 'plant-talk-image-generation-api-key';

const CHAT_BASE_URL_KEY: string = 'ai.baseURL';
const CHAT_MODEL_KEY: string = 'ai.model';
const SYSTEM_PROMPT_KEY: string = 'ai.systemPrompt';
const REALTIME_URL_KEY: string = 'ai.realtimeURL';
const REALTIME_MODEL_KEY: string = 'ai.realtimeModel';
const REALTIME_VOICE_KEY: string = 'ai.realtimeVoice';
const IMAGE_GENERATION_URL_KEY: string = 'ai.imageGenURL';
const IMAGE_GENERATION_MODEL_KEY: string = 'ai.imageGenModel';
const IMAGE_GENERATION_PROMPT_KEY: string = 'ai.imageGenPrompt';

export class AISettingsSnapshot {
  chatBaseURL: string = DEFAULT_CHAT_BASE_URL;
  chatModel: string = DEFAULT_CHAT_MODEL;
  systemPrompt: string = DEFAULT_SYSTEM_PROMPT;
  realtimeURL: string = DEFAULT_REALTIME_URL;
  realtimeModel: string = DEFAULT_REALTIME_MODEL;
  realtimeVoice: string = DEFAULT_REALTIME_VOICE;
  imageGenerationURL: string = DEFAULT_IMAGE_GENERATION_URL;
  imageGenerationModel: string = DEFAULT_IMAGE_GENERATION_MODEL;
  imageGenerationPrompt: string = DEFAULT_IMAGE_GENERATION_PROMPT;
}

export class ImageGenerationConfiguration {
  baseURL: string;
  model: string;
  apiKey: string;

  constructor(baseURL: string, model: string, apiKey: string) {
    this.baseURL = baseURL;
    this.model = model;
    this.apiKey = apiKey;
  }
}

export class AIConfigurationStore {
  static load(context: Context): AISettingsSnapshot {
    try {
      const store = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      const snapshot = new AISettingsSnapshot();
      snapshot.chatBaseURL =
        store.getSync(CHAT_BASE_URL_KEY, DEFAULT_CHAT_BASE_URL).toString();
      snapshot.chatModel =
        store.getSync(CHAT_MODEL_KEY, DEFAULT_CHAT_MODEL).toString();
      snapshot.systemPrompt =
        store.getSync(SYSTEM_PROMPT_KEY, DEFAULT_SYSTEM_PROMPT).toString();
      snapshot.realtimeURL =
        store.getSync(REALTIME_URL_KEY, DEFAULT_REALTIME_URL).toString();
      snapshot.realtimeModel =
        store.getSync(REALTIME_MODEL_KEY, DEFAULT_REALTIME_MODEL).toString();
      snapshot.realtimeVoice =
        store.getSync(REALTIME_VOICE_KEY, DEFAULT_REALTIME_VOICE).toString();
      snapshot.imageGenerationURL =
        store.getSync(IMAGE_GENERATION_URL_KEY, DEFAULT_IMAGE_GENERATION_URL).toString();
      snapshot.imageGenerationModel =
        store.getSync(IMAGE_GENERATION_MODEL_KEY, DEFAULT_IMAGE_GENERATION_MODEL).toString();
      snapshot.imageGenerationPrompt =
        store.getSync(IMAGE_GENERATION_PROMPT_KEY, DEFAULT_IMAGE_GENERATION_PROMPT).toString();
      return snapshot;
    } catch (_error) {
      throw new Error('读取大模型偏好设置失败。');
    }
  }

  static async savePreferences(context: Context, snapshot: AISettingsSnapshot): Promise<void> {
    try {
      const store = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      store.putSync(CHAT_BASE_URL_KEY, snapshot.chatBaseURL.trim());
      store.putSync(CHAT_MODEL_KEY, snapshot.chatModel.trim());
      store.putSync(SYSTEM_PROMPT_KEY, snapshot.systemPrompt);
      store.putSync(REALTIME_URL_KEY, snapshot.realtimeURL.trim());
      store.putSync(REALTIME_MODEL_KEY, snapshot.realtimeModel.trim());
      store.putSync(REALTIME_VOICE_KEY, snapshot.realtimeVoice.trim());
      store.putSync(IMAGE_GENERATION_URL_KEY, snapshot.imageGenerationURL.trim());
      store.putSync(IMAGE_GENERATION_MODEL_KEY, snapshot.imageGenerationModel.trim());
      store.putSync(IMAGE_GENERATION_PROMPT_KEY, snapshot.imageGenerationPrompt);
      await store.flush();
    } catch (_error) {
      throw new Error('保存大模型偏好设置失败。');
    }
  }

  static hasChatAPIKey(): boolean {
    return AIConfigurationStore.readSecret(CHAT_API_KEY_ALIAS) !== null;
  }

  static hasRealtimeAPIKey(): boolean {
    return AIConfigurationStore.readSecret(REALTIME_API_KEY_ALIAS) !== null;
  }

  static hasImageGenerationAPIKey(): boolean {
    return AIConfigurationStore.readSecret(IMAGE_GENERATION_API_KEY_ALIAS) !== null;
  }

  static saveChatAPIKey(value: string): void {
    AIConfigurationStore.saveSecret(CHAT_API_KEY_ALIAS, value);
  }

  static saveRealtimeAPIKey(value: string): void {
    AIConfigurationStore.saveSecret(REALTIME_API_KEY_ALIAS, value);
  }

  static saveImageGenerationAPIKey(value: string): void {
    AIConfigurationStore.saveSecret(IMAGE_GENERATION_API_KEY_ALIAS, value);
  }

  static deleteChatAPIKey(): void {
    AIConfigurationStore.deleteSecret(CHAT_API_KEY_ALIAS);
  }

  static deleteRealtimeAPIKey(): void {
    AIConfigurationStore.deleteSecret(REALTIME_API_KEY_ALIAS);
  }

  static deleteImageGenerationAPIKey(): void {
    AIConfigurationStore.deleteSecret(IMAGE_GENERATION_API_KEY_ALIAS);
  }

  static imageGenerationConfiguration(context: Context): ImageGenerationConfiguration {
    const settings = AIConfigurationStore.load(context);
    const baseURL = settings.imageGenerationURL.trim();
    if (!AIConfigurationStore.isHTTPURL(baseURL)) {
      throw new Error('AI 生图地址无效，请填写包含 http:// 或 https:// 的地址。');
    }
    const model = settings.imageGenerationModel.trim();
    if (model.length === 0) {
      throw new Error('请在设置中填写 AI 生图模型名称（如 qwen-image-edit）。');
    }
    const dedicatedKey = AIConfigurationStore.readSecret(IMAGE_GENERATION_API_KEY_ALIAS);
    const fallbackKey = AIConfigurationStore.readSecret(REALTIME_API_KEY_ALIAS);
    const apiKey = dedicatedKey !== null ? dedicatedKey : fallbackKey;
    if (apiKey === null || apiKey.length === 0) {
      throw new Error('请先在设置中保存 AI 生图或实时语音 API Key。');
    }
    return new ImageGenerationConfiguration(baseURL, model, apiKey);
  }

  private static isHTTPURL(value: string): boolean {
    return value.startsWith('https://') || value.startsWith('http://');
  }

  private static saveSecret(alias: string, input: string): void {
    const value = input.trim();
    if (value.length === 0) {
      return;
    }
    try {
      const encoder = util.TextEncoder.create();
      const attributes: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      attributes.set(asset.Tag.ALIAS, encoder.encodeInto(alias));
      attributes.set(asset.Tag.SECRET, encoder.encodeInto(value));
      attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
      attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
      attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
      asset.addSync(attributes);
    } catch (_error) {
      throw new Error('保存安全凭据失败。');
    }
  }

  private static readSecret(alias: string): string | null {
    try {
      const encoder = util.TextEncoder.create();
      const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      query.set(asset.Tag.ALIAS, encoder.encodeInto(alias));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const result = asset.querySync(query);
      if (result.length === 0) {
        return null;
      }
      const secret = result[0].get(asset.Tag.SECRET);
      if (!(secret instanceof Uint8Array)) {
        return null;
      }
      return util.TextDecoder.create().decodeToString(secret);
    } catch (_error) {
      return null;
    }
  }

  private static deleteSecret(alias: string): void {
    try {
      const encoder = util.TextEncoder.create();
      const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      query.set(asset.Tag.ALIAS, encoder.encodeInto(alias));
      asset.removeSync(query);
    } catch (_error) {
      // Removing a key that was not saved is intentionally idempotent.
    }
  }
}
