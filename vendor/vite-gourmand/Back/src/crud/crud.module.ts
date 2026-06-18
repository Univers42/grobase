/**
 * CRUD Module
 */
import { Module, Global } from '@nestjs/common';
import { CrudService } from './crud.service';
import { CrudController } from './crud.controller';
import { PrismaModule } from '../prisma';

@Global()
@Module({
  imports: [PrismaModule],
  controllers: [CrudController],
  providers: [CrudService],
  exports: [CrudService],
})
export class CrudModule {}
