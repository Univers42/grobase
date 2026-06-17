/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mongo.module.ts                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Global, Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { MongoService } from './mongo.service';

@Global()
@Module({
  imports: [ConfigModule],
  providers: [MongoService],
  exports: [MongoService],
})
export class MongoModule {}
