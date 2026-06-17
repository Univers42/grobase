/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   llm-provider.service.ts                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

interface ChatCompletion {
  choices: { message: { content: string } }[];
}

/**
 * Generic OpenAI-compatible LLM client.
 * Works with Groq, OpenAI, Ollama, LM Studio, or any OpenAI-compatible API.
 */
@Injectable()
export class LlmProviderService implements OnModuleInit {
  private readonly logger = new Logger(LlmProviderService.name);
  private apiUrl!: string;
  private apiKey!: string;
  private model!: string;
  private maxTokens!: number;
  private temperature!: number;
  private available = false;

  constructor(private readonly config: ConfigService) {}

  onModuleInit(): void {
    this.apiUrl = this.config.get('LLM_API_URL', 'https://api.groq.com/openai/v1');
    this.apiKey = this.config.get('LLM_API_KEY', '');
    this.model = this.config.get('LLM_MODEL', 'llama-3.3-70b-versatile');
    this.maxTokens = this.config.get('LLM_MAX_TOKENS', 2048);
    this.temperature = this.config.get('LLM_TEMPERATURE', 0.7);

    if (this.apiKey) {
      this.available = true;
      this.logger.log(`LLM provider ready: ${this.model} via ${this.apiUrl}`);
    } else {
      this.logger.warn('LLM_API_KEY not set — AI completions will return fallback messages');
    }
  }

  isAvailable(): boolean {
    return this.available;
  }

  /**
   * Send a chat completion request.
   * Returns the assistant's response text.
   */
  async complete(
    messages: { role: 'system' | 'user' | 'assistant'; content: string }[],
  ): Promise<string> {
    if (!this.available) {
      return 'AI is currently unavailable. Please configure LLM_API_KEY.';
    }

    try {
      const res = await fetch(`${this.apiUrl}/chat/completions`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${this.apiKey}`,
        },
        body: JSON.stringify({
          model: this.model,
          messages,
          max_tokens: this.maxTokens,
          temperature: this.temperature,
        }),
      });

      if (!res.ok) {
        const err = await res.text();
        this.logger.error(`LLM API error ${res.status}: ${err}`);
        return 'Sorry, the AI service encountered an error. Please try again later.';
      }

      const data = (await res.json()) as ChatCompletion;
      return data.choices?.[0]?.message?.content ?? 'No response generated.';
    } catch (err) {
      this.logger.error(`LLM request failed: ${(err as Error).message}`);
      return 'Sorry, the AI service is temporarily unavailable.';
    }
  }
}
