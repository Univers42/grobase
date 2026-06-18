/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   prompts.service.ts                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 22:11:47 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  Injectable,
  Logger,
  ConflictException,
  NotFoundException,
  OnModuleInit,
} from '@nestjs/common';
import { MongoService } from '@mini-baas/database';
import { Collection } from 'mongodb';

export interface PromptTemplate {
  mode: string;
  template: string;
  description?: string;
  createdAt: Date;
  updatedAt: Date;
}

@Injectable()
export class PromptsService implements OnModuleInit {
  private readonly logger = new Logger(PromptsService.name);
  private collection!: Collection<PromptTemplate>;

  constructor(private readonly mongo: MongoService) {}

  async onModuleInit(): Promise<void> {
    this.collection = this.mongo.getDb().collection<PromptTemplate>('prompt_templates');
    await this.collection.createIndex({ mode: 1 }, { unique: true }).catch(() => {});

    // Seed default prompt if none exist
    const count = await this.collection.countDocuments();
    if (count === 0) {
      await this.collection.insertOne({
        mode: 'default',
        template:
          "You are a helpful assistant. Answer the user's questions accurately and concisely.\n\nContext:\n{context}",
        description: 'Default general-purpose assistant',
        createdAt: new Date(),
        updatedAt: new Date(),
      });
      this.logger.log('Seeded default prompt template');
    }
  }

  async list(): Promise<PromptTemplate[]> {
    return this.collection.find({}, { sort: { mode: 1 } }).toArray();
  }

  async get(mode: string): Promise<PromptTemplate | null> {
    return this.collection.findOne({ mode });
  }

  async create(mode: string, template: string, description?: string): Promise<PromptTemplate> {
    const existing = await this.collection.findOne({ mode });
    if (existing) throw new ConflictException(`Prompt mode "${mode}" already exists`);

    const doc: PromptTemplate = {
      mode,
      template,
      description,
      createdAt: new Date(),
      updatedAt: new Date(),
    };
    await this.collection.insertOne(doc);
    return doc;
  }

  async update(mode: string, template: string, description?: string): Promise<PromptTemplate> {
    const result = await this.collection.findOneAndUpdate(
      { mode },
      { $set: { template, description, updatedAt: new Date() } },
      { returnDocument: 'after' },
    );
    if (!result) throw new NotFoundException(`Prompt mode "${mode}" not found`);
    return result;
  }

  async remove(mode: string): Promise<{ deleted: boolean }> {
    const r = await this.collection.deleteOne({ mode });
    if (r.deletedCount === 0) throw new NotFoundException(`Prompt mode "${mode}" not found`);
    return { deleted: true };
  }
}
