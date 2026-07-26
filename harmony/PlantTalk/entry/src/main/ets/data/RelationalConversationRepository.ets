import { relationalStore } from '@kit.ArkData';
import { ConversationRepository } from './ConversationRepository';
import {
  AIConversation,
  AIConversationKind,
  ChatMessage,
  ChatRole,
  ChatImageAttachment,
  ToolInvocation
} from '../model/PlantModels';

export class RelationalConversationRepository implements ConversationRepository {
  private readonly store: relationalStore.RdbStore;

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  async createConversation(title?: string, kind: AIConversationKind = AIConversationKind.TEXT): Promise<AIConversation> {
    const id = RelationalConversationRepository.generateId();
    const now = Date.now();
    const convTitle = title || (kind === AIConversationKind.REALTIME ? '实时语音对话' : '植物日常对话');

    const bucket: relationalStore.ValuesBucket = {
      'id': id,
      'title': convTitle,
      'kind': kind,
      'created_at': now,
      'updated_at': now
    };

    await this.store.insert('ai_conversations', bucket);
    return new AIConversation(id, convTitle, kind, now, now);
  }

  async getConversation(id: string): Promise<AIConversation | null> {
    const resultSet = await this.store.querySql(
      `SELECT id, title, kind, created_at, updated_at
       FROM ai_conversations
       WHERE id = ?`,
      [id]
    );
    try {
      if (!resultSet.goToFirstRow()) {
        return null;
      }
      return RelationalConversationRepository.rowToConversation(resultSet);
    } finally {
      resultSet.close();
    }
  }

  async allConversations(kind?: AIConversationKind): Promise<AIConversation[]> {
    let sql = `SELECT id, title, kind, created_at, updated_at FROM ai_conversations`;
    const args: string[] = [];
    if (kind) {
      sql += ` WHERE kind = ?`;
      args.push(kind);
    }
    sql += ` ORDER BY updated_at DESC`;

    const resultSet = await this.store.querySql(sql, args);
    const conversations: AIConversation[] = [];
    try {
      while (resultSet.goToNextRow()) {
        conversations.push(RelationalConversationRepository.rowToConversation(resultSet));
      }
      return conversations;
    } finally {
      resultSet.close();
    }
  }

  async getOrCreateDefaultConversation(kind: AIConversationKind = AIConversationKind.TEXT): Promise<AIConversation> {
    const all = await this.allConversations(kind);
    if (all.length > 0) {
      return all[0];
    }
    return await this.createConversation(undefined, kind);
  }

  async chatMessages(conversationId: string): Promise<ChatMessage[]> {
    const resultSet = await this.store.querySql(
      `SELECT id, conversation_id, role, content, created_at
       FROM ai_messages
       WHERE conversation_id = ?
       ORDER BY created_at ASC`,
      [conversationId]
    );

    const messages: ChatMessage[] = [];
    try {
      while (resultSet.goToNextRow()) {
        const idIdx = resultSet.getColumnIndex('id');
        const convIdx = resultSet.getColumnIndex('conversation_id');
        const roleIdx = resultSet.getColumnIndex('role');
        const contentIdx = resultSet.getColumnIndex('content');
        const timeIdx = resultSet.getColumnIndex('created_at');

        const id = idIdx >= 0 ? resultSet.getString(idIdx) : '';
        const convId = convIdx >= 0 ? resultSet.getString(convIdx) : conversationId;
        const roleStr = roleIdx >= 0 ? resultSet.getString(roleIdx) : 'user';
        const content = contentIdx >= 0 ? resultSet.getString(contentIdx) : '';
        const createdAtMs = timeIdx >= 0 ? resultSet.getLong(timeIdx) : Date.now();

        const role = roleStr === 'assistant' ? ChatRole.ASSISTANT :
                     roleStr === 'system' ? ChatRole.SYSTEM : ChatRole.USER;

        const msg = new ChatMessage(id, convId, role, content, createdAtMs);
        messages.push(msg);
      }
    } finally {
      resultSet.close();
    }

    for (const msg of messages) {
      msg.imageAttachments = await this.loadImagesForMessage(msg.id);
      msg.toolInvocations = await this.loadToolInvocationsForMessage(msg.id);
    }

    return messages;
  }

