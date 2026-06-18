/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   chat.service.ts                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 22:11:47 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  Injectable,
  InternalServerErrorException,
  Logger,
  NotFoundException,
  OnModuleInit,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { MongoService } from '@mini-baas/database';
import { Collection, ObjectId } from 'mongodb';
import { LlmProviderService } from './llm-provider.service';

export interface ConversationMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

interface ConversationDoc {
  _id?: ObjectId;
  userId?: string;
  mode: string;
  messages: ConversationMessage[];
  createdAt: Date;
  updatedAt: Date;
}

const DEFAULT_SYSTEM_PROMPT =
  "You are a helpful assistant. Answer the user's questions accurately and concisely.";

@Injectable()
export class ChatService implements OnModuleInit {
  private readonly logger = new Logger(ChatService.name);
  private conversations!: Collection<ConversationDoc>;
  private promptTemplates!: Collection;

  constructor(
    private readonly mongo: MongoService,
    private readonly config: ConfigService,
    private readonly llm: LlmProviderService,
  ) {}

  async onModuleInit(): Promise<void> {
    const db = this.mongo.getDb();
    this.conversations = db.collection<ConversationDoc>('conversations');
    this.promptTemplates = db.collection('prompt_templates');

    // TTL index for auto-cleanup
    const ttlHours = this.config.get<number>('AI_CONVERSATION_TTL_HOURS', 24);
    await this.conversations
      .createIndex({ updatedAt: 1 }, { expireAfterSeconds: ttlHours * 3600, name: 'ttl_cleanup' })
      .catch(() => {
        /* already exists */
      });

    await this.conversations.createIndex({ userId: 1, updatedAt: -1 }).catch(() => {});
    this.logger.log('Chat collections indexed');
  }

  /**
   * Send a message in a conversation.
   * Creates a new conversation if no conversationId is given.
   */
  async chat(
    message: string,
    opts: {
      conversationId?: string;
      userId?: string;
      mode?: string;
      context?: Record<string, unknown>;
    },
  ): Promise<{ conversationId: string; reply: string }> {
    let conv: ConversationDoc | null = null;

    // Resume existing conversation
    if (opts.conversationId) {
      conv = await this.conversations.findOne({ _id: new ObjectId(opts.conversationId) });
      if (!conv) throw new NotFoundException('Conversation not found');
    }

    // Start new conversation
    if (!conv) {
      const systemPrompt = await this.buildSystemPrompt(opts.mode ?? 'default', opts.context);
      conv = {
        userId: opts.userId,
        mode: opts.mode ?? 'default',
        messages: [{ role: 'system', content: systemPrompt }],
        createdAt: new Date(),
        updatedAt: new Date(),
      };
      const result = await this.conversations.insertOne(conv);
      conv._id = result.insertedId;
    }

    // Add user message
    conv.messages.push({ role: 'user', content: message });

    // Get LLM response
    const reply = await this.llm.complete(conv.messages);

    // Add assistant reply
    conv.messages.push({ role: 'assistant', content: reply });

    // Persist
    const conversationObjectId = conv._id;
    if (!conversationObjectId)
      throw new InternalServerErrorException('Conversation id was not assigned');
    await this.conversations.updateOne(
      { _id: conversationObjectId },
      { $set: { messages: conv.messages, updatedAt: new Date() } },
    );

    return {
      conversationId: conversationObjectId.toHexString(),
      reply,
    };
  }

  /** List a user's conversations */
  async listConversations(userId: string) {
    const docs = await this.conversations
      .find(
        { userId },
        {
          projection: { _id: 1, mode: 1, createdAt: 1, updatedAt: 1 },
          sort: { updatedAt: -1 },
          limit: 50,
        },
      )
      .toArray();

    return docs.map((d) => ({
      id: d._id.toHexString(),
      mode: d.mode,
      createdAt: d.createdAt,
      updatedAt: d.updatedAt,
    }));
  }

  /** Get a conversation with messages */
  async getConversation(conversationId: string, userId?: string) {
    const filter: Record<string, unknown> = { _id: new ObjectId(conversationId) };
    if (userId) filter['userId'] = userId;

    const doc = await this.conversations.findOne(filter);
    if (!doc) throw new NotFoundException('Conversation not found');

    return {
      id: doc._id.toHexString(),
      mode: doc.mode,
      messages: doc.messages.filter((m) => m.role !== 'system'),
      createdAt: doc.createdAt,
      updatedAt: doc.updatedAt,
    };
  }

  /** Delete a conversation */
  async deleteConversation(conversationId: string, userId?: string) {
    const filter: Record<string, unknown> = { _id: new ObjectId(conversationId) };
    if (userId) filter['userId'] = userId;

    const result = await this.conversations.deleteOne(filter);
    if (result.deletedCount === 0) throw new NotFoundException('Conversation not found');
    return { deleted: true };
  }

  /**
   * Build the system prompt from the template for a given mode.
   * Injects the optional `context` object as a JSON string.
   */
  private async buildSystemPrompt(
    mode: string,
    context?: Record<string, unknown>,
  ): Promise<string> {
    const template = await this.promptTemplates.findOne({ mode });
    let prompt = (template?.['template'] as string) ?? DEFAULT_SYSTEM_PROMPT;

    if (context) {
      const contextStr = JSON.stringify(context, null, 2);
      prompt = prompt.replace('{context}', contextStr);
    }

    return prompt;
  }
}
