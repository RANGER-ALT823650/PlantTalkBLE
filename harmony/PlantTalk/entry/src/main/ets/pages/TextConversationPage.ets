import image from '@ohos.multimedia.image';
import curves from '@ohos.curves';
import { ChatBubble, ChatBubbleSide } from '../components/ChatBubble';
import {
  AIConfigurationStore,
  DEFAULT_SYSTEM_PROMPT
} from '../ai/AIConfigurationStore';
import { OpenAICompatibleClient } from '../ai/OpenAICompatibleClient';
import { ConversationRepository } from '../data/ConversationRepository';
import { RelationalConversationRepository } from '../data/RelationalConversationRepository';
import { RelationalHistoryRepository } from '../data/RelationalHistoryRepository';
import {
  AIConversation,
  AIConversationKind,
  ChatImageAttachment,
  ChatMessage,
  ChatRole
} from '../model/PlantModels';
import { accentColorFor, accentColorWithAlpha } from '../theme/AppTheme';
import { DesignTokens } from '../theme/DesignTokens';

const EAGER_TRANSCRIPT_MESSAGE_LIMIT: number = 120;

@Component
struct ModelThinkingIndicator {
  @State private activeDot: number = 0;
  private timer: number | null = null;

  aboutToAppear(): void {
    this.timer = setInterval(() => {
      this.getUIContext().animateTo({
        duration: 180,
        curve: Curve.EaseInOut
      }, () => {
        this.activeDot = (this.activeDot + 1) % 3;
      });
    }, 180);
  }

  aboutToDisappear(): void {
    if (this.timer !== null) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  build() {
    Row({ space: 6 }) {
      ForEach([0, 1, 2], (index: number) => {
        Circle()
          .width(7)
          .height(7)
          .fill($r('app.color.text_secondary'))
          .scale({
            x: this.activeDot === index ? 1.0 : 0.65,
            y: this.activeDot === index ? 1.0 : 0.65
          })
          .translate({ y: this.activeDot === index ? -2 : 1 })
          .opacity(this.activeDot === index ? 1.0 : 0.5)
      }, (idx: number) => idx.toString())
    }
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.surface_translucent'))
    .backgroundBlurStyle(BlurStyle.Thin)
    .borderRadius(18)
    .alignSelf(ItemAlign.Start)
  }
}

@Component
struct ConversationAttachmentThumbnail {
  @Prop attachment: ChatImageAttachment =
    new ChatImageAttachment('', 'image/jpeg', new Uint8Array());
  @State private pixelMap: image.PixelMap | null = null;
  private isActive: boolean = false;

  aboutToAppear(): void {
    this.isActive = true;
    this.decodeThumbnail();
  }

  aboutToDisappear(): void {
    this.isActive = false;
    if (this.pixelMap !== null) {
      this.pixelMap.release();
      this.pixelMap = null;
    }
  }

  private async decodeThumbnail(): Promise<void> {
    if (this.attachment.data.length === 0) {
      return;
    }

    const encoded = new Uint8Array(this.attachment.data.length);
    encoded.set(this.attachment.data);
    const source = image.createImageSource(encoded.buffer);
    try {
      const decoded = await source.createPixelMap({
        desiredSize: {
          width: 240,
          height: 240
        }
      });
      if (!this.isActive) {
        decoded.release();
        return;
      }
      if (this.pixelMap !== null) {
        this.pixelMap.release();
      }
      this.pixelMap = decoded;
    } catch (_error) {
      // Keep the deterministic placeholder when a legacy attachment is corrupt.
    } finally {
      await source.release();
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.pixelMap !== null) {
        Image(this.pixelMap)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        Column({ space: 4 }) {
          Text('图片')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
        }
      }
    }
    .width(84)
    .height(84)
    .backgroundColor($r('app.color.background_secondary'))
    .borderRadius(14)
    .clip(true)
  }
}

@Component
export struct TextConversationPage {
  @StorageLink('appTheme') appTheme: string = 'blue';

  @Prop @Watch('onInitialMessageChanged') initialMessage: string = '';
  onBack: () => void = () => {};
  onSend: (message: string) => void = () => {};
  onImageSwipeExclusionChanged: (excluded: boolean) => void = (_excluded: boolean): void => {};

  @State private messages: ChatMessage[] = [];
  @State private draft: string = '';
  @State private menuExpanded: boolean = false;
  @State private isWaitingForAssistant: boolean = false;
  @State private activeConversation: AIConversation | null = null;

