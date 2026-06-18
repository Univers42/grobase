/**
 * Session Module
 */
import { Module } from '@nestjs/common';
import { SessionController } from './session.controller';
import { SessionService } from './session.service';
import { UserSessionService } from './user-session.service';
import { AdminSessionService } from './admin-session.service';
import { PrismaModule } from '../prisma';

@Module({
  imports: [PrismaModule],
  controllers: [SessionController],
  providers: [SessionService, UserSessionService, AdminSessionService],
  exports: [SessionService, UserSessionService, AdminSessionService],
})
export class SessionModule {}
