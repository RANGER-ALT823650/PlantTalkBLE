import image from '@ohos.multimedia.image';
import { ChatBubble, ChatBubbleSide } from '../components/ChatBubble';
import {
  ChatImageAttachment,
  ChatMessage,
  ChatRole
} from '../model/PlantModels';
import { accentColorFor, accentColorWithAlpha } from '../theme/AppTheme';
import { DesignTokens } from '../theme/DesignTokens';

const EAGER_TRANSCRIPT_MESSAGE_LIMIT: number = 120;

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
          Text('▧')
            .fontSize(24)
            .fontColor($r('app.color.text_secondary'))
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

  /**
   * The initial message remains a separate prop so the existing home-to-chat
   * transition can keep working. Once persistence is wired, pass its stable ID
   * and timestamp as well as the stored transcript in `messages`.
   */
  @Prop initialMessage: string = '';
  @Prop initialMessageID: string = 'initial-message';
  @Prop initialMessageDateMs: number = Date.now();
  @Prop messages: ChatMessage[] = [];
  @Prop isWaitingForAssistant: boolean = false;
  onBack: () => void = () => {};
  onSend: (message: string) => void = () => {};

  /**
   * The root page should set a local exclusion flag from this callback and
   * refuse to begin a new page transition while it is true. The callback is
   * active only while a pointer is down in a multi-image horizontal strip.
   */
  onImageSwipeExclusionChanged: (excluded: boolean) => void =
    (_excluded: boolean): void => {};

  @State private draft: string = '';
  @State private menuExpanded: boolean = false;

  aboutToDisappear(): void {
    this.onImageSwipeExclusionChanged(false);
  }

  private submit(): void {
    const message = this.draft.trim();
    if (message.length === 0) {
      return;
    }
    this.draft = '';
    this.onSend(message);
  }

  private shouldRenderInitialMessage(): boolean {
    if (this.initialMessage.trim().length === 0) {
      return false;
    }
    return !this.messages.some(
      (message: ChatMessage): boolean => message.id === this.initialMessageID
    );
  }

  private transcriptMessageCount(): number {
    return this.messages.length + (this.shouldRenderInitialMessage() ? 1 : 0);
  }

  private hasTranscript(): boolean {
    return this.transcriptMessageCount() > 0;
  }

  private waitingForAssistant(): boolean {
    if (this.isWaitingForAssistant) {
      return true;
    }
    if (this.messages.length > 0) {
      return this.messages[this.messages.length - 1].role === ChatRole.USER;
    }
    return this.shouldRenderInitialMessage();
  }

  private normalizedTimestamp(timestampMs: number): number {
    return Number.isFinite(timestampMs) && timestampMs > 0
      ? timestampMs
      : Date.now();
  }

  private dayKey(timestampMs: number): string {
    const date = new Date(this.normalizedTimestamp(timestampMs));
    return `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`;
  }

  private dateHeader(timestampMs: number): string {
    const date = new Date(this.normalizedTimestamp(timestampMs));
    const weekdays: string[] = [
      '星期日',
      '星期一',
      '星期二',
      '星期三',
      '星期四',
      '星期五',
      '星期六'
    ];
    return `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日 ${weekdays[date.getDay()]}`;
  }

  private twoDigits(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  private timeLabel(timestampMs: number): string {
    const date = new Date(this.normalizedTimestamp(timestampMs));
    return `${this.twoDigits(date.getHours())}:${this.twoDigits(date.getMinutes())}`;
  }

  /**
   * Mirrors iOS `ConversationDateGrouping`: the first user message of each
   * local calendar day owns that day's centered header. Assistant/system rows
   * never consume a day.
   */
  private firstUserMessageIDs(): string[] {
    const seenDayKeys: string[] = [];
    const result: string[] = [];

    if (this.shouldRenderInitialMessage()) {
      const initialDay = this.dayKey(this.initialMessageDateMs);
      seenDayKeys.push(initialDay);
      result.push(this.initialMessageID);
    }

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
    } else if (event.type === TouchType.Up ||
      event.type === TouchType.Cancel) {
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
        Text('×')
          .fontSize(25)
          .fontColor($r('app.color.danger'))
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
      .accessibilityText(this.dateHeader(timestampMs))
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
  private initialMessageRow() {
    Column({ space: 6 }) {
      if (this.showsDateHeader(this.initialMessageID)) {
        this.dateHeaderRow(this.initialMessageDateMs)
      }
      ChatBubble({
        text: this.initialMessage,
        side: ChatBubbleSide.USER
      })
      this.messageTimestamp(
        this.initialMessageDateMs,
        ChatBubbleSide.USER
      )
    }
    .width('100%')
  }

  @Builder
  private messageRow(message: ChatMessage) {
    Column({ space: 6 }) {
      if (this.showsDateHeader(message.id)) {
        this.dateHeaderRow(message.createdAtMs)
      }

      if (message.imageAttachments.length > 0) {
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
  private thinkingRow() {
    Row({ space: 5 }) {
      Circle().width(7).height(7).fill('#80000000')
      Circle().width(7).height(7).fill('#52000000')
      Circle().width(7).height(7).fill('#33000000')
    }
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.surface_translucent'))
    .borderRadius(18)
    .alignSelf(ItemAlign.Start)
  }

  @Builder
  private eagerTranscript() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.shouldRenderInitialMessage()) {
          this.initialMessageRow()
        }

        ForEach(
          this.messages,
          (message: ChatMessage) => {
            if (message.id !== this.initialMessageID) {
              this.messageRow(message)
            }
          },
          (message: ChatMessage): string => message.id
        )

        if (this.waitingForAssistant()) {
          this.thinkingRow()
        }
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 20 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  @Builder
  private lazyTranscript() {
    List({ space: 12 }) {
      if (this.shouldRenderInitialMessage()) {
        ListItem() {
          this.initialMessageRow()
        }
      }

      ForEach(
        this.messages,
        (message: ChatMessage) => {
          if (message.id !== this.initialMessageID) {
            ListItem() {
              this.messageRow(message)
            }
          }
        },
        (message: ChatMessage): string => message.id
      )

      if (this.waitingForAssistant()) {
        ListItem() {
          this.thinkingRow()
        }
      }
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .padding({ left: 14, right: 14, top: 12, bottom: 20 })
  }

  @Builder
  private conversation() {
    if (!this.hasTranscript()) {
      Scroll() {
        this.emptyTranscript()
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    } else if (this.transcriptMessageCount() <= EAGER_TRANSCRIPT_MESSAGE_LIMIT) {
      this.eagerTranscript()
    } else {
      this.lazyTranscript()
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
        .onClick(() => {
          this.getUIContext().animateTo({
            duration: 420,
            curve: Curve.EaseInOut
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
          .borderRadius(22)
          .border({ width: 1, color: $r('app.color.separator') })
          .onChange((value: string) => {
            this.draft = value;
          })

        Button() {
          Text('↑')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
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
