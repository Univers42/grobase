/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   current-user.decorator.ts                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 22:30:38 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { createParamDecorator, ExecutionContext } from '@nestjs/common';
import { UserContext, VerifiedRequestIdentity } from '../interfaces/user-context.interface';
import { Request } from 'express';

/**
 * Parameter decorator to inject the authenticated user context.
 * @example async findAll(@CurrentUser() user: UserContext) { … }
 */
export const CurrentUser = createParamDecorator(
  (_data: unknown, ctx: ExecutionContext): UserContext => {
    const request = ctx.switchToHttp().getRequest<Request>();
    if (!request.user) {
      throw new Error('CurrentUser decorator used without AuthGuard');
    }
    return request.user;
  },
);

export const CurrentIdentity = createParamDecorator(
  (_data: unknown, ctx: ExecutionContext): VerifiedRequestIdentity => {
    const request = ctx.switchToHttp().getRequest<Request>();
    if (!request.identity) {
      throw new Error('CurrentIdentity decorator used without AuthGuard');
    }
    return request.identity;
  },
);
