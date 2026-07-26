import {
  AIConfigurationStore,
  AISettingsSnapshot,
  DEFAULT_CHAT_BASE_URL,
  DEFAULT_CHAT_MODEL,
  DEFAULT_IMAGE_GENERATION_PROMPT,
  DEFAULT_IMAGE_GENERATION_URL,
  DEFAULT_REALTIME_MODEL,
  DEFAULT_REALTIME_URL,
  DEFAULT_REALTIME_VOICE,
  QWEN_IMAGE_EDIT_MODEL
} from '../ai/AIConfigurationStore';
import { DesignTokens } from '../theme/DesignTokens';

@Entry
@Component
struct AISettingsPage {
  @State private chatBaseURL: string = DEFAULT_CHAT_BASE_URL;
  @State private chatModel: string = DEFAULT_CHAT_MODEL;
  @State private chatAPIKey: string = '';
  @State private hasSavedChatAPIKey: boolean = false;

  @State private realtimeURL: string = DEFAULT_REALTIME_URL;
  @State private realtimeModel: string = DEFAULT_REALTIME_MODEL;
  @State private realtimeVoice: string = DEFAULT_REALTIME_VOICE;
  @State private realtimeAPIKey: string = '';
  @State private hasSavedRealtimeAPIKey: boolean = false;

  @State private imageGenerationURL: string = DEFAULT_IMAGE_GENERATION_URL;
  @State private imageGenerationModel: string = '';
  @State private imageGenerationPrompt: string = DEFAULT_IMAGE_GENERATION_PROMPT;
  @State private imageGenerationAPIKey: string = '';
  @State private hasSavedImageGenerationAPIKey: boolean = false;

