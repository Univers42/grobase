import { Module, NestModule, MiddlewareConsumer } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { MongooseModule } from '@nestjs/mongoose';
import { ThrottlerModule, ThrottlerGuard } from '@nestjs/throttler';
import { APP_GUARD } from '@nestjs/core';
import { AppController } from './app.controller';
import { AppService } from './app.service';
import { AuthModule } from './modules/auth/auth.module';
import { UserModule } from './modules/user/user.module';
import { MusicModule } from './modules/music/music.module';
import { EventModule } from './modules/event/event.module';
import { PlaylistModule } from './modules/playlist/playlist.module';
import { DelegationModule } from './modules/delegation/delegation.module';
import { LoggingModule } from './modules/logging/logging.module';
import { SubscriptionModule } from './modules/subscription/subscription.module';
import { IoTModule } from './modules/iot/iot.module';
import { JwtAuthGuard } from './modules/auth/guards/jwt-auth.guard';
import { SanitizeMiddleware } from './common/middleware/sanitize.middleware';

@Module({
  imports: [
    // Environment variables
    ConfigModule.forRoot({
      isGlobal: true,
      envFilePath: '.env',
    }),

    // MongoDB connection
    MongooseModule.forRoot(process.env.MONGODB_URI || 'mongodb://localhost:27017/music-room'),

    // Rate limiting
    ThrottlerModule.forRoot([
      {
        ttl: parseInt(process.env.THROTTLE_TTL || '60000', 10),
        limit: parseInt(process.env.THROTTLE_LIMIT || '60', 10),
      },
    ]),

    // Feature modules
    AuthModule,
    UserModule,
    MusicModule,
    EventModule,
    PlaylistModule,
    DelegationModule,
    LoggingModule,
    SubscriptionModule,
    IoTModule,
  ],
  controllers: [AppController],
  providers: [
    AppService,
    // Global JWT auth guard — use @Public() to bypass
    { provide: APP_GUARD, useClass: JwtAuthGuard },
    // Global rate limiting guard
    { provide: APP_GUARD, useClass: ThrottlerGuard },
  ],
})
export class AppModule implements NestModule {
  configure(consumer: MiddlewareConsumer) {
    consumer.apply(SanitizeMiddleware).forRoutes('*');
  }
}
