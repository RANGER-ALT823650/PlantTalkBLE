import { DesignTokens } from '../theme/DesignTokens';

@Entry
@Component
struct AISettingsPage {
  @State private chatBaseURL: string = 'https://api.openai.com/v1';
  @State private chatModel: string = 'gpt-4.1-mini';
  @State private chatAPIKey: string = '';
  @State private realtimeURL: string =
    'wss://dashscope.aliyuncs.com/api-ws/v1/realtime';
  @State private realtimeModel: string = 'qwen3.5-omni-flash-realtime';
  @State private realtimeVoice: string = 'Tina';
  @State private realtimeAPIKey: string = '';
  @State private systemPrompt: string =
    '你是这株植物的温柔伙伴。结合传感器数据回答，但不要编造不存在的读数。';

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
      .onClick(() => this.getUIContext().getRouter().back())
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

  build() {
    Column() {
      this.header()

      Scroll() {
        Column({ space: 16 }) {
          this.sectionTitle('文本模型', 'OpenAI Chat Completions 兼容接口')
          this.field('Base URL', this.chatBaseURL, 'https://api.openai.com/v1', (value) => {
            this.chatBaseURL = value;
          })
          this.field('模型', this.chatModel, 'gpt-4.1-mini', (value) => {
            this.chatModel = value;
          })
          this.field('API Key', this.chatAPIKey, '仅保存在安全存储中', (value) => {
            this.chatAPIKey = value;
          }, true)

          Divider().color($r('app.color.separator')).margin({ top: 4, bottom: 4 })

          this.sectionTitle('实时语音', '阿里云百炼 Qwen Realtime WebSocket')
          this.field('WebSocket URL', this.realtimeURL, 'wss://…', (value) => {
            this.realtimeURL = value;
          })
          this.field('模型', this.realtimeModel, 'qwen3.5-omni-flash-realtime', (value) => {
            this.realtimeModel = value;
          })
          this.field('音色', this.realtimeVoice, 'Tina', (value) => {
            this.realtimeVoice = value;
          })
          this.field('Realtime API Key', this.realtimeAPIKey, '独立于文本 API Key', (value) => {
            this.realtimeAPIKey = value;
          }, true)

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
            .onClick(() => {
              this.getUIContext().getPromptAction().showToast({
                message: '界面字段已就绪；安全存储适配将在 AI 接入阶段启用。'
              });
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