  private repository: ConversationRepository | null = null;
  private isProcessingInitial: boolean = false;

  aboutToAppear(): void {
    this.initDatabaseAndLoad();
  }

  aboutToDisappear(): void {
    this.onImageSwipeExclusionChanged(false);
  }

  private async initDatabaseAndLoad(): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx) {
      try {
        const historyRepo = await RelationalHistoryRepository.open(ctx);
        this.repository = new RelationalConversationRepository(historyRepo.getStore());
        const conv = await this.repository.getOrCreateDefaultConversation(AIConversationKind.TEXT);
        this.activeConversation = conv;
        this.messages = await this.repository.chatMessages(conv.id);

        if (this.initialMessage.trim().length > 0 && !this.isProcessingInitial) {
          const initText = this.initialMessage;
          this.initialMessage = '';
          this.submitMessage(initText);
        }
      } catch (err) {
        console.error('[TextConversationPage] Init DB failed:', JSON.stringify(err));
      }
    }
  }

  private onInitialMessageChanged(): void {
    if (this.initialMessage.trim().length > 0 && this.repository && this.activeConversation) {
      const initText = this.initialMessage;
      this.initialMessage = '';
      this.submitMessage(initText);
    }
  }

  private async submitMessage(text: string): Promise<void> {
    const trimmed = text.trim();
    if (trimmed.length === 0 || !this.activeConversation || !this.repository) {
      return;
    }

    const convId = this.activeConversation.id;
    const now = Date.now();
    const userMsg = new ChatMessage(
      `${now}-${Math.random().toString(36).substring(2, 7)}`,
      convId,
      ChatRole.USER,
      trimmed,
      now
    );

    this.messages = [...this.messages, userMsg];
    await this.repository.saveChatMessage(userMsg);
    this.onSend(trimmed);

    // Trigger AI streaming response
    this.isWaitingForAssistant = true;

    const ctx = this.getUIContext().getHostContext();
    let baseURL = 'https://api.openai.com/v1';
    let model = 'gpt-4.1-mini';
    let systemPrompt = DEFAULT_SYSTEM_PROMPT;
    let apiKey: string | null = null;

    if (ctx) {
      try {
        const settings = AIConfigurationStore.load(ctx);
        baseURL = settings.chatBaseURL;
        model = settings.chatModel;
        systemPrompt = settings.systemPrompt;
        apiKey = AIConfigurationStore.getChatAPIKey();
      } catch (_e) {}
    }

    if (!apiKey || apiKey.trim().length === 0) {
      this.isWaitingForAssistant = false;
      const fallbackMsg = new ChatMessage(
        `${Date.now()}-fallback`,
        convId,
        ChatRole.ASSISTANT,
        '（未配置 AI API Key。请在「设置 → 大模型设置」中配置 API Key 后与我交流。）',
        Date.now()
      );
      this.messages = [...this.messages, fallbackMsg];
      await this.repository.saveChatMessage(fallbackMsg);
      return;
    }

    const assistantMsgId = `${Date.now()}-${Math.random().toString(36).substring(2, 7)}`;
    let assistantMsg: ChatMessage | null = null;

    try {
      await OpenAICompatibleClient.streamChatCompletions({
        baseURL: baseURL,
        apiKey: apiKey,
        model: model,
        systemPrompt: systemPrompt,
        messages: this.messages,
        onDelta: (_chunk: string, fullText: string) => {
          if (this.isWaitingForAssistant) {
            this.isWaitingForAssistant = false;
          }
          if (!assistantMsg) {
            assistantMsg = new ChatMessage(
              assistantMsgId,
              convId,
              ChatRole.ASSISTANT,
              fullText,
              Date.now()
            );
            this.messages = [...this.messages, assistantMsg];
          } else {
            assistantMsg.content = fullText;
            // Force state array trigger for reactive UI update
            this.messages = [...this.messages.slice(0, -1), assistantMsg];
          }
        }
      });

      if (assistantMsg && this.repository) {
        await this.repository.saveChatMessage(assistantMsg);
      }
    } catch (err) {
      this.isWaitingForAssistant = false;
      const errMsgStr = err instanceof Error ? err.message : '与 AI 通信发生异常';
      const errorMsg = new ChatMessage(
        `${Date.now()}-err`,
        convId,
        ChatRole.ASSISTANT,
        `（请求失败: ${errMsgStr}）`,
        Date.now()
      );
      this.messages = [...this.messages, errorMsg];
      if (this.repository) {
        await this.repository.saveChatMessage(errorMsg);
      }
    }
  }

  private submit(): void {
    const text = this.draft.trim();
    if (text.length === 0) {
      return;
    }
    this.draft = '';
    this.submitMessage(text);
  }

  private dayKey(timestampMs: number): string {
    const date = new Date(timestampMs > 0 ? timestampMs : Date.now());
    return `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`;
  }

  private dateHeader(timestampMs: number): string {
    const date = new Date(timestampMs > 0 ? timestampMs : Date.now());
    const weekdays: string[] = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
    return `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日 ${weekdays[date.getDay()]}`;
  }

  private twoDigits(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  private timeLabel(timestampMs: number): string {
    const date = new Date(timestampMs > 0 ? timestampMs : Date.now());
    return `${this.twoDigits(date.getHours())}:${this.twoDigits(date.getMinutes())}`;
  }

  private firstUserMessageIDs(): string[] {
    const seenDayKeys: string[] = [];
    const result: string[] = [];

    this.messages.forEach((message: ChatMessage): void => {
      if (message.role !== ChatRole.USER) {
        return;
      }
      const key = this.dayKey(message.createdAtMs);
      if (seenDayKeys.indexOf(key) >= 0) {
        return;
      }
      seenDayKeys.push(key);
      result.push(message.id);
    });

    return result;
  }

  private showsDateHeader(messageID: string): boolean {
    return this.firstUserMessageIDs().indexOf(messageID) >= 0;
  }

  private sideFor(role: ChatRole): ChatBubbleSide {
    return role === ChatRole.USER
      ? ChatBubbleSide.USER
      : ChatBubbleSide.ASSISTANT;
  }

  private handleImageStripTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.onImageSwipeExclusionChanged(true);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.onImageSwipeExclusionChanged(false);
    }
  }

  @Builder
  private header() {
    Row() {
      Text('Plant Talk')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Blank()
      Button() {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(20)
          .fontColor([$r('app.color.danger')])
      }
      .width(DesignTokens.TOUCH_TARGET)
      .height(DesignTokens.TOUCH_TARGET)
      .backgroundColor(Color.Transparent)
      .onClick(this.onBack)
    }
    .height(DesignTokens.TOOLBAR_HEIGHT)
    .padding({ left: 20, right: 12 })
  }

  @Builder
  private emptyTranscript() {
    Column({ space: 10 }) {
      Text('🌿')
        .fontSize(40)
      Text('和植物说点什么吧')
        .fontSize(17)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .margin({ top: 72 })
  }

  @Builder
  private dateHeaderRow(timestampMs: number) {
    Text(this.dateHeader(timestampMs))
      .width('100%')
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary'))
      .textAlign(TextAlign.Center)
  }

  @Builder
  private attachmentStrip(
    attachments: ChatImageAttachment[],
    side: ChatBubbleSide
  ) {
    Row() {
      if (side === ChatBubbleSide.USER) {
        Blank().width(48)
      }

      if (attachments.length > 1) {
        List({ space: 8 }) {
          ForEach(
            attachments,
            (attachment: ChatImageAttachment) => {
              ListItem() {
                ConversationAttachmentThumbnail({ attachment: attachment })
              }
            },
            (attachment: ChatImageAttachment): string => attachment.id
          )
        }
        .listDirection(Axis.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .constraintSize({
          maxWidth: Math.min(attachments.length * 92, 276)
        })
        .height(84)
        .onTouch((event: TouchEvent) => {
          this.handleImageStripTouch(event);
        })
      } else if (attachments.length === 1) {
        ConversationAttachmentThumbnail({ attachment: attachments[0] })
      }

      if (side === ChatBubbleSide.ASSISTANT) {
        Blank().width(48)
      }
    }
    .width('100%')
    .justifyContent(
      side === ChatBubbleSide.USER ? FlexAlign.End : FlexAlign.Start
    )
  }

  @Builder
  private messageTimestamp(timestampMs: number, side: ChatBubbleSide) {
    Row() {
      if (side === ChatBubbleSide.USER) {
        Blank()
      }
      Text(this.timeLabel(timestampMs))
        .fontSize(10)
        .fontColor($r('app.color.text_secondary'))
      if (side === ChatBubbleSide.ASSISTANT) {
        Blank()
      }
    }
    .width('100%')
    .padding({ left: 8, right: 8 })
  }

  @Builder
  private messageRow(message: ChatMessage) {
    Column({ space: 6 }) {
      if (this.showsDateHeader(message.id)) {
        this.dateHeaderRow(message.createdAtMs)
      }

      if (message.imageAttachments && message.imageAttachments.length > 0) {
        this.attachmentStrip(
          message.imageAttachments,
          this.sideFor(message.role)
        )
      }

      if (message.content.trim().length > 0) {
        ChatBubble({
          text: message.content,
          side: this.sideFor(message.role)
        })
      }

      this.messageTimestamp(
        message.createdAtMs,
        this.sideFor(message.role)
      )
    }
    .width('100%')
  }

  @Builder
  private conversation() {
    if (this.messages.length === 0 && !this.isWaitingForAssistant) {
      Scroll() {
        this.emptyTranscript()
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    } else if (this.messages.length <= EAGER_TRANSCRIPT_MESSAGE_LIMIT) {
      Scroll() {
        Column({ space: 12 }) {
          ForEach(
            this.messages,
            (message: ChatMessage) => {
              this.messageRow(message)
            },
            (message: ChatMessage): string => message.id
          )

          if (this.isWaitingForAssistant) {
            ModelThinkingIndicator()
          }
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    } else {
      List({ space: 12 }) {
        ForEach(
          this.messages,
          (message: ChatMessage) => {
            ListItem() {
              this.messageRow(message)
            }
          },
          (message: ChatMessage): string => message.id
        )

        if (this.isWaitingForAssistant) {
          ListItem() {
            ModelThinkingIndicator()
          }
        }
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ left: 14, right: 14, top: 12, bottom: 20 })
    }
  }

  @Builder
  private attachmentMenu() {
    if (this.menuExpanded) {
      Row({ space: 10 }) {
        Button('退出')
          .fontColor(Color.White)
          .backgroundColor($r('app.color.danger'))
          .onClick(this.onBack)
        Button('相机')
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.background_secondary'))
        Button('相册')
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.background_secondary'))
      }
      .width('100%')
      .transition(
        TransitionEffect
          .OPACITY
          .combine(TransitionEffect.translate({ x: -24 }))
      )
    }
  }

  @Builder
  private composer() {
    Column({ space: 8 }) {
      this.attachmentMenu()

      Row({ space: 10 }) {
        Button() {
          Text(this.menuExpanded ? '×' : '+')
            .fontSize(24)
            .fontColor($r('app.color.text_primary'))
        }
        .width(46)
        .height(46)
        .borderRadius(23)
        .backgroundColor($r('app.color.surface_translucent'))
        .backgroundBlurStyle(BlurStyle.Thin)
        .onClick(() => {
          this.getUIContext().animateTo({
            duration: 420,
            curve: curves.springMotion(0.42, 0.82)
          }, () => {
            this.menuExpanded = !this.menuExpanded;
          });
        })

        TextArea({
          placeholder: '消息',
          text: this.draft
        })
          .layoutWeight(1)
          .maxLines(5)
          .padding({ left: 16, right: 16, top: 9, bottom: 9 })
          .backgroundColor($r('app.color.surface_translucent'))
          .backgroundBlurStyle(BlurStyle.Thin)
          .borderRadius(22)
          .border({ width: 1, color: $r('app.color.separator') })
          .onChange((value: string) => {
            this.draft = value;
          })

        Button() {
          SymbolGlyph($r('sys.symbol.arrow_up'))
            .fontSize(20)
            .fontColor([Color.White])
        }
        .width(46)
        .height(46)
        .borderRadius(23)
        .enabled(this.draft.trim().length > 0)
        .opacity(this.draft.trim().length > 0 ? 1 : 0.45)
        .backgroundColor(accentColorFor(this.appTheme))
        .onClick(() => this.submit())
      }
      .width('100%')
    }
    .padding({ left: 12, right: 12, top: 8, bottom: 12 })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Circle()
        .width(420)
        .height(420)
        .fill(accentColorWithAlpha(this.appTheme, '29'))
        .position({ x: '72%', y: -190 })
      Circle()
        .width(380)
        .height(380)
        .fill('#1A30D158')
        .position({ x: -190, y: '72%' })

      Column() {
        this.header()
        this.conversation()
        this.composer()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: DesignTokens.CONVERSATION_MAX_WIDTH })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background_primary'))
  }
}
