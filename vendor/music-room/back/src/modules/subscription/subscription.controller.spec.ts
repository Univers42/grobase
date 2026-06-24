import { Test, TestingModule } from '@nestjs/testing';
import { SubscriptionController } from './subscription.controller';
import { SubscriptionService } from './subscription.service';

describe('SubscriptionController', () => {
  let controller: SubscriptionController;
  let subscriptionService: jest.Mocked<Partial<SubscriptionService>>;

  beforeEach(async () => {
    subscriptionService = {
      getSubscription: jest.fn(),
      upgrade: jest.fn(),
      cancel: jest.fn(),
      checkFeature: jest.fn(),
    };

    const module: TestingModule = await Test.createTestingModule({
      controllers: [SubscriptionController],
      providers: [{ provide: SubscriptionService, useValue: subscriptionService }],
    }).compile();

    controller = module.get<SubscriptionController>(SubscriptionController);
  });

  it('should be defined', () => {
    expect(controller).toBeDefined();
  });

  describe('getSubscription', () => {
    it('should return user subscription', async () => {
      const sub = { plan: 'FREE', features: {} };
      const user = { _id: 'u1' };
      subscriptionService.getSubscription.mockResolvedValue(sub as any);

      const result = await controller.getSubscription(user as any);

      expect(subscriptionService.getSubscription).toHaveBeenCalledWith('u1');
      expect(result).toEqual(sub);
    });
  });

  describe('upgrade', () => {
    it('should upgrade user plan', async () => {
      const dto = { plan: 'PREMIUM' };
      const user = { _id: 'u1' };
      subscriptionService.upgrade.mockResolvedValue({} as any);

      await controller.upgrade(user as any, dto as any);

      expect(subscriptionService.upgrade).toHaveBeenCalledWith('u1', dto);
    });
  });

  describe('cancel', () => {
    it('should cancel user subscription', async () => {
      const user = { _id: 'u1' };
      subscriptionService.cancel.mockResolvedValue(undefined);

      await controller.cancel(user as any);

      expect(subscriptionService.cancel).toHaveBeenCalledWith('u1');
    });
  });
});
