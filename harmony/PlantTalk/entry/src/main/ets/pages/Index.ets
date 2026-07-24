import curves from '@ohos.curves';
import { HomeDashboard } from '../components/HomeDashboard';
import { PlantReading } from '../model/PlantModels';
import { DesignTokens } from '../theme/DesignTokens';
import { HistoryOverviewPage } from './HistoryOverviewPage';
import { TextConversationPage } from './TextConversationPage';

enum RootPage {
  HISTORY = -1,
  HOME = 0,
  TEXT = 1
}

@Entry
@Component
struct Index {
  @StorageLink('reduceMotion') reduceMotion: boolean = false;
  @State private currentPage: RootPage = RootPage.HOME;
  @State private pageWidth: number = 360;
  @State private dragTranslation: number = 0;
  @State private isSettling: boolean = false;
  @State private gestureAccepted: boolean = false;
  @State private textPageActivated: boolean = false;
  @State private initialTextMessage: string = '';
  @State private reading: PlantReading | null = null;

  private pageOffset(page: RootPage): number {
    return (page - this.currentPage) * this.pageWidth + this.dragTranslation;
  }

  private moveTo(page: RootPage, buttonTriggered: boolean = true): void {
    if (this.isSettling || page === this.currentPage) {
      return;
    }
    this.isSettling = true;
    this.getUIContext().animateTo({
      duration: this.reduceMotion
        ? (buttonTriggered ? 200 : 160)
        : (buttonTriggered ? 350 : 0),
      curve: this.reduceMotion
        ? (buttonTriggered ? Curve.EaseInOut : Curve.EaseOut)
        : buttonTriggered
        ? curves.springMotion(0.35, 1.0)
        : curves.responsiveSpringMotion(
          DesignTokens.PAGE_SPRING_RESPONSE,
          DesignTokens.PAGE_SPRING_DAMPING
        ),
      onFinish: () => {
        this.isSettling = false;
      }
    }, () => {
      this.currentPage = page;
      this.dragTranslation = 0;
    });
  }

  private startTextConversation(message: string): void {
    this.initialTextMessage = message;
    this.textPageActivated = true;
    this.moveTo(RootPage.TEXT);
  }

  private allowedTranslation(rawTranslation: number): number {
    if (this.currentPage === RootPage.HOME) {
      if (rawTranslation > 0) {
        return Math.min(this.pageWidth, rawTranslation);
      }
      if (this.textPageActivated) {
        return Math.max(-this.pageWidth, rawTranslation);
      }
      return 0;
    }
    if (this.currentPage === RootPage.HISTORY) {
      return Math.max(-this.pageWidth, Math.min(0, rawTranslation));
    }
    return Math.min(this.pageWidth, Math.max(0, rawTranslation));
  }

  private finishGesture(event: GestureEvent): void {
    const translation = this.dragTranslation;
    const predictedTranslation = translation + event.velocityX * 0.2;
    const crossedDistance =
      Math.abs(translation) > this.pageWidth * DesignTokens.PAGE_DISTANCE_THRESHOLD;
    const crossedPrediction =
      Math.abs(translation) > DesignTokens.PAGE_DRAG_DISTANCE &&
      Math.abs(predictedTranslation) > this.pageWidth * DesignTokens.PAGE_PREDICTED_THRESHOLD;

    let destination = this.currentPage;
    if (crossedDistance || crossedPrediction) {
      if (translation > 0) {
        destination = this.currentPage === RootPage.TEXT
          ? RootPage.HOME
          : RootPage.HISTORY;
      } else if (translation < 0) {
        destination = this.currentPage === RootPage.HISTORY
          ? RootPage.HOME
          : RootPage.TEXT;
      }
    }

    this.settlePage(destination);
  }

  private settlePage(destination: RootPage): void {
    this.isSettling = true;
    this.getUIContext().animateTo({
      duration: this.reduceMotion ? 160 : 0,
      curve: this.reduceMotion
        ? Curve.EaseOut
        : curves.responsiveSpringMotion(
          DesignTokens.PAGE_SPRING_RESPONSE,
          DesignTokens.PAGE_SPRING_DAMPING
        ),
      onFinish: () => {
        this.isSettling = false;
      }
    }, () => {
      this.currentPage = destination;
      this.dragTranslation = 0;
    });
  }

  private cancelGesture(): void {
    this.gestureAccepted = false;
    if (this.dragTranslation === 0) {
      return;
    }
    this.settlePage(this.currentPage);
  }

  private openSettings(): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/AppSettingsPage'
    });
  }

  private toggleBluetoothPlaceholder(): void {
    this.getUIContext().getPromptAction().showToast({
      message: 'BLE 协议层已迁移；安装 Harmony SDK 后接入 GATT Central。'
    });
  }

  private openRealtimePlaceholder(): void {
    this.getUIContext().getPromptAction().showToast({
      message: 'Realtime 音频与 Orb 联动将在语音阶段接入。'
    });
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      HistoryOverviewPage({
        onBack: () => this.moveTo(RootPage.HOME)
      })
        .width('100%')
        .height('100%')
        .translate({ x: this.pageOffset(RootPage.HISTORY) })

      HomeDashboard({
        reading: this.reading,
        interactionSuppressed: this.currentPage !== RootPage.HOME || this.isSettling,
        motionPaused: this.currentPage !== RootPage.HOME || this.isSettling,
        onOpenHistory: () => this.moveTo(RootPage.HISTORY),
        onToggleBluetooth: () => this.toggleBluetoothPlaceholder(),
        onOpenSettings: () => this.openSettings(),
        onSendText: (message: string) => this.startTextConversation(message),
        onOpenRealtime: () => this.openRealtimePlaceholder()
      })
        .width('100%')
        .height('100%')
        .translate({ x: this.pageOffset(RootPage.HOME) })

      if (this.textPageActivated) {
        TextConversationPage({
          initialMessage: this.initialTextMessage,
          onBack: () => this.moveTo(RootPage.HOME),
          onSend: (_message: string) => {}
        })
          .width('100%')
          .height('100%')
          .translate({ x: this.pageOffset(RootPage.TEXT) })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background_primary'))
    .clip(true)
    .onAreaChange((_oldArea, newArea) => {
      const measuredWidth = Number.parseFloat(newArea.width.toString());
      if (measuredWidth > 0) {
        this.pageWidth = measuredWidth;
      }
    })
    .gesture(
      PanGesture({
        direction: PanDirection.Horizontal,
        distance: DesignTokens.PAGE_DRAG_DISTANCE
      })
        .onActionStart(() => {
          if (!this.isSettling) {
            this.dragTranslation = 0;
            this.gestureAccepted = false;
          }
        })
        .onActionUpdate((event: GestureEvent) => {
          if (!this.isSettling) {
            if (!this.gestureAccepted) {
              this.gestureAccepted =
                Math.abs(event.offsetX) > Math.abs(event.offsetY) * 1.25;
            }
            if (!this.gestureAccepted) {
              return;
            }
            this.dragTranslation = this.allowedTranslation(event.offsetX);
          }
        })
        .onActionEnd((event: GestureEvent) => {
          if (!this.isSettling) {
            if (this.gestureAccepted && this.dragTranslation !== 0) {
              this.finishGesture(event);
            } else {
              this.dragTranslation = 0;
            }
            this.gestureAccepted = false;
          }
        })
        .onActionCancel(() => {
          if (!this.isSettling) {
            this.cancelGesture();
          }
        })
    )
  }
}
