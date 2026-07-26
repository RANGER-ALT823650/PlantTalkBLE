import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { ImageGenerationConfiguration } from './AIConfigurationStore';

const MAXIMUM_INPUT_PIXEL_DIMENSION: number = 2048;
const INPUT_JPEG_QUALITY: number = 85;
const REQUEST_TIMEOUT_MS: number = 120000;
const MAXIMUM_SERVER_MESSAGE_LENGTH: number = 500;

interface ImageGenerationRequestHeaders {
  'Content-Type': string;
  Authorization: string;
}

class ImageGenerationContentPart {
  image?: string;
  text?: string;

  constructor(imageValue: string = '', textValue: string = '') {
    if (imageValue.length > 0) {
      this.image = imageValue;
    }
    if (textValue.length > 0) {
      this.text = textValue;
    }
  }
}

class ImageGenerationMessage {
  role: string;
  content: ImageGenerationContentPart[];

  constructor(content: ImageGenerationContentPart[]) {
    this.role = 'user';
    this.content = content;
  }
}

class ImageGenerationInput {
  messages: ImageGenerationMessage[];

  constructor(messages: ImageGenerationMessage[]) {
    this.messages = messages;
  }
}

class ImageGenerationParameters {
  negative_prompt: string = '';
  prompt_extend: boolean = true;
  watermark: boolean = false;
}

class ImageGenerationRequestBody {
  model: string;
  input: ImageGenerationInput;
  parameters: ImageGenerationParameters;

  constructor(model: string, prompt: string, imageDataURL: string) {
    this.model = model;
    this.input = new ImageGenerationInput([
      new ImageGenerationMessage([
        new ImageGenerationContentPart(imageDataURL, ''),
        new ImageGenerationContentPart('', prompt)
      ])
    ]);
    this.parameters = new ImageGenerationParameters();
  }
}

interface ImageGenerationResponseContentPart {
  image?: string;
}

interface ImageGenerationResponseMessage {
  content?: ImageGenerationResponseContentPart[];
}

interface ImageGenerationResponseChoice {
  message?: ImageGenerationResponseMessage;
}

interface ImageGenerationResponseResult {
  url?: string;
}

interface ImageGenerationResponseOutput {
  choices?: ImageGenerationResponseChoice[];
  results?: ImageGenerationResponseResult[];
  task_status?: string;
}

interface ImageGenerationResponseEnvelope {
  output?: ImageGenerationResponseOutput;
  code?: string;
  message?: string;
}

/**
 * Validated bytes returned by the generation service. Keeping the original
 * encoded payload lets the gallery persist a PNG/JPEG without an unnecessary
 * second download.
 */
export class PlantImageGenerationResult {
  data: Uint8Array;
  pixelWidth: number;
  pixelHeight: number;
  mimeType: string;
  sourceURL: string;

  constructor(
    data: Uint8Array,
    pixelWidth: number,
    pixelHeight: number,
    mimeType: string,
    sourceURL: string
  ) {
    this.data = data;
    this.pixelWidth = pixelWidth;
    this.pixelHeight = pixelHeight;
    this.mimeType = mimeType;
    this.sourceURL = sourceURL;
  }
}

/**
 * Synchronous DashScope multimodal image-edit client.
 *
 * `inputImageData` is an encoded JPEG/PNG selected by the user. Before upload,
 * it is decoded, constrained to a 2048 px longest edge, and encoded as JPEG 85.
 */
