import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { GeneratedPlantImage } from '../model/GeneratedImageModels';

const DIRECTORY_NAME: string = 'GeneratedPlantImages';
const INDEX_FILE_NAME: string = 'index.json';
const INDEX_TEMP_FILE_NAME: string = 'index.json.tmp';
const GALLERY_JPEG_QUALITY: number = 92;

class GeneratedImageIndexEntry {
  id: string = '';
  createdAtMs: number = 0;
  fileName: string = '';
  pixelWidth: number = 0;
  pixelHeight: number = 0;
  prompt: string = '';
}

class StoredImagePayload {
  data: Uint8Array;
  extension: string;
  pixelWidth: number;
  pixelHeight: number;

  constructor(
    data: Uint8Array,
    extension: string,
    pixelWidth: number,
    pixelHeight: number
  ) {
    this.data = data;
    this.extension = extension;
    this.pixelWidth = pixelWidth;
    this.pixelHeight = pixelHeight;
  }
}

/**
 * Sandbox-backed AI gallery. Images live under
 * `<filesDir>/GeneratedPlantImages`; `index.json` remains the only ordering and
 * metadata source, matching the iOS append-at-front behavior.
 */
export class GeneratedImageStore {
  static loadAll(context: Context): GeneratedPlantImage[] {
    try {
      const directoryPath = GeneratedImageStore.directoryPath(context);
      const entries = GeneratedImageStore.loadIndex(directoryPath);
      const items: GeneratedPlantImage[] = [];
      for (let index = 0; index < entries.length; index += 1) {
        const entry = entries[index];
        if (!GeneratedImageStore.isSafeEntry(entry)) {
          continue;
        }
        const imagePath = `${directoryPath}/${entry.fileName}`;
        if (!fileIo.accessSync(imagePath)) {
          continue;
        }
        items.push(new GeneratedPlantImage(
          entry.id,
          GeneratedImageStore.fileURI(imagePath),
          entry.pixelWidth,
          entry.pixelHeight,
          entry.createdAtMs,
          entry.prompt
        ));
      }
      items.sort((left: GeneratedPlantImage, right: GeneratedPlantImage) =>
        right.createdAtMs - left.createdAtMs);
      return items;
    } catch (_error) {
      return [];
    }
  }

  /**
   * Persists validated encoded image data. JPEG 92 is preferred for parity with
   * iOS; if the platform cannot re-encode an otherwise valid download, the
   * original bytes are retained with an appropriate extension.
   */
  static async save(
    context: Context,
    encodedImage: Uint8Array,
    prompt: string = ''
  ): Promise<GeneratedPlantImage | null> {
    if (encodedImage.length === 0) {
      return null;
    }

    let imagePath = '';
    try {
      const payload = await GeneratedImageStore.prepareStoredImage(encodedImage);
      const directoryPath = GeneratedImageStore.directoryPath(context);
      if (!fileIo.accessSync(directoryPath)) {
        fileIo.mkdirSync(directoryPath, true);
      }

      const id = util.generateRandomUUID();
      const fileName = `${id}.${payload.extension}`;
      imagePath = `${directoryPath}/${fileName}`;
      GeneratedImageStore.writeBytes(imagePath, payload.data);

      const entry = new GeneratedImageIndexEntry();
      entry.id = id;
      entry.createdAtMs = Date.now();
      entry.fileName = fileName;
      entry.pixelWidth = payload.pixelWidth;
      entry.pixelHeight = payload.pixelHeight;
      entry.prompt = prompt;

      const entries = GeneratedImageStore.loadIndex(directoryPath);
      entries.unshift(entry);
      GeneratedImageStore.writeIndex(entries, directoryPath);

      return new GeneratedPlantImage(
        entry.id,
        GeneratedImageStore.fileURI(imagePath),
        entry.pixelWidth,
        entry.pixelHeight,
        entry.createdAtMs,
        entry.prompt
      );
    } catch (_error) {
      if (imagePath.length > 0) {
        try {
          fileIo.unlinkSync(imagePath);
        } catch (_cleanupError) {
          // A failed save must not surface a second cleanup error.
        }
      }
      return null;
    }
  }

