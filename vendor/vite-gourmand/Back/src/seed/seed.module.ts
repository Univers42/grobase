/**
 * Seed Module
 */
import { Module } from '@nestjs/common';
import { SeedController } from './seed.controller';
import { SeedService } from './seed.service';
import { PrismaModule } from '../prisma';
import { UnsplashModule } from '../unsplash';

@Module({
  imports: [PrismaModule, UnsplashModule],
  controllers: [SeedController],
  providers: [SeedService],
  exports: [SeedService],
})
export class SeedModule {}
