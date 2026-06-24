import { Test, TestingModule } from '@nestjs/testing';
import { HealthController } from './health.controller';

describe('HealthController', () => {
  let controller: HealthController;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      controllers: [HealthController],
    }).compile();

    controller = module.get<HealthController>(HealthController);
  });

  it('should be defined', () => {
    expect(controller).toBeDefined();
  });

  it('should return health status', async () => {
    const result = await controller.getHealth();
    expect(result).toHaveProperty('status');
    expect(result.status).toBe('ok');
  });

  it('should return readiness status', async () => {
    const result = await controller.getReady();
    expect(result).toHaveProperty('status');
  });

  it('should return liveness status', async () => {
    const result = await controller.getLive();
    expect(result).toHaveProperty('status');
    expect(result.status).toBe('ok');
  });

  it('should include uptime in health response', async () => {
    const result = await controller.getHealth();
    expect(result).toHaveProperty('uptime');
    expect(typeof result.uptime).toBe('number');
  });

  it('should include timestamp in health response', async () => {
    const result = await controller.getHealth();
    expect(result).toHaveProperty('timestamp');
  });
});