  static delete(context: Context, id: string): void {
    try {
      const directoryPath = GeneratedImageStore.directoryPath(context);
      const entries = GeneratedImageStore.loadIndex(directoryPath);
      let removedEntry: GeneratedImageIndexEntry | null = null;
      const remaining: GeneratedImageIndexEntry[] = [];
      for (let index = 0; index < entries.length; index += 1) {
        const entry = entries[index];
        if (removedEntry === null && entry.id === id) {
          removedEntry = entry;
        } else {
          remaining.push(entry);
        }
      }
      if (removedEntry === null) {
        return;
      }

      GeneratedImageStore.writeIndex(remaining, directoryPath);
      try {
        fileIo.unlinkSync(`${directoryPath}/${removedEntry.fileName}`);
      } catch (_fileError) {
        // Removing the index entry is authoritative; an orphan can be pruned.
      }

      if (remaining.length === 0) {
        try {
          fileIo.unlinkSync(`${directoryPath}/${INDEX_FILE_NAME}`);
        } catch (_indexError) {
          // An already absent empty index needs no further handling.
        }
        try {
          fileIo.rmdirSync(directoryPath);
        } catch (_directoryError) {
          // Keep the sandbox folder when an orphaned file still exists.
        }
      }
    } catch (_error) {
      // Deletion is intentionally idempotent, matching the iOS storage API.
    }
  }

  private static async prepareStoredImage(encodedImage: Uint8Array): Promise<StoredImagePayload> {
    const sourceBytes = GeneratedImageStore.copyBytes(encodedImage);
    const source = image.createImageSource(sourceBytes.buffer);
    let pixelMap: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    let pixelWidth = 0;
    let pixelHeight = 0;
    let mimeType = '';

    try {
      const info = await source.getImageInfo();
      pixelWidth = info.size.width;
      pixelHeight = info.size.height;
      mimeType = info.mimeType;
      if (pixelWidth <= 0 || pixelHeight <= 0) {
        throw new Error('Invalid image dimensions.');
      }

      try {
        pixelMap = await source.createPixelMap();
        packer = image.createImagePacker();
        const jpegBuffer = await packer.packing(pixelMap, {
          format: 'image/jpeg',
          quality: GALLERY_JPEG_QUALITY
        });
        const jpegData = new Uint8Array(jpegBuffer);
        if (jpegData.length > 0) {
          return new StoredImagePayload(
            GeneratedImageStore.copyBytes(jpegData),
            'jpg',
            pixelWidth,
            pixelHeight
          );
        }
      } catch (_encodingError) {
        // Preserve the already decoded and validated service response below.
      }

      return new StoredImagePayload(
        sourceBytes,
        GeneratedImageStore.extensionFor(mimeType, sourceBytes),
        pixelWidth,
        pixelHeight
      );
    } finally {
      if (pixelMap !== null) {
        try {
          await pixelMap.release();
        } catch (_releaseError) {
          // Encoding has completed and the PixelMap is no longer referenced.
        }
      }
      if (packer !== null) {
        try {
          await packer.release();
        } catch (_releaseError) {
          // Cleanup must not discard a successfully encoded gallery image.
        }
      }
      try {
        await source.release();
      } catch (_releaseError) {
        // Cleanup must not discard a validated original service response.
      }
    }
  }

  private static loadIndex(directoryPath: string): GeneratedImageIndexEntry[] {
    const indexPath = `${directoryPath}/${INDEX_FILE_NAME}`;
    try {
      if (!fileIo.accessSync(indexPath)) {
        return [];
      }
      const text = fileIo.readTextSync(indexPath);
      const entries = JSON.parse(text) as GeneratedImageIndexEntry[];
      if (!Array.isArray(entries)) {
        return [];
      }
      return entries;
    } catch (_error) {
      return [];
    }
  }

