export class GeneratedPlantImage {
  id: string;
  imageUri: string;
  pixelWidth: number;
  pixelHeight: number;
  createdAtMs: number;
  prompt: string;

  constructor(
    id: string = '',
    imageUri: string = '',
    pixelWidth: number = 0,
    pixelHeight: number = 0,
    createdAtMs: number = 0,
    prompt: string = ''
  ) {
    this.id = id;
    this.imageUri = imageUri;
    this.pixelWidth = pixelWidth;
    this.pixelHeight = pixelHeight;
    this.createdAtMs = createdAtMs;
    this.prompt = prompt;
  }

  aspectRatio(fallback: number = 1): number {
    if (this.pixelWidth <= 0 || this.pixelHeight <= 0) {
      return fallback > 0 ? fallback : 1;
    }
    return this.pixelWidth / this.pixelHeight;
  }
}

export class GeneratedImageFrame {
  left: number;
  top: number;
  width: number;
  height: number;

  constructor(
    left: number = 0,
    top: number = 0,
    width: number = 0,
    height: number = 0
  ) {
    this.left = left;
    this.top = top;
    this.width = width;
    this.height = height;
  }

  isUsable(): boolean {
    return this.width > 0 && this.height > 0;
  }
}

export class GeneratedImagePreviewItem {
  image: GeneratedPlantImage;
  sourceFrame: GeneratedImageFrame;
  sourceCornerRadius: number;

  constructor(
    image: GeneratedPlantImage = new GeneratedPlantImage(),
    sourceFrame: GeneratedImageFrame = new GeneratedImageFrame(),
    sourceCornerRadius: number = 18
  ) {
    this.image = image;
    this.sourceFrame = sourceFrame;
    this.sourceCornerRadius = sourceCornerRadius;
  }
}
