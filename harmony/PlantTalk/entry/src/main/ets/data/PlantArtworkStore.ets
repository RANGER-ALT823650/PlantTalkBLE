import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';

const DIRECTORY_NAME: string = 'PlantArtwork';
const IMAGE_FILE_NAME: string = 'current-image.jpg';
const METADATA_FILE_NAME: string = 'metadata.json';
const IMAGE_TEMP_FILE_NAME: string = 'current-image.jpg.tmp';
const METADATA_TEMP_FILE_NAME: string = 'metadata.json.tmp';
const MINIMUM_SCALE: number = 1;
const MAXIMUM_SCALE: number = 6;
const IO_CHUNK_SIZE: number = 64 * 1024;

class PlantArtworkMetadata {
  scale: number = 1;
  offsetX: number = 0;
  offsetY: number = 0;
}

class ImageDimensions {
  pixelWidth: number;
  pixelHeight: number;

  constructor(pixelWidth: number, pixelHeight: number) {
    this.pixelWidth = pixelWidth;
    this.pixelHeight = pixelHeight;
  }
}

export class PlantArtworkSnapshot {
  imageUri: string;
  scale: number;
  offsetX: number;
  offsetY: number;
  pixelWidth: number;
  pixelHeight: number;

  constructor(
    imageUri: string = '',
    scale: number = 1,
    offsetX: number = 0,
    offsetY: number = 0,
    pixelWidth: number = 0,
    pixelHeight: number = 0
  ) {
    this.imageUri = imageUri;
    this.scale = scale;
    this.offsetX = offsetX;
    this.offsetY = offsetY;
    this.pixelWidth = pixelWidth;
    this.pixelHeight = pixelHeight;
  }
}

/**
 * Persists the single image shown on the plant card. Encoded source bytes are
 * retained as-is: ImageSource validates their real format, so a picker URI does
 * not need an expensive decode/re-encode cycle merely to enter the sandbox.
 */
export class PlantArtworkStore {
  static async load(context: Context): Promise<PlantArtworkSnapshot | null> {
    try {
      const directoryPath = PlantArtworkStore.directoryPath(context);
      const imagePath = `${directoryPath}/${IMAGE_FILE_NAME}`;
      const metadataPath = `${directoryPath}/${METADATA_FILE_NAME}`;
      if (!fileIo.accessSync(imagePath) || !fileIo.accessSync(metadataPath)) {
        return null;
      }

      const imageBytes = PlantArtworkStore.readAll(imagePath);
      const dimensions = await PlantArtworkStore.validateImage(imageBytes);
      const metadataText = fileIo.readTextSync(metadataPath);
      const metadata = JSON.parse(metadataText) as PlantArtworkMetadata;

      return new PlantArtworkSnapshot(
        PlantArtworkStore.fileUri(imagePath),
        PlantArtworkStore.normalizedScale(metadata.scale),
        PlantArtworkStore.finiteOrDefault(metadata.offsetX, 0),
        PlantArtworkStore.finiteOrDefault(metadata.offsetY, 0),
        dimensions.pixelWidth,
        dimensions.pixelHeight
      );
    } catch (_error) {
      return null;
    }
  }

  static async saveFromUri(
    context: Context,
    sourceUri: string,
    scale: number = 1,
    offsetX: number = 0,
    offsetY: number = 0
  ): Promise<PlantArtworkSnapshot> {
    let sourceFile: fileIo.File | null = null;
    try {
      // Photo picker results are commonly datashare URIs. Opening the URI keeps
      // access within the permission grant instead of trying to turn it into a
      // sandbox path.
      sourceFile = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
      const bytes = PlantArtworkStore.readAllFromOpenFile(sourceFile);
      return await PlantArtworkStore.saveBytes(
        context,
        bytes,
        scale,
        offsetX,
        offsetY
      );
    } catch (_error) {
      throw new Error('读取所选植物图片失败。');
    } finally {
      PlantArtworkStore.closeQuietly(sourceFile);
    }
  }

