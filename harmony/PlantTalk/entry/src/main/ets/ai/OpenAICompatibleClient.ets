import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { ChatMessage, ChatRole } from '../model/PlantModels';

export interface ChatCompletionOptions {
  baseURL: string;
  apiKey: string;
  model: string;
  systemPrompt?: string;
  messages: ChatMessage[];
  onDelta?: (chunk: string, fullText: string) => void;
}

export interface OpenAIMessage {
  role: string;
  content: string;
}

export interface OpenAIRequestPayload {
  model: string;
  messages: OpenAIMessage[];
  stream: boolean;
}

export class OpenAICompatibleClient {
  /**
   * Stream chat completions from OpenAI-compatible API using @ohos.net.http requestInStream.
   */
  static async streamChatCompletions(options: ChatCompletionOptions): Promise<string> {
    const baseURL = options.baseURL.replace(/\/+$/, '');
    const url = `${baseURL}/chat/completions`;

    const requestMessages: OpenAIMessage[] = [];
    if (options.systemPrompt && options.systemPrompt.trim().length > 0) {
      requestMessages.push({
        role: 'system',
        content: options.systemPrompt
      });
    }

    for (const msg of options.messages) {
      requestMessages.push({
        role: msg.role === ChatRole.ASSISTANT ? 'assistant' : 'user',
        content: msg.content
      });
    }

    const payload: OpenAIRequestPayload = {
      model: options.model,
      messages: requestMessages,
      stream: true
    };

    const httpRequest = http.createHttp();
    let accumulatedText = '';
    let bufferStr = '';
    const decoder = util.TextDecoder.create('utf-8');

    // 80ms throttle state
    let pendingDelta = '';
    let lastFlushTime = 0;
    let flushTimer: number | null = null;

    const flushPending = () => {
      if (pendingDelta.length > 0) {
        accumulatedText += pendingDelta;
        if (options.onDelta) {
          options.onDelta(pendingDelta, accumulatedText);
        }
        pendingDelta = '';
        lastFlushTime = Date.now();
      }
      if (flushTimer !== null) {
        clearTimeout(flushTimer);
        flushTimer = null;
      }
    };

    const handleDelta = (delta: string) => {
      if (accumulatedText.length === 0 && pendingDelta.length === 0) {
        // First token is rendered immediately
        pendingDelta = delta;
        flushPending();
        return;
      }

      pendingDelta += delta;
      const now = Date.now();
      if (now - lastFlushTime >= 80) {
        flushPending();
      } else if (flushTimer === null) {
        flushTimer = setTimeout(() => {
          flushPending();
        }, 80 - (now - lastFlushTime));
      }
    };

    return new Promise<string>((resolve, reject) => {
      let isCompleted = false;

      httpRequest.on('dataReceive', (data: ArrayBuffer) => {
        try {
          const chunkStr = decoder.decodeToString(new Uint8Array(data));
          bufferStr += chunkStr;

          const lines = bufferStr.split('\n');
          bufferStr = lines.pop() || ''; // Keep incomplete line in buffer

          for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed || trimmed.startsWith(':')) {
              continue;
            }
            if (trimmed === 'data: [DONE]') {
              isCompleted = true;
              continue;
            }
            if (trimmed.startsWith('data: ')) {
              const jsonStr = trimmed.substring(6).trim();
              try {
                const parsed = JSON.parse(jsonStr) as Record<string, Object>;
                const choices = parsed['choices'] as Array<Record<string, Object>>;
                if (choices && choices.length > 0) {
                  const deltaObj = choices[0]['delta'] as Record<string, string>;
                  if (deltaObj && deltaObj['content']) {
                    handleDelta(deltaObj['content']);
                  }
                }
              } catch (_e) {
                // Ignore parse errors on partial JSON lines
              }
            }
          }
        } catch (err) {
          console.error('[OpenAIClient] dataReceive parse error:', JSON.stringify(err));
        }
      });

      httpRequest.on('dataEnd', () => {
        flushPending();
        httpRequest.destroy();
        resolve(accumulatedText);
      });

      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream'
      };
      if (options.apiKey && options.apiKey.trim().length > 0) {
        headers['Authorization'] = `Bearer ${options.apiKey.trim()}`;
      }

      httpRequest.requestInStream(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(payload),
        connectTimeout: 15000,
        readTimeout: 60000
      }).then((code: number) => {
        if (code >= 400) {
          httpRequest.destroy();
          reject(new Error(`AI 响应状态错误 (${code})`));
        }
      }).catch((err: Object) => {
        httpRequest.destroy();
        reject(new Error(`AI 网络请求失败: ${err instanceof Error ? err.message : JSON.stringify(err)}`));
      });
    });
  }
}
