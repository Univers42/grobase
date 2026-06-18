import { Test, TestingModule } from '@nestjs/testing';
import { LoggingInterceptor } from './logging.interceptor';
import { LoggingService } from './logging.service';
import { ExecutionContext, CallHandler } from '@nestjs/common';
import { of } from 'rxjs';

describe('LoggingInterceptor', () => {
  let interceptor: LoggingInterceptor;
  let loggingService: jest.Mocked<Partial<LoggingService>>;

  beforeEach(async () => {
    loggingService = {
      logRequest: jest.fn().mockResolvedValue(undefined),
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        LoggingInterceptor,
        { provide: LoggingService, useValue: loggingService },
      ],
    }).compile();

    interceptor = module.get<LoggingInterceptor>(LoggingInterceptor);
  });

  it('should be defined', () => {
    expect(interceptor).toBeDefined();
  });

  it('should log request and pass through', (done) => {
    const mockRequest = {
      method: 'GET',
      url: '/api/test',
      ip: '127.0.0.1',
      headers: { 'user-agent': 'jest' },
      user: { _id: 'user1' },
    };

    const mockResponse = {
      statusCode: 200,
    };

    const context: Partial<ExecutionContext> = {
      switchToHttp: jest.fn().mockReturnValue({
        getRequest: () => mockRequest,
        getResponse: () => mockResponse,
      }),
    };

    const handler: Partial<CallHandler> = {
      handle: () => of({ data: 'test' }),
    };

    interceptor
      .intercept(context as ExecutionContext, handler as CallHandler)
      .subscribe({
        next: (value) => {
          expect(value).toEqual({ data: 'test' });
        },
        complete: () => {
          // Give the fire-and-forget log call time to complete
          setTimeout(() => {
            expect(loggingService.logRequest).toHaveBeenCalled();
            done();
          }, 50);
        },
      });
  });
});