  static async saveBytes(
    context: Context,
    encodedImage: ArrayBuffer,
    scale: number = 1,
    offsetX: number = 0,
    offsetY: number = 0
  ): Promise<PlantArtworkSnapshot> {
    const sourceCopy = PlantArtworkStore.copyBuffer(encodedImage);
    let dimensions: ImageDimensions;
    try {
      dimensions = await PlantArtworkStore.validateImage(sourceCopy);
    } catch (_error) {
      throw new Error('植物卡片图片不是可解码的图片。');
    }

    const storedScale = PlantArtworkStore.normalizedScale(scale);
    const storedOffsetX = PlantArtworkStore.finiteOrDefault(offsetX, 0);
    const storedOffsetY = PlantArtworkStore.finiteOrDefault(offsetY, 0);
    const metadata = new PlantArtworkMetadata();
    metadata.scale = storedScale;
    metadata.offsetX = storedOffsetX;
    metadata.offsetY = storedOffsetY;

    const directoryPath = PlantArtworkStore.directoryPath(context);
    const imagePath = `${directoryPath}/${IMAGE_FILE_NAME}`;
    const metadataPath = `${directoryPath}/${METADATA_FILE_NAME}`;
    const temporaryImagePath = `${directoryPath}/${IMAGE_TEMP_FILE_NAME}`;
    const temporaryMetadataPath = `${directoryPath}/${METADATA_TEMP_FILE_NAME}`;

    try {
      if (!fileIo.accessSync(directoryPath)) {
        fileIo.mkdirSync(directoryPath, true);
      }
      PlantArtworkStore.writeAll(temporaryImagePath, sourceCopy);
      const metadataBytes =
        util.TextEncoder.create().encodeInto(JSON.stringify(metadata, null, 2));
      PlantArtworkStore.writeAll(
        temporaryMetadataPath,
        PlantArtworkStore.bufferFromBytes(metadataBytes)
      );

      // Both temporary files are complete and synced before either canonical
      // file is replaced, preventing truncated picker data from becoming live.
      fileIo.moveFileSync(temporaryImagePath, imagePath, 0);
      fileIo.moveFileSync(temporaryMetadataPath, metadataPath, 0);

      return new PlantArtworkSnapshot(
        PlantArtworkStore.fileUri(imagePath),
        storedScale,
        storedOffsetX,
        storedOffsetY,
        dimensions.pixelWidth,
        dimensions.pixelHeight
      );
    } catch (_error) {
      throw new Error('保存植物卡片图片失败。');
    } finally {
      PlantArtworkStore.unlinkQuietly(temporaryImagePath);
      PlantArtworkStore.unlinkQuietly(temporaryMetadataPath);
    }
  }

  static async clear(context: Context): Promise<void> {
    const directoryPath = PlantArtworkStore.directoryPath(context);
    PlantArtworkStore.unlinkQuietly(`${directoryPath}/${IMAGE_FILE_NAME}`);
    PlantArtworkStore.unlinkQuietly(`${directoryPath}/${METADATA_FILE_NAME}`);
    PlantArtworkStore.unlinkQuietly(`${directoryPath}/${IMAGE_TEMP_FILE_NAME}`);
    PlantArtworkStore.unlinkQuietly(`${directoryPath}/${METADATA_TEMP_FILE_NAME}`);
    try {
      fileIo.rmdirSync(directoryPath);
    } catch (_error) {
      // Clearing an already absent folder is intentionally idempotent.
    }
  }

  static async readCurrentBytes(context: Context): Promise<ArrayBuffer | null> {
    try {
      return PlantArtworkStore.readAll(
        `${PlantArtworkStore.directoryPath(context)}/${IMAGE_FILE_NAME}`
      );
    } catch (_error) {
      return null;
    }
  }

  private static async validateImage(encodedImage: ArrayBuffer): Promise<ImageDimensions> {
    const source = image.createImageSource(encodedImage);
    try {
      const info = await source.getImageInfo();
      if (info.size.width <= 0 || info.size.height <= 0) {
        throw new Error('Invalid image dimensions.');
      }
      return new ImageDimensions(info.size.width, info.size.height);
    } finally {
      try {
        await source.release();
      } catch (_releaseError) {
        // Validation result remains authoritative even if native cleanup reports
        // a late release failure.
      }
    }
  }

