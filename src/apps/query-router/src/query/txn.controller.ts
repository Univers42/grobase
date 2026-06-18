import { Body, Controller, Post, Req, UseGuards } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import {
  AuthGuard,
  CurrentIdentity,
  CurrentUser,
  UserContext,
  VerifiedRequestIdentity,
} from '@mini-baas/common';
import type { Request } from 'express';
import { QueryService, TxnResult } from './query.service';
import { TxnRequestDto } from './dto/txn.dto';

// Root-mounted like QueryController: Kong strips `/query/v1`, so this serves at
// `/query/v1/txn`.
@ApiTags('query')
@Controller('txn')
@UseGuards(AuthGuard)
export class TxnController {
  constructor(private readonly service: QueryService) {}

  @Post()
  @ApiOperation({
    summary:
      'Run a single-mount atomic write batch (all-or-nothing). Engine must be transactional (postgresql/mysql).',
  })
  async txn(
    @CurrentUser() user: UserContext,
    @CurrentIdentity() identity: VerifiedRequestIdentity,
    @Body() dto: TxnRequestDto,
    @Req() request: Request,
  ): Promise<TxnResult> {
    return this.service.executeTransaction(dto.mount, user.id, dto.operations, {
      requestId: request.requestId,
      identity,
    });
  }
}
