import { accentColorFor, accentColorWithAlpha } from '../theme/AppTheme';
import { DesignTokens } from '../theme/DesignTokens';
import { ChatBubble, ChatBubbleSide } from '../components/ChatBubble';

@Component
export struct TextConversationPage {
  @StorageLink('appTheme') appTheme: string = 'blue';
  @Prop initialMessage: string = '';
  onBack: () => void = () => {};
  onSend: (message: string) => void = () => {};

  @State private draft: string = '';
  @State private menuExpanded: boolean = false;

  private submit(): void {
    const message = this.draft.trim();
    if (message.length === 0) {
      return;
    }
    this.draft = '';
    this.onSend(message);
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
  private conversation() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.initialMessage.length === 0) {
          Column({ space: 10 }) {
            Text('🌿')
              .fontSize(40)
            Text('和植物说点什么吧')
              .fontSize(17)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .margin({ top: 72 })
        } else {
          ChatBubble({
            text: this.initialMessage,
            side: ChatBubbleSide.USER
          })

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
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 20 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
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