  private static writeIndex(
    entries: GeneratedImageIndexEntry[],
    directoryPath: string
  ): void {
    const indexPath = `${directoryPath}/${INDEX_FILE_NAME}`;
    const temporaryPath = `${directoryPath}/${INDEX_TEMP_FILE_NAME}`;
    const json = JSON.stringify(entries, null, 2);
    let temporaryWritten = false;
    try {
      GeneratedImageStore.writeText(temporaryPath, json);
      temporaryWritten = true;
      fileIo.moveFileSync(temporaryPath, indexPath, 0);
      temporaryWritten = false;
    } catch (_error) {
      throw new Error('写入 AI 图片索引失败。');
    } finally {
      if (temporaryWritten) {
        try {
          fileIo.unlinkSync(temporaryPath);
        } catch (_cleanupError) {
          // The next atomic write truncates the same temporary file.
        }
      }
    }
  }

  private static writeBytes(path: string, data: Uint8Array): void {
    const copy = GeneratedImageStore.copyBytes(data);
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(
        path,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
      const written = fileIo.writeSync(file.fd, copy.buffer);
      if (written !== copy.byteLength) {
        throw new Error(`图片文件未完整写入：${written}/${copy.byteLength}`);
      }
      fileIo.fsyncSync(file.fd);
    } catch (_error) {
      throw new Error('写入 AI 图片文件失败。');
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (_closeError) {
          // The caller still receives the primary write error, if there was one.
        }
      }
    }
  }

  private static writeText(path: string, value: string): void {
    const bytes = util.TextEncoder.create().encodeInto(value);
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(
        path,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
      const written = fileIo.writeSync(file.fd, bytes.buffer);
      if (written !== bytes.byteLength) {
        throw new Error(`索引文件未完整写入：${written}/${bytes.byteLength}`);
      }
      fileIo.fsyncSync(file.fd);
    } catch (_error) {
      throw new Error('写入 AI 图片索引失败。');
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (_closeError) {
          // The caller still receives the primary write error, if there was one.
        }
      }
    }
  }

  private static isSafeEntry(entry: GeneratedImageIndexEntry): boolean {
    return entry.id.length > 0 &&
      entry.fileName.length > 0 &&
      !entry.fileName.includes('/') &&
      !entry.fileName.includes('\\') &&
      entry.createdAtMs > 0 &&
      entry.pixelWidth > 0 &&
      entry.pixelHeight > 0;
  }

  private static extensionFor(mimeType: string, data: Uint8Array): string {
    const normalizedMime = mimeType.toLowerCase();
    if (normalizedMime.includes('jpeg') || GeneratedImageStore.isJPEG(data)) {
      return 'jpg';
    }
    if (normalizedMime.includes('png') || GeneratedImageStore.isPNG(data)) {
      return 'png';
    }
    if (normalizedMime.includes('webp') || GeneratedImageStore.isWebP(data)) {
      return 'webp';
    }
    if (normalizedMime.includes('gif') || GeneratedImageStore.isGIF(data)) {
      return 'gif';
    }
    return 'img';
  }

  private static isJPEG(data: Uint8Array): boolean {
    return data.length >= 3 &&
      data[0] === 0xFF && data[1] === 0xD8 && data[2] === 0xFF;
  }

  private static isPNG(data: Uint8Array): boolean {
    return data.length >= 8 &&
      data[0] === 0x89 && data[1] === 0x50 &&
      data[2] === 0x4E && data[3] === 0x47;
  }

  private static isWebP(data: Uint8Array): boolean {
    return data.length >= 12 &&
      data[0] === 0x52 && data[1] === 0x49 &&
      data[2] === 0x46 && data[3] === 0x46 &&
      data[8] === 0x57 && data[9] === 0x45 &&
      data[10] === 0x42 && data[11] === 0x50;
  }

  private static isGIF(data: Uint8Array): boolean {
    return data.length >= 6 &&
      data[0] === 0x47 && data[1] === 0x49 &&
      data[2] === 0x46 && data[3] === 0x38;
  }

  private static fileURI(path: string): string {
    return `file://${path}`;
  }

  private static directoryPath(context: Context): string {
    return `${context.filesDir}/${DIRECTORY_NAME}`;
  }

  private static copyBytes(source: Uint8Array): Uint8Array {
    const copy = new Uint8Array(source.length);
    copy.set(source);
    return copy;
  }
}
