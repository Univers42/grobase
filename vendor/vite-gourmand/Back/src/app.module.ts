import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { ThrottlerModule, ThrottlerGuard } from '@nestjs/throttler';
import { CacheModule } from '@nestjs/cache-manager';
import { AcceptLanguageResolver, I18nModule, QueryResolver } from 'nestjs-i18n';
import { existsSync } from 'node:fs';
import * as path from 'node:path';
import { APP_GUARD, APP_FILTER, APP_INTERCEPTOR, APP_PIPE } from '@nestjs/core';
import { AppController } from './app.controller';
import { AppService } from './app.service';
import { AnalyticsModule } from './analytics';
import { PrismaModule } from './prisma';
import { AuthModule } from './auth';
import { MenuModule } from './menu';
import { OrderModule } from './order';
import { DishModule } from './dish';
import { UserModule } from './user';
import { AdminModule } from './admin';
import { WorkingHoursModule } from './working-hours';
import { ReviewModule } from './review';
import { DietModule } from './diet';
import { ThemeModule } from './theme';
import { AllergenModule } from './allergen';
import { CrudModule } from './crud/crud.module';
import { MailModule } from './mail';
import { LoggingModule, HttpLogInterceptor } from './logging';
import { TestRunnerModule } from './test/test-runner';
// New API modules for complete database coverage
import { ContactModule } from './contact';
import { DiscountModule } from './discount';
import { LoyaltyModule } from './loyalty';
import { IngredientModule } from './ingredient';
import { DeliveryModule } from './delivery';
import { NotificationModule } from './message/notification';
import { MessageModule } from './message';
import { SupportModule } from './support';
import { KanbanModule } from './kanban';
import { TimeOffModule } from './timeoff';
import { GdprModule } from './gdpr';
import { ConsentModule } from './consent/consent.module';
import { SessionModule } from './session';
import { ImageModule } from './image';
import { RoleModule } from './role';
import { UnsplashModule } from './unsplash';
import { SeedModule } from './seed';
import { SiteInfoModule } from './site-info';
import { PromotionModule } from './promotion';
import { AiAgentModule } from './ai-agent';
import { NewsletterModule } from './newsletter';
import {
  JwtAuthGuard,
  RolesGuard,
  HttpExceptionFilter,
  AllExceptionsFilter,
  LoggingInterceptor,
  TransformInterceptor,
  CustomValidationPipe,
} from './common';

function resolveI18nPath(): string {
  const candidates = [
    path.join(process.cwd(), 'src', 'i18n'),
    path.join(__dirname, 'i18n'),
    path.join(process.cwd(), 'dist', 'src', 'i18n'),
  ];

  return candidates.find((candidate) => existsSync(candidate)) ?? candidates[0];
}

@Module({
  imports: [
    // Configuration
    ConfigModule.forRoot({
      isGlobal: true,
      envFilePath: '.env',
    }),
    // Internationalization (i18n)
    I18nModule.forRoot({
      fallbackLanguage: 'en',
      loaderOptions: {
        path: resolveI18nPath(),
        watch: true,
      },
      resolvers: [
        { use: QueryResolver, options: ['lang'] },
        AcceptLanguageResolver,
      ],
    }),
    // Rate limiting (Throttler) - disabled in test environment
    ThrottlerModule.forRoot({
      throttlers:
        process.env.NODE_ENV === 'test'
          ? []
          : [
              {
                name: 'short',
                ttl: 1000, // 1 second
                limit: 20, // 20 requests per second (SPA fires parallel calls on load)
              },
              {
                name: 'medium',
                ttl: 10000, // 10 seconds
                limit: 100, // 100 requests per 10 seconds
              },
              {
                name: 'long',
                ttl: 60000, // 1 minute
                limit: 300, // 300 requests per minute
              },
            ],
    }),
    // Caching
    CacheModule.register({
      isGlobal: true,
      ttl: 60000, // Default cache TTL: 60 seconds
      max: 100, // Maximum number of cached items
    }),
    // Database
    PrismaModule,
    AnalyticsModule,
    // Logging (real-time streaming)
    LoggingModule,
    // Features
    AuthModule,
    MenuModule,
    OrderModule,
    DishModule,
    UserModule,
    AdminModule,
    WorkingHoursModule,
    ReviewModule,
    DietModule,
    ThemeModule,
    AllergenModule,
    CrudModule,
    MailModule,
    // Test Runner (for QA dashboard)
    TestRunnerModule,
    // New API modules for complete database coverage
    ContactModule,
    DiscountModule,
    LoyaltyModule,
    IngredientModule,
    DeliveryModule,
    NotificationModule,
    MessageModule,
    SupportModule,
    KanbanModule,
    TimeOffModule,
    GdprModule,
    ConsentModule,
    SessionModule,
    ImageModule,
    RoleModule,
    UnsplashModule,
    SeedModule,
    SiteInfoModule,
    PromotionModule,
    AiAgentModule,
    NewsletterModule,
  ],
  controllers: [AppController],
  providers: [
    AppService,
    // Global Guards (order matters: Throttler first, then Auth, then Roles)
    {
      provide: APP_GUARD,
      useClass: ThrottlerGuard,
    },
    {
      provide: APP_GUARD,
      useClass: JwtAuthGuard,
    },
    {
      provide: APP_GUARD,
      useClass: RolesGuard,
    },
    // Global Filters (AllExceptions is fallback, HttpException is specific)
    {
      provide: APP_FILTER,
      useClass: AllExceptionsFilter,
    },
    {
      provide: APP_FILTER,
      useClass: HttpExceptionFilter,
    },
    // Global Interceptors
    {
      provide: APP_INTERCEPTOR,
      useClass: HttpLogInterceptor,
    },
    {
      provide: APP_INTERCEPTOR,
      useClass: LoggingInterceptor,
    },
    {
      provide: APP_INTERCEPTOR,
      useClass: TransformInterceptor,
    },
    // Global Pipes
    {
      provide: APP_PIPE,
      useClass: CustomValidationPipe,
    },
  ],
})
export class AppModule {}