  private static readAll(pathOrUri: string): ArrayBuffer {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(pathOrUri, fileIo.OpenMode.READ_ONLY);
      return PlantArtworkStore.readAllFromOpenFile(file);
    } catch (_error) {
      throw new Error('读取植物图片文件失败。');
    } finally {
      PlantArtworkStore.closeQuietly(file);
    }
  }

  private static readAllFromOpenFile(file: fileIo.File): ArrayBuffer {
    try {
      const fileSize = fileIo.statSync(file.fd).size;
      if (fileSize <= 0) {
        throw new Error('Image file is empty.');
      }

      const destination = new Uint8Array(fileSize);
      let totalRead = 0;
      while (totalRead < fileSize) {
        const remaining = fileSize - totalRead;
        const chunk = new ArrayBuffer(Math.min(IO_CHUNK_SIZE, remaining));
        const readCount = fileIo.readSync(file.fd, chunk);
        if (readCount <= 0) {
          break;
        }
        destination.set(new Uint8Array(chunk, 0, readCount), totalRead);
        totalRead += readCount;
      }
      if (totalRead !== fileSize) {
        throw new Error('Image file was not read completely.');
      }
      return PlantArtworkStore.bufferFromBytes(destination);
    } catch (_error) {
      throw new Error('植物图片文件读取不完整。');
    }
  }

  private static writeAll(path: string, data: ArrayBuffer): void {
    const source = new Uint8Array(data);
    if (source.length === 0) {
      throw new Error('Refusing to write an empty file.');
    }

    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(
        path,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
      let totalWritten = 0;
      while (totalWritten < source.length) {
        const chunkLength = Math.min(IO_CHUNK_SIZE, source.length - totalWritten);
        const chunk = new Uint8Array(chunkLength);
        chunk.set(source.subarray(totalWritten, totalWritten + chunkLength));
        const writeCount = fileIo.writeSync(file.fd, chunk.buffer);
        if (writeCount <= 0) {
          break;
        }
        totalWritten += writeCount;
      }
      if (totalWritten !== source.length) {
        throw new Error('File was not written completely.');
      }
      fileIo.fsyncSync(file.fd);
    } catch (_error) {
      throw new Error('植物图片文件写入不完整。');
    } finally {
      PlantArtworkStore.closeQuietly(file);
    }
  }

  private static normalizedScale(value: number): number {
    const finiteValue = PlantArtworkStore.finiteOrDefault(value, 1);
    return Math.min(MAXIMUM_SCALE, Math.max(MINIMUM_SCALE, finiteValue));
  }

  private static finiteOrDefault(value: number, fallback: number): number {
    return Number.isFinite(value) ? value : fallback;
  }

  private static directoryPath(context: Context): string {
    return `${context.filesDir}/${DIRECTORY_NAME}`;
  }

  private static fileUri(path: string): string {
    return `file://${path}`;
  }

  private static copyBuffer(source: ArrayBuffer): ArrayBuffer {
    const sourceBytes = new Uint8Array(source);
    const copy = new Uint8Array(sourceBytes.length);
    copy.set(sourceBytes);
    return PlantArtworkStore.bufferFromBytes(copy);
  }

  private static bufferFromBytes(source: Uint8Array): ArrayBuffer {
    const buffer = new ArrayBuffer(source.byteLength);
    new Uint8Array(buffer).set(source);
    return buffer;
  }

  private static closeQuietly(file: fileIo.File | null): void {
    if (file === null) {
      return;
    }
    try {
      fileIo.closeSync(file);
    } catch (_error) {
      // The caller should observe the primary read/write error, not cleanup.
    }
  }

  private static unlinkQuietly(path: string): void {
    try {
      fileIo.unlinkSync(path);
    } catch (_error) {
      // Missing files are already in the requested cleared/cleaned-up state.
    }
  }
}
