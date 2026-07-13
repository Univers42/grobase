/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   sqlro.dto.ts                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/07/12 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/07/12 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { IsNotEmpty, IsString, MaxLength } from 'class-validator';

/** Body of a read-only SQL run: one SELECT statement against a postgres mount. */
export class SqlRoDto {
  @IsString()
  @IsNotEmpty()
  @MaxLength(10000)
  sql!: string;
}
