import curves from '@ohos.curves';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import {
  AIConfigurationStore,
  DEFAULT_IMAGE_GENERATION_PROMPT
} from '../ai/AIConfigurationStore';
import { PlantImageGenerationClient } from '../ai/PlantImageGenerationClient';
import {
  PlantBleCallbacks,
  PlantBleConnectionState,
  PlantBleManager
} from '../ble/PlantBleManager';
import { HomeDashboard } from '../components/HomeDashboard';
import { PlantArtworkEditorOverlay } from '../components/PlantArtworkEditorOverlay';
import { GeneratedImageStore } from '../data/GeneratedImageStore';
import { PlantArtworkStore } from '../data/PlantArtworkStore';
import { RelationalHistoryRepository } from '../data/RelationalHistoryRepository';
import { GeneratedPlantImage } from '../model/GeneratedImageModels';
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
  @State private rootGestureBlockedAtStart: boolean = false;
  @State private textImageSwipeExclusionActive: boolean = false;
  @State private textPageActivated: boolean = false;
  @State private initialTextMessage: string = '';
  @State private reading: PlantReading | null = null;
  @State private bluetoothStatus: string = '未连接';
  @State private bluetoothConnected: boolean = false;
  @State private historySyncStatus: string = '等待连接后同步';
  @State private artworkUri: string = '';
  @State private artworkEditorPresented: boolean = false;
  @State private isGeneratingArtwork: boolean = false;
  @State private artworkGenerationPrompt: string = DEFAULT_IMAGE_GENERATION_PROMPT;
  @State private generatedImages: GeneratedPlantImage[] = [];
  @State private isLoadingGeneratedImages: boolean = true;

  private artworkGenerationSequence: number = 0;
  private bleRuntimeInitializationStarted: boolean = false;
  private bleManager: PlantBleManager | null = null;
  private imageGenerationClient: PlantImageGenerationClient =
    new PlantImageGenerationClient();

  aboutToAppear(): void {
    this.loadInitialLocalState();
  }

  private async loadInitialLocalState(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      this.isLoadingGeneratedImages = false;
      return;
    }
    const artwork = await PlantArtworkStore.load(context);
    if (artwork !== null) {
      this.artworkUri = artwork.imageUri;
    }
    this.generatedImages = GeneratedImageStore.loadAll(context);
    this.isLoadingGeneratedImages = false;
    try {
      this.artworkGenerationPrompt =
        AIConfigurationStore.load(context).imageGenerationPrompt;
    } catch (_error) {
      this.artworkGenerationPrompt = DEFAULT_IMAGE_GENERATION_PROMPT;
    }
    await this.prepareBleRuntime(context);
  }

  private async prepareBleRuntime(context: Context): Promise<void> {
    if (this.bleRuntimeInitializationStarted || this.bleManager !== null) {
      return;
    }
    this.bleRuntimeInitializationStarted = true;
    try {
      const repository = await RelationalHistoryRepository.open(context);
      const callbacks = new PlantBleCallbacks();
      callbacks.onConnectionStateChanged = (
        state: PlantBleConnectionState,
        title: string
      ): void => {
        this.bluetoothStatus = title;
        this.bluetoothConnected =
          state === PlantBleConnectionState.CONNECTED;
        if (
          state === PlantBleConnectionState.SCANNING ||
          state === PlantBleConnectionState.CONNECTED ||
          state === PlantBleConnectionState.UNAVAILABLE ||
          state === PlantBleConnectionState.ERROR
        ) {
          this.showToast(title);
        }
      };
      callbacks.onReading = (reading: PlantReading): void => {
        this.reading = reading;
      };
      callbacks.onHistoryStateChanged = (title: string): void => {
        this.historySyncStatus = title;
        if (title.startsWith('历史同步失败')) {
          this.showToast(title);
        }
      };
      this.bleManager = new PlantBleManager(
        context,
        repository,
        callbacks
      );
    } catch (error) {
      this.bleRuntimeInitializationStarted = false;
      const message = error instanceof Error && error.message.length > 0
        ? error.message
        : '未知错误';
      this.bluetoothStatus = `BLE 数据库初始化失败：${message}`;
      this.showToast(this.bluetoothStatus);
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // A transient toast failure must not alter persisted artwork state.
    }
  }

  private openArtworkEditor(): void {
    if (this.isGeneratingArtwork) {
      return;
    }
    const context = this.getUIContext().getHostContext();
    if (context !== undefined) {
      try {
        this.artworkGenerationPrompt =
          AIConfigurationStore.load(context).imageGenerationPrompt;
      } catch (_error) {
        this.artworkGenerationPrompt = DEFAULT_IMAGE_GENERATION_PROMPT;
      }
    }
    this.artworkEditorPresented = true;
  }

  private async chooseArtwork(): Promise<void> {
    // Clear the in-app editor before presenting the system picker. This avoids
    // the latest iOS bug class where a stale editor reappears after navigation.
    this.artworkEditorPresented = false;
    try {
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      options.isSearchSupported = true;
      options.isPhotoTakingSupported = true;
      options.isEditSupported = true;
      options.isOriginalSupported = true;
      const picker = new photoAccessHelper.PhotoViewPicker();
      const result = await picker.select(options);
      if (result.photoUris.length === 0) {
        return;
      }

      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        this.showToast('当前页面上下文不可用，无法保存所选图片。');
        return;
      }
      const artwork = await PlantArtworkStore.saveFromUri(
        context,
        result.photoUris[0]
      );
      this.artworkUri = artwork.imageUri;
    } catch (_error) {
      this.showToast('没有更改植物图片。');
    }
  }

  private async removeArtwork(): Promise<void> {
    this.artworkEditorPresented = false;
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    await PlantArtworkStore.clear(context);
    this.artworkUri = '';
  }

  private async startArtworkGeneration(prompt: string): Promise<void> {
    if (this.isGeneratingArtwork) {
      return;
    }
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      this.showToast('当前页面上下文不可用，暂时无法生图。');
      return;
    }

    this.artworkEditorPresented = false;
    const generationSequence = this.artworkGenerationSequence + 1;
    this.artworkGenerationSequence = generationSequence;
    this.isGeneratingArtwork = true;

    try {
      const configuration =
        AIConfigurationStore.imageGenerationConfiguration(context);
      const input = await PlantArtworkStore.readCurrentBytes(context);
      if (input === null) {
        throw new Error('请先选择一张植物图片。');
      }
      const result = await this.imageGenerationClient.generate(
        configuration,
        new Uint8Array(input),
        prompt
      );
      if (!this.isArtworkGenerationActive(generationSequence)) {
        return;
      }

      const galleryItem = await GeneratedImageStore.save(
        context,
        result.data,
        prompt
      );
      if (!this.isArtworkGenerationActive(generationSequence)) {
        return;
      }

      const generatedBuffer = new ArrayBuffer(result.data.byteLength);
      new Uint8Array(generatedBuffer).set(result.data);
      const artwork = await PlantArtworkStore.saveBytes(context, generatedBuffer);
      if (!this.isArtworkGenerationActive(generationSequence)) {
        return;
      }
      this.artworkUri = artwork.imageUri;
      if (galleryItem !== null) {
        this.generatedImages = [
          galleryItem,
          ...this.generatedImages.filter(
            (item: GeneratedPlantImage) => item.id !== galleryItem.id
          )
        ];
      }
    } catch (error) {
      if (this.isArtworkGenerationActive(generationSequence)) {
        const message = error instanceof Error && error.message.length > 0
          ? error.message
          : 'AI 生图失败，请检查网络和模型设置后重试。';
        this.showToast(message);
      }
    } finally {
      if (generationSequence === this.artworkGenerationSequence) {
        this.isGeneratingArtwork = false;
      }
    }
  }

  private isArtworkGenerationActive(sequence: number): boolean {
    return this.isGeneratingArtwork &&
      sequence === this.artworkGenerationSequence;
  }

  private cancelArtworkGeneration(): void {
    if (!this.isGeneratingArtwork) {
      return;
    }
    // The HTTP stack has no cancellation token on API 12. Invalidate the
    // generation identity so a late response can never replace restored art.
    this.artworkGenerationSequence += 1;
    this.isGeneratingArtwork = false;
    this.showToast('已取消 AI 生图；稍后返回的结果会被忽略。');
  }

  private reloadGeneratedImages(): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      this.generatedImages = [];
      this.isLoadingGeneratedImages = false;
      return;
    }
    this.generatedImages = GeneratedImageStore.loadAll(context);
    this.isLoadingGeneratedImages = false;
  }

  private deleteGeneratedImage(item: GeneratedPlantImage): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    GeneratedImageStore.delete(context, item.id);
    this.generatedImages = this.generatedImages.filter(
      (candidate: GeneratedPlantImage) => candidate.id !== item.id
    );
  }

  private async reuseGeneratedImage(item: GeneratedPlantImage): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    try {
      const sourcePath = item.imageUri.startsWith('file://')
        ? item.imageUri.substring('file://'.length)
        : item.imageUri;
      const artwork = await PlantArtworkStore.saveFromUri(context, sourcePath);
      this.artworkUri = artwork.imageUri;
      this.showToast('已复用到植物卡片。');
    } catch (_error) {
      this.showToast('复用图片失败，请刷新图库后重试。');
    }
  }

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
    try {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/AppSettingsPage'
      });
    } catch (_error) {
      // Navigation failures should not leave the root page interaction locked.
    }
  }

  private toggleBluetooth(): void {
    if (this.bleManager === null) {
      const context = this.getUIContext().getHostContext();
      if (
        context !== undefined &&
        !this.bleRuntimeInitializationStarted
      ) {
        this.prepareBleRuntime(context);
      }
      this.showToast('BLE 数据层仍在初始化，请稍后再试。');
      return;
    }
    this.bleManager.toggleConnection();
  }

  private openRealtimePlaceholder(): void {
    try {
      this.getUIContext().getPromptAction().showToast({
        message: 'Realtime 音频与 Orb 联动将在语音阶段接入。'
      });
    } catch (_error) {
      // The placeholder remains safe when the system prompt service is unavailable.
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      HistoryOverviewPage({
        generatedImages: this.generatedImages,
        isLoadingGeneratedImages: this.isLoadingGeneratedImages,
        onBack: () => this.moveTo(RootPage.HOME),
        onRefreshGeneratedImages: () => this.reloadGeneratedImages(),
        onDeleteGeneratedImage: (item: GeneratedPlantImage) =>
          this.deleteGeneratedImage(item),
        onReuseGeneratedImage: async (item: GeneratedPlantImage) => {
          await this.reuseGeneratedImage(item);
        }
      })
        .width('100%')
        .height('100%')
        .translate({ x: this.pageOffset(RootPage.HISTORY) })

      HomeDashboard({
        reading: this.reading,
        bluetoothStatus: this.bluetoothStatus,
        bluetoothConnected: this.bluetoothConnected,
        artworkUri: this.artworkUri,
        isGeneratingArtwork: this.isGeneratingArtwork,
        interactionSuppressed: this.currentPage !== RootPage.HOME || this.isSettling,
        motionPaused: this.currentPage !== RootPage.HOME || this.isSettling,
        onOpenHistory: () => this.moveTo(RootPage.HISTORY),
        onToggleBluetooth: () => this.toggleBluetooth(),
        onOpenSettings: () => this.openSettings(),
        onSendText: (message: string) => this.startTextConversation(message),
        onOpenRealtime: () => this.openRealtimePlaceholder(),
        onEditArtwork: () => this.openArtworkEditor(),
        onCancelArtworkGeneration: () => this.cancelArtworkGeneration()
      })
        .width('100%')
        .height('100%')
        .translate({ x: this.pageOffset(RootPage.HOME) })

      if (this.textPageActivated) {
        TextConversationPage({
          initialMessage: this.initialTextMessage,
          onBack: () => this.moveTo(RootPage.HOME),
          onSend: (_message: string) => {},
          onImageSwipeExclusionChanged: (active: boolean) => {
            this.textImageSwipeExclusionActive = active;
          }
        })
          .width('100%')
          .height('100%')
          .translate({ x: this.pageOffset(RootPage.TEXT) })
      }

      if (this.artworkEditorPresented) {
        PlantArtworkEditorOverlay({
          hasArtwork: this.artworkUri.length > 0,
          defaultPrompt: this.artworkGenerationPrompt,
          onChooseArtwork: async () => {
            await this.chooseArtwork();
          },
          onGenerateArtwork: async (prompt: string) => {
            await this.startArtworkGeneration(prompt);
          },
          onRemoveArtwork: async () => {
            await this.removeArtwork();
          },
          onDismiss: () => {
            this.artworkEditorPresented = false;
          }
        })
          .width('100%')
          .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background_primary'))
    .clip(true)
    .onAreaChange((_oldArea, newArea) => {
      const measuredWidth = Number.parseFloat(newArea.width.toString());
      if (measuredWidth > 0) {
        if (Math.abs(measuredWidth - this.pageWidth) > 1) {
          // A fold/unfold resize invalidates translations measured against the
          // previous page width. Resolve to the current page before relayout.
          this.dragTranslation = 0;
          this.gestureAccepted = false;
          this.rootGestureBlockedAtStart = false;
          this.isSettling = false;
        }
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
            // Decide ownership once at gesture start. If a root transition has
            // already begun, a later child-state change must not interrupt its
            // spring convergence.
            this.rootGestureBlockedAtStart =
              this.artworkEditorPresented ||
              this.currentPage === RootPage.TEXT &&
              this.textImageSwipeExclusionActive;
          }
        })
        .onActionUpdate((event: GestureEvent) => {
          if (!this.isSettling) {
            if (this.rootGestureBlockedAtStart) {
              return;
            }
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
            if (!this.rootGestureBlockedAtStart &&
              this.gestureAccepted &&
              this.dragTranslation !== 0) {
              this.finishGesture(event);
            } else {
              this.dragTranslation = 0;
            }
            this.gestureAccepted = false;
            this.rootGestureBlockedAtStart = false;
          }
        })
        .onActionCancel(() => {
          if (!this.isSettling) {
            this.rootGestureBlockedAtStart = false;
            this.cancelGesture();
          }
        })
    )
  }
}