  @State private systemPrompt: string = '';

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    try {
      const snapshot = AIConfigurationStore.load(context);
      this.chatBaseURL = snapshot.chatBaseURL;
      this.chatModel = snapshot.chatModel;
      this.systemPrompt = snapshot.systemPrompt;
      this.realtimeURL = snapshot.realtimeURL;
      this.realtimeModel = snapshot.realtimeModel;
      this.realtimeVoice = snapshot.realtimeVoice;
      this.imageGenerationURL = snapshot.imageGenerationURL;
      this.imageGenerationModel = snapshot.imageGenerationModel;
      this.imageGenerationPrompt = snapshot.imageGenerationPrompt;
      this.refreshKeyStatus();
    } catch (_error) {
      this.showToast('读取大模型设置失败，请稍后重试。');
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // The page remains usable if a transient toast cannot be presented.
    }
  }

  private refreshKeyStatus(): void {
    this.hasSavedChatAPIKey = AIConfigurationStore.hasChatAPIKey();
    this.hasSavedRealtimeAPIKey = AIConfigurationStore.hasRealtimeAPIKey();
    this.hasSavedImageGenerationAPIKey =
      AIConfigurationStore.hasImageGenerationAPIKey();
  }

  private applyQwenImageDefaults(): void {
    this.imageGenerationURL = DEFAULT_IMAGE_GENERATION_URL;
    this.imageGenerationModel = QWEN_IMAGE_EDIT_MODEL;
  }

  private async save(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      this.showToast('当前页面上下文不可用，暂时无法保存。');
      return;
    }
    if (!this.chatBaseURL.trim().startsWith('http://') &&
      !this.chatBaseURL.trim().startsWith('https://')) {
      this.showToast('文本模型 Base URL 需要以 http:// 或 https:// 开头。');
      return;
    }
    if (!this.realtimeURL.trim().startsWith('ws://') &&
      !this.realtimeURL.trim().startsWith('wss://')) {
      this.showToast('实时语音地址需要以 ws:// 或 wss:// 开头。');
      return;
    }
    if (this.chatModel.trim().length === 0 || this.realtimeModel.trim().length === 0) {
      this.showToast('文本模型和实时语音模型名称不能为空。');
      return;
    }

    try {
      const snapshot = new AISettingsSnapshot();
      snapshot.chatBaseURL = this.chatBaseURL;
      snapshot.chatModel = this.chatModel;
      snapshot.systemPrompt = this.systemPrompt;
      snapshot.realtimeURL = this.realtimeURL;
      snapshot.realtimeModel = this.realtimeModel;
      snapshot.realtimeVoice = this.realtimeVoice;
      snapshot.imageGenerationURL = this.imageGenerationURL.length > 0 ?
        this.imageGenerationURL : DEFAULT_IMAGE_GENERATION_URL;
      snapshot.imageGenerationModel = this.imageGenerationModel;
      snapshot.imageGenerationPrompt = this.imageGenerationPrompt;
      await AIConfigurationStore.savePreferences(context, snapshot);

      AIConfigurationStore.saveChatAPIKey(this.chatAPIKey);
      AIConfigurationStore.saveRealtimeAPIKey(this.realtimeAPIKey);
      AIConfigurationStore.saveImageGenerationAPIKey(this.imageGenerationAPIKey);
      this.chatAPIKey = '';
      this.realtimeAPIKey = '';
      this.imageGenerationAPIKey = '';
      this.refreshKeyStatus();
      this.showToast('大模型设置已保存。');
    } catch (_error) {
      this.showToast('保存失败，请检查设备安全存储状态后重试。');
    }
  }

  private clearChatAPIKey(): void {
    AIConfigurationStore.deleteChatAPIKey();
    this.chatAPIKey = '';
    this.refreshKeyStatus();
    this.showToast('文本 API Key 已清除。');
  }

  private clearRealtimeAPIKey(): void {
    AIConfigurationStore.deleteRealtimeAPIKey();
    this.realtimeAPIKey = '';
    this.refreshKeyStatus();
    this.showToast('实时语音 API Key 已清除。');
  }

  private clearImageGenerationAPIKey(): void {
    AIConfigurationStore.deleteImageGenerationAPIKey();
    this.imageGenerationAPIKey = '';
    this.refreshKeyStatus();
    this.showToast('AI 生图专用 API Key 已清除；留空时会复用实时语音 Key。');
  }

  @Builder
  private header() {
    Row() {
      Button() {
        Text('‹')
          .fontSize(30)
          .fontColor($r('app.color.text_primary'))
      }
      .width(DesignTokens.TOUCH_TARGET)
      .height(DesignTokens.TOUCH_TARGET)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        try {
          this.getUIContext().getRouter().back();
        } catch (_error) {
          this.showToast('暂时无法返回上一页。');
        }
      })
      Text('大模型设置')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Blank()
    }
    .height(DesignTokens.TOOLBAR_HEIGHT)
    .padding({ left: 4, right: 16 })
  }

  @Builder
  private sectionTitle(title: string, detail: string) {
    Column({ space: 3 }) {
      Text(title)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text(detail)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private field(
    title: string,
    value: string,
    placeholder: string,
    onChange: (value: string) => void,
    password: boolean = false
  ) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .alignSelf(ItemAlign.Start)
      TextInput({
        text: value,
        placeholder: placeholder
      })
        .type(password ? InputType.Password : InputType.Normal)
        .height(48)
        .fontSize(15)
        .padding({ left: 14, right: 14 })
        .backgroundColor($r('app.color.background_secondary'))
        .borderRadius(13)
        .onChange(onChange)
    }
    .width('100%')
  }

  @Builder
  private keyStatus(saved: boolean, fallback: string, onClear: () => void) {
    Row({ space: 8 }) {
      Text(saved ? '已安全保存；输入新 Key 可覆盖' : fallback)
        .fontSize(12)
        .fontColor(saved ? '#30D158' : $r('app.color.text_secondary'))
        .layoutWeight(1)
      if (saved) {
        Button('清除')
          .height(34)
          .fontSize(12)
          .backgroundColor($r('app.color.background_secondary'))
          .fontColor($r('app.color.text_primary'))
          .onClick(onClear)
      }
    }
    .width('100%')
  }

  build() {
    Column() {
      this.header()

      Scroll() {
        Column({ space: 16 }) {
          this.sectionTitle('文本模型', 'OpenAI Chat Completions 兼容接口')
          this.field('Base URL', this.chatBaseURL, DEFAULT_CHAT_BASE_URL, (value) => {
            this.chatBaseURL = value;
          })
          this.field('模型', this.chatModel, DEFAULT_CHAT_MODEL, (value) => {
            this.chatModel = value;
          })
          this.field('API Key', this.chatAPIKey, 'sk-…', (value) => {
            this.chatAPIKey = value;
          }, true)
          this.keyStatus(
            this.hasSavedChatAPIKey,
            '尚未保存文本 API Key',
            () => this.clearChatAPIKey()
          )

          Divider().color($r('app.color.separator')).margin({ top: 4, bottom: 4 })

          this.sectionTitle('实时语音', '阿里云百炼 Qwen Realtime WebSocket')
          this.field('WebSocket URL', this.realtimeURL, DEFAULT_REALTIME_URL, (value) => {
            this.realtimeURL = value;
          })
          this.field('模型', this.realtimeModel, DEFAULT_REALTIME_MODEL, (value) => {
            this.realtimeModel = value;
          })
          this.field('音色', this.realtimeVoice, DEFAULT_REALTIME_VOICE, (value) => {
            this.realtimeVoice = value;
          })
          this.field('Realtime API Key', this.realtimeAPIKey, 'DASHSCOPE_API_KEY / sk-…', (value) => {
            this.realtimeAPIKey = value;
          }, true)
          this.keyStatus(
            this.hasSavedRealtimeAPIKey,
            '尚未保存实时语音 API Key',
            () => this.clearRealtimeAPIKey()
          )

          Divider().color($r('app.color.separator')).margin({ top: 4, bottom: 4 })

          this.sectionTitle('AI 生图', 'DashScope multimodal-generation 同步接口')
          this.field(
            '生图 URL',
            this.imageGenerationURL,
            DEFAULT_IMAGE_GENERATION_URL,
            (value) => {
              this.imageGenerationURL = value;
            }
          )
          this.field(
            '生图模型',
            this.imageGenerationModel,
            'qwen-image-edit',
            (value) => {
              this.imageGenerationModel = value;
            }
          )
          this.field(
            '生图 API Key',
            this.imageGenerationAPIKey,
            '留空时复用实时语音 Key',
            (value) => {
              this.imageGenerationAPIKey = value;
            },
            true
          )
          this.keyStatus(
            this.hasSavedImageGenerationAPIKey,
            '未设置专用 Key；将复用实时语音 Key',
            () => this.clearImageGenerationAPIKey()
          )
          Button('使用千问图像编辑默认配置')
            .width('100%')
            .height(42)
            .backgroundColor($r('app.color.background_secondary'))
            .fontColor($r('app.color.text_primary'))
            .onClick(() => this.applyQwenImageDefaults())

          TextArea({
            text: this.imageGenerationPrompt,
            placeholder: 'AI 生图默认提示词'
          })
            .height(132)
            .fontSize(15)
            .padding(14)
            .backgroundColor($r('app.color.background_secondary'))
            .borderRadius(13)
            .onChange((value: string) => {
              this.imageGenerationPrompt = value;
            })

          Text('模型可填写 qwen-image-edit、qwen-image-edit-plus 等。生图 Key 留空时自动复用上方实时语音 Key。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))

          Divider().color($r('app.color.separator')).margin({ top: 4, bottom: 4 })

          this.sectionTitle('系统 Prompt', '定义植物人格与回答边界')
          TextArea({
            text: this.systemPrompt,
            placeholder: '系统 Prompt'
          })
            .height(160)
            .fontSize(15)
            .padding(14)
            .backgroundColor($r('app.color.background_secondary'))
            .borderRadius(13)
            .onChange((value: string) => {
              this.systemPrompt = value;
            })

          Button('保存')
            .width('100%')
            .height(48)
            .onClick(async () => {
              await this.save();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 32 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background_primary'))
  }
}
