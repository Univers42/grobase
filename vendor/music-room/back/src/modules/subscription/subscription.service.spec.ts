import { Test, TestingModule } from '@nestjs/testing';
import { SubscriptionService } from './subscription.service';
import { getModelToken } from '@nestjs/mongoose';

describe('SubscriptionService', () => {
  let service: SubscriptionService;
  let mockSubModel: any;

  beforeEach(async () => {
    const ModelConstructor: any = jest.fn().mockImplementation((data) => ({
      ...data,
      _id: 'sub123',
      save: jest.fn().mockResolvedValue({ _id: 'sub123', ...data }),
    }));

    ModelConstructor.findOne = jest.fn();
    ModelConstructor.findById = jest.fn();

    mockSubModel = ModelConstructor;

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        SubscriptionService,
        { provide: getModelToken('Subscription'), useValue: ModelConstructor },
      ],
    }).compile();

    service = module.get<SubscriptionService>(SubscriptionService);
  });

  describe('getSubscription', () => {
    it('should return existing subscription', async () => {
      const existing = { _id: 'sub1', user: 'user123', plan: 'free', status: 'active' };
      mockSubModel.findOne.mockResolvedValue(existing);

      const result = await service.getSubscription('user123');
      expect(result.plan).toBe('free');
    });

    it('should auto-create FREE subscription when none exists', async () => {
      mockSubModel.findOne.mockResolvedValue(null);

      const result = await service.getSubscription('user123');
      expect(result).toBeDefined();
    });
  });

  describe('checkFeature', () => {
    it('should return true for features in current plan', async () => {
      mockSubModel.findOne.mockResolvedValue({
        plan: 'premium',
        status: 'active',
        features: { canCreatePrivateEvents: true, offlineMode: true },
      });

      const result = await service.checkFeature('user123', 'canCreatePrivateEvents');
      expect(result).toBe(true);
    });
  });
});
