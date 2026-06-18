import { Test, TestingModule } from '@nestjs/testing';
import { DelegationController } from './delegation.controller';
import { DelegationService } from './delegation.service';

describe('DelegationController', () => {
  let controller: DelegationController;
  let service: jest.Mocked<Partial<DelegationService>>;

  beforeEach(async () => {
    service = {
      registerDevice: jest.fn(),
      getUserDevices: jest.fn(),
      removeDevice: jest.fn(),
      createDelegation: jest.fn(),
      getUserDelegations: jest.fn(),
      revokeDelegation: jest.fn(),
      checkPermission: jest.fn(),
    };

    const module: TestingModule = await Test.createTestingModule({
      controllers: [DelegationController],
      providers: [{ provide: DelegationService, useValue: service }],
    }).compile();

    controller = module.get<DelegationController>(DelegationController);
  });

  it('should be defined', () => {
    expect(controller).toBeDefined();
  });

  describe('registerDevice', () => {
    it('should register device for current user', async () => {
      const dto = { name: 'iPhone', type: 'MOBILE' };
      const user = { _id: 'u1' };
      service.registerDevice.mockResolvedValue({ _id: 'd1', ...dto } as any);

      const result = await controller.registerDevice(user as any, dto as any);

      expect(service.registerDevice).toHaveBeenCalledWith('u1', dto);
      expect(result._id).toBe('d1');
    });
  });

  describe('getUserDevices', () => {
    it('should return user devices', async () => {
      const user = { _id: 'u1' };
      const devices = [{ _id: 'd1' }];
      service.getUserDevices.mockResolvedValue(devices as any);

      const result = await controller.getUserDevices(user as any);

      expect(service.getUserDevices).toHaveBeenCalledWith('u1');
      expect(result).toHaveLength(1);
    });
  });

  describe('createDelegation', () => {
    it('should create delegation', async () => {
      const dto = { delegateId: 'u2', permissions: ['PLAY'] };
      const user = { _id: 'u1' };
      service.createDelegation.mockResolvedValue({ _id: 'del1' } as any);

      const result = await controller.createDelegation(user as any, dto as any);

      expect(service.createDelegation).toHaveBeenCalledWith('u1', dto);
      expect(result._id).toBe('del1');
    });
  });

  describe('revokeDelegation', () => {
    it('should revoke delegation', async () => {
      const user = { _id: 'u1' };
      service.revokeDelegation.mockResolvedValue(undefined);

      await controller.revokeDelegation('del1', user as any);

      expect(service.revokeDelegation).toHaveBeenCalledWith('del1', 'u1');
    });
  });
});
