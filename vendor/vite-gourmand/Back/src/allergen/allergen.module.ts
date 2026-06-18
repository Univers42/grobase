/**
 * Allergen Module
 */
import { Module } from '@nestjs/common';
import { AllergenController } from './allergen.controller';
import { AllergenService } from './allergen.service';

@Module({
  controllers: [AllergenController],
  providers: [AllergenService],
  exports: [AllergenService],
})
export class AllergenModule {}
