import { accentColorFor } from '../theme/AppTheme';

export enum ChatBubbleSide {
  ASSISTANT = 'assistant',
  USER = 'user'
}

@Component
export struct ChatBubble {
  @StorageLink('appTheme') appTheme: string = 'blue';
  @Prop text: string = '';
  @Prop side: ChatBubbleSide = ChatBubbleSide.ASSISTANT;

  build() {
    Row() {
      if (this.side === ChatBubbleSide.USER) {
        Blank().width(48)
      }

      Text(this.text)
        .fontSize(16)
        .lineHeight(23)
        .fontColor(
          this.side === ChatBubbleSide.USER
            ? Color.White
            : $r('app.color.text_primary')
        )
        .padding({ left: 16, right: 16, top: 11, bottom: 11 })
        .backgroundColor(
          this.side === ChatBubbleSide.USER
            ? accentColorFor(this.appTheme)
            : $r('app.color.surface_translucent')
        )
        .border({
          width: 0.5,
          color: this.side === ChatBubbleSide.USER
            ? accentColorFor(this.appTheme)
            : $r('app.color.separator')
        })
        .borderRadius(18)
        .constraintSize({ maxWidth: '82%' })

      if (this.side === ChatBubbleSide.ASSISTANT) {
        Blank().width(48)
      }
    }
    .width('100%')
    .justifyContent(
      this.side === ChatBubbleSide.USER
        ? FlexAlign.End
        : FlexAlign.Start
    )
  }
}
