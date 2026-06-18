/**
 * GDPR Module
 */
import { Module } from '@nestjs/common';
import { GdprController } from './gdpr.controller';
import { GdprService } from './gdpr.service';
import { ConsentService } from './consent.service';
import { DataDeletionService } from './data-deletion.service';
import { PrismaModule } from '../prisma';

@Module({
  imports: [PrismaModule],
  controllers: [GdprController],
  providers: [GdprService, ConsentService, DataDeletionService],
  exports: [GdprService, ConsentService, DataDeletionService],
})
export class GdprModule {}
