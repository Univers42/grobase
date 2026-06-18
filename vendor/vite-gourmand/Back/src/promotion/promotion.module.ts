/**
 * Promotion Module
 */
import { Module } from '@nestjs/common';
import { PromotionController } from './promotion.controller';
import { PromotionService } from './promotion.service';
import { NewsletterModule } from '../newsletter';

@Module({
  imports: [NewsletterModule],
  controllers: [PromotionController],
  providers: [PromotionService],
  exports: [PromotionService],
})
export class PromotionModule {}
