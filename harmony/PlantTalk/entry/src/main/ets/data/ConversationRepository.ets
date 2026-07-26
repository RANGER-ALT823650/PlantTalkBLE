import {
  AIConversation,
  AIConversationKind,
  ChatMessage
} from '../model/PlantModels';

export interface ConversationRepository {
  createConversation(title?: string, kind?: AIConversationKind): Promise<AIConversation>;

  getConversation(id: string): Promise<AIConversation | null>;

  allConversations(kind?: AIConversationKind): Promise<AIConversation[]>;

  chatMessages(conversationId: string): Promise<ChatMessage[]>;

  saveChatMessage(message: ChatMessage): Promise<void>;

  deleteChatTurn(messageId: string): Promise<void>;

  deleteConversation(conversationId: string): Promise<void>;

  getOrCreateDefaultConversation(kind?: AIConversationKind): Promise<AIConversation>;
}
