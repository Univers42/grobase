/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   collections.module.ts                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Module } from '@nestjs/common';
import { makeCounterProvider } from '@willsoto/nestjs-prometheus';
import { CollectionsController } from './collections.controller';
import { CollectionsService } from './collections.service';

@Module({
  controllers: [CollectionsController],
  providers: [
    CollectionsService,
    makeCounterProvider({
      name: 'mongo_operations_total',
      help: 'Total MongoDB operations',
      labelNames: ['collection', 'operation'],
    }),
  ],
})
export class CollectionsModule {}