export class PlantImageGenerationClient {
  async generate(
    configuration: ImageGenerationConfiguration,
    inputImageData: Uint8Array,
    prompt: string
  ): Promise<PlantImageGenerationResult> {
    const dataURL = await PlantImageGenerationClient.encodeInputImageDataURL(inputImageData);
    const body = new ImageGenerationRequestBody(
      configuration.model,
      prompt,
      dataURL
    );
    const headers: ImageGenerationRequestHeaders = {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${configuration.apiKey}`
    };
    const request = http.createHttp();

    try {
      let response: http.HttpResponse;
      try {
        response = await request.request(configuration.baseURL, {
          method: http.RequestMethod.POST,
          header: headers,
          extraData: JSON.stringify(body),
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: REQUEST_TIMEOUT_MS,
          readTimeout: REQUEST_TIMEOUT_MS,
          usingCache: false
        });
      } catch (_error) {
        throw new Error('生图服务请求失败，请检查网络后重试。');
      }
      const responseText = response.result.toString();
      if (response.responseCode < 200 || response.responseCode >= 300) {
        const message = PlantImageGenerationClient.serverErrorMessage(responseText);
        if (message.length > 0) {
          throw new Error(`生图服务错误（HTTP ${response.responseCode}）：${message}`);
        }
        throw new Error(`生图服务请求失败（HTTP ${response.responseCode}）。`);
      }

      const imageURL = PlantImageGenerationClient.parseImageURL(responseText);
      return await PlantImageGenerationClient.downloadImage(imageURL);
    } finally {
      request.destroy();
    }
  }

  /**
   * Kept public and deterministic so protocol fixtures can cover both response
   * shapes without sending a network request.
   */
  static parseImageURL(responseText: string): string {
    let envelope: ImageGenerationResponseEnvelope;
    try {
      envelope = JSON.parse(responseText) as ImageGenerationResponseEnvelope;
    } catch (_error) {
      throw new Error('生图服务返回了无法识别的响应。');
    }

    const output = envelope.output;
    if (output !== undefined) {
      const choices = output.choices;
      if (choices !== undefined) {
        for (let choiceIndex = 0; choiceIndex < choices.length; choiceIndex += 1) {
          const message = choices[choiceIndex].message;
          if (message === undefined || message.content === undefined) {
            continue;
          }
          const content = message.content;
          for (let partIndex = 0; partIndex < content.length; partIndex += 1) {
            const candidate = content[partIndex].image;
            if (candidate !== undefined &&
              PlantImageGenerationClient.isHTTPURL(candidate)) {
              return candidate;
            }
          }
        }
      }

      const results = output.results;
      if (results !== undefined) {
        for (let resultIndex = 0; resultIndex < results.length; resultIndex += 1) {
          const candidate = results[resultIndex].url;
          if (candidate !== undefined &&
            PlantImageGenerationClient.isHTTPURL(candidate)) {
            return candidate;
          }
        }
      }

      if (output.task_status !== undefined &&
        output.task_status.toUpperCase() === 'FAILED') {
        throw new Error(`生图任务失败（${output.task_status}）。`);
      }
    }

    if (envelope.message !== undefined && envelope.message.trim().length > 0) {
      throw new Error(`生图服务错误：${envelope.message.trim()}`);
    }
    throw new Error('生图服务没有返回图片，请调整提示词后重试。');
  }

  private static async encodeInputImageDataURL(inputImageData: Uint8Array): Promise<string> {
    if (inputImageData.length === 0) {
      throw new Error('无法处理输入图片，请重新拍摄或选择。');
    }

    const encodedCopy = PlantImageGenerationClient.copyBytes(inputImageData);
    const source = image.createImageSource(encodedCopy.buffer);
    let pixelMap: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      const sourceInfo = await source.getImageInfo();
      const sourceWidth = sourceInfo.size.width;
      const sourceHeight = sourceInfo.size.height;
      if (sourceWidth <= 0 || sourceHeight <= 0) {
        throw new Error('无法处理输入图片，请重新拍摄或选择。');
      }

      const longestEdge = Math.max(sourceWidth, sourceHeight);
      const scale = Math.min(1, MAXIMUM_INPUT_PIXEL_DIMENSION / longestEdge);
      const outputWidth = Math.max(1, Math.round(sourceWidth * scale));
      const outputHeight = Math.max(1, Math.round(sourceHeight * scale));
      pixelMap = await source.createPixelMap({
        desiredSize: {
          width: outputWidth,
          height: outputHeight
        }
      });

      packer = image.createImagePacker();
      const jpegBuffer = await packer.packing(pixelMap, {
        format: 'image/jpeg',
        quality: INPUT_JPEG_QUALITY
      });
      const jpegData = new Uint8Array(jpegBuffer);
      if (jpegData.length === 0) {
        throw new Error('无法处理输入图片，请重新拍摄或选择。');
      }
      const base64 = new util.Base64Helper().encodeToStringSync(jpegData);
      return `data:image/jpeg;base64,${base64}`;
    } catch (_error) {
      throw new Error('无法处理输入图片，请重新拍摄或选择。');
    } finally {
      if (pixelMap !== null) {
        try {
          await pixelMap.release();
        } catch (_releaseError) {
          // The request has already finished using this temporary PixelMap.
        }
      }
      if (packer !== null) {
        try {
          await packer.release();
        } catch (_releaseError) {
          // Resource cleanup must not replace the user-facing generation error.
        }
      }
      try {
        await source.release();
      } catch (_releaseError) {
        // Resource cleanup must not replace the user-facing generation error.
      }
    }
  }

  private static async downloadImage(url: string): Promise<PlantImageGenerationResult> {
    const request = http.createHttp();
    try {
      let response: http.HttpResponse;
      try {
        response = await request.request(url, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: REQUEST_TIMEOUT_MS,
          readTimeout: REQUEST_TIMEOUT_MS,
          usingCache: false
        });
      } catch (_error) {
        throw new Error('生成的图片下载失败，请重试。');
      }
      if (response.responseCode < 200 || response.responseCode >= 300 ||
        response.resultType !== http.HttpDataType.ARRAY_BUFFER) {
        throw new Error('生成的图片下载失败，请重试。');
      }

      const downloaded = new Uint8Array(response.result as ArrayBuffer);
      if (downloaded.length === 0) {
        throw new Error('生成的图片下载失败，请重试。');
      }
      const validatedCopy = PlantImageGenerationClient.copyBytes(downloaded);
      const source = image.createImageSource(validatedCopy.buffer);
      try {
        const info = await source.getImageInfo();
        if (info.size.width <= 0 || info.size.height <= 0) {
          throw new Error('生成的图片下载失败，请重试。');
        }
        return new PlantImageGenerationResult(
          validatedCopy,
          info.size.width,
          info.size.height,
          info.mimeType,
          url
        );
      } catch (_error) {
        throw new Error('生成的图片下载失败，请重试。');
      } finally {
        try {
          await source.release();
        } catch (_releaseError) {
          // Validation is complete; a release failure must not invalidate bytes.
        }
      }
    } finally {
      request.destroy();
    }
  }

  private static serverErrorMessage(responseText: string): string {
    try {
      const envelope =
        JSON.parse(responseText) as ImageGenerationResponseEnvelope;
      if (envelope.output !== undefined &&
        envelope.output.task_status !== undefined &&
        envelope.output.task_status.toUpperCase() === 'FAILED') {
        return `生图任务失败（${envelope.output.task_status}）。`;
      }
      if (envelope.message !== undefined) {
        return envelope.message.trim().slice(0, MAXIMUM_SERVER_MESSAGE_LENGTH);
      }
    } catch (_error) {
      // Fall through to the bounded plain-text server body.
    }
    return responseText.trim().slice(0, MAXIMUM_SERVER_MESSAGE_LENGTH);
  }

  private static isHTTPURL(value: string): boolean {
    return value.startsWith('https://') || value.startsWith('http://');
  }

  private static copyBytes(source: Uint8Array): Uint8Array {
    const copy = new Uint8Array(source.length);
    copy.set(source);
    return copy;
  }
}