  async saveChatMessage(message: ChatMessage): Promise<void> {
    this.store.beginTransaction();
    try {
      const msgBucket: relationalStore.ValuesBucket = {
        'id': message.id,
        'conversation_id': message.conversationID,
        'role': message.role,
        'content': message.content,
        'created_at': message.createdAtMs
      };

      await this.store.insert(
        'ai_messages',
        msgBucket,
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE
      );

      // Save image attachments
      if (message.imageAttachments && message.imageAttachments.length > 0) {
        for (let i = 0; i < message.imageAttachments.length; i++) {
          const img = message.imageAttachments[i];
          const imgBucket: relationalStore.ValuesBucket = {
            'id': img.id,
            'message_id': message.id,
            'position': i,
            'mime_type': img.mimeType,
            'data': img.data
          };
          await this.store.insert(
            'ai_message_images',
            imgBucket,
            relationalStore.ConflictResolution.ON_CONFLICT_REPLACE
          );
        }
      }

      // Save tool invocations
      if (message.toolInvocations && message.toolInvocations.length > 0) {
        for (let i = 0; i < message.toolInvocations.length; i++) {
          const tool = message.toolInvocations[i];
          const toolBucket: relationalStore.ValuesBucket = {
            'id': tool.id,
            'message_id': message.id,
            'position': i,
            'provider_call_id': tool.providerCallID || '',
            'tool_name': tool.toolName,
            'summary': tool.summary,
            'arguments_json': tool.argumentsJSON,
            'result_json': tool.resultJSON,
            'executed_at': tool.executedAtMs
          };
          await this.store.insert(
            'ai_message_tool_invocations',
            toolBucket,
            relationalStore.ConflictResolution.ON_CONFLICT_REPLACE
          );
        }
      }

      // Update conversation timestamp
      await this.store.executeSql(
        `UPDATE ai_conversations SET updated_at = ? WHERE id = ?`,
        [Date.now(), message.conversationID]
      );

      this.store.commit();
    } catch (error) {
      this.store.rollBack();
      console.error(`[ConversationRepository] saveChatMessage failed:`, JSON.stringify(error));
      throw new Error(`保存消息失败: ${error instanceof Error ? error.message : JSON.stringify(error)}`);
    }
  }

  async deleteChatTurn(messageId: string): Promise<void> {
    this.store.beginTransaction();
    try {
      await this.store.executeSql(`DELETE FROM ai_message_images WHERE message_id = ?`, [messageId]);
      await this.store.executeSql(`DELETE FROM ai_message_tool_invocations WHERE message_id = ?`, [messageId]);
      await this.store.executeSql(`DELETE FROM ai_memory_message_sequences WHERE message_id = ?`, [messageId]);
      await this.store.executeSql(`DELETE FROM ai_messages WHERE id = ?`, [messageId]);
      this.store.commit();
    } catch (error) {
      this.store.rollBack();
      console.error(`[ConversationRepository] deleteChatTurn failed:`, JSON.stringify(error));
      throw new Error(`删除消息失败: ${error instanceof Error ? error.message : JSON.stringify(error)}`);
    }
  }

  async deleteConversation(conversationId: string): Promise<void> {
    this.store.beginTransaction();
    try {
      const resultSet = await this.store.querySql(
        `SELECT id FROM ai_messages WHERE conversation_id = ?`,
        [conversationId]
      );
      const msgIds: string[] = [];
      try {
        while (resultSet.goToNextRow()) {
          const colIdx = resultSet.getColumnIndex('id');
          if (colIdx >= 0) {
            msgIds.push(resultSet.getString(colIdx));
          }
        }
      } finally {
        resultSet.close();
      }

      for (const msgId of msgIds) {
        await this.store.executeSql(`DELETE FROM ai_message_images WHERE message_id = ?`, [msgId]);
        await this.store.executeSql(`DELETE FROM ai_message_tool_invocations WHERE message_id = ?`, [msgId]);
        await this.store.executeSql(`DELETE FROM ai_memory_message_sequences WHERE message_id = ?`, [msgId]);
      }

      await this.store.executeSql(`DELETE FROM ai_messages WHERE conversation_id = ?`, [conversationId]);
      await this.store.executeSql(`DELETE FROM ai_conversations WHERE id = ?`, [conversationId]);

      this.store.commit();
    } catch (error) {
      this.store.rollBack();
      console.error(`[ConversationRepository] deleteConversation failed:`, JSON.stringify(error));
      throw new Error(`删除对话失败: ${error instanceof Error ? error.message : JSON.stringify(error)}`);
    }
  }

