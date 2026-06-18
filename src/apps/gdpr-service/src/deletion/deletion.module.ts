/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   deletion.module.ts                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Module } from '@nestjs/common';
import { DeletionController } from './deletion.controller';
import { DeletionService } from './deletion.service';

@Module({
  controllers: [DeletionController],
  providers: [DeletionService],
  exports: [DeletionService],
})
export class DeletionModule {}