  private async loadImagesForMessage(messageId: string): Promise<ChatImageAttachment[]> {
    const resultSet = await this.store.querySql(
      `SELECT id, mime_type, data FROM ai_message_images WHERE message_id = ? ORDER BY position ASC`,
      [messageId]
    );
    const attachments: ChatImageAttachment[] = [];
    try {
      while (resultSet.goToNextRow()) {
        const idIdx = resultSet.getColumnIndex('id');
        const mimeIdx = resultSet.getColumnIndex('mime_type');
        const dataIdx = resultSet.getColumnIndex('data');

        const id = idIdx >= 0 ? resultSet.getString(idIdx) : '';
        const mime = mimeIdx >= 0 ? resultSet.getString(mimeIdx) : 'image/jpeg';
        const data = dataIdx >= 0 ? resultSet.getBlob(dataIdx) : new Uint8Array(0);

        attachments.push(new ChatImageAttachment(id, mime, data));
      }
      return attachments;
    } finally {
      resultSet.close();
    }
  }

  private async loadToolInvocationsForMessage(messageId: string): Promise<ToolInvocation[]> {
    const resultSet = await this.store.querySql(
      `SELECT id, provider_call_id, tool_name, summary, arguments_json, result_json, executed_at
       FROM ai_message_tool_invocations WHERE message_id = ? ORDER BY position ASC`,
      [messageId]
    );
    const tools: ToolInvocation[] = [];
    try {
      while (resultSet.goToNextRow()) {
        const idIdx = resultSet.getColumnIndex('id');
        const callIdIdx = resultSet.getColumnIndex('provider_call_id');
        const nameIdx = resultSet.getColumnIndex('tool_name');
        const sumIdx = resultSet.getColumnIndex('summary');
        const argsIdx = resultSet.getColumnIndex('arguments_json');
        const resIdx = resultSet.getColumnIndex('result_json');
        const timeIdx = resultSet.getColumnIndex('executed_at');

        const id = idIdx >= 0 ? resultSet.getString(idIdx) : '';
        const callId = (callIdIdx >= 0 && !resultSet.isColumnNull(callIdIdx)) ? resultSet.getString(callIdIdx) : null;
        const name = nameIdx >= 0 ? resultSet.getString(nameIdx) : '';
        const sum = sumIdx >= 0 ? resultSet.getString(sumIdx) : '';
        const args = argsIdx >= 0 ? resultSet.getString(argsIdx) : '{}';
        const res = resIdx >= 0 ? resultSet.getString(resIdx) : '{}';
        const time = timeIdx >= 0 ? resultSet.getLong(timeIdx) : Date.now();

        tools.push(new ToolInvocation(id, callId, name, sum, args, res, time));
      }
      return tools;
    } finally {
      resultSet.close();
    }
  }

  private static rowToConversation(resultSet: relationalStore.ResultSet): AIConversation {
    const idIdx = resultSet.getColumnIndex('id');
    const titleIdx = resultSet.getColumnIndex('title');
    const kindIdx = resultSet.getColumnIndex('kind');
    const createIdx = resultSet.getColumnIndex('created_at');
    const updateIdx = resultSet.getColumnIndex('updated_at');

    const id = idIdx >= 0 ? resultSet.getString(idIdx) : '';
    const title = titleIdx >= 0 ? resultSet.getString(titleIdx) : '';
    const kindStr = kindIdx >= 0 ? resultSet.getString(kindIdx) : 'text';
    const createdAtMs = createIdx >= 0 ? resultSet.getLong(createIdx) : Date.now();
    const updatedAtMs = updateIdx >= 0 ? resultSet.getLong(updateIdx) : Date.now();

    const kind = kindStr === 'realtime' ? AIConversationKind.REALTIME : AIConversationKind.TEXT;
    return new AIConversation(id, title, kind, createdAtMs, updatedAtMs);
  }

  private static generateId(): string {
    return `${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;
  }
}
