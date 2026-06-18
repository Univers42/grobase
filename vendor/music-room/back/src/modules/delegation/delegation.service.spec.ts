import { Test, TestingModule } from '@nestjs/testing';
import { DelegationService } from './delegation.service';
import { getModelToken } from '@nestjs/mongoose';
import { NotFoundException, ForbiddenException } from '@nestjs/common';

describe('DelegationService', () => {
  let service: DelegationService;
  let mockDeviceModel: any;
  let mockDelegationModel: any;

  beforeEach(async () => {
    const DeviceConstructor: any = jest.fn().mockImplementation((data) => ({
      ...data,
      _id: 'device123',
      save: jest.fn().mockResolvedValue({ _id: 'device123', ...data }),
    }));
    DeviceConstructor.find = jest.fn();
    DeviceConstructor.findById = jest.fn();
    DeviceConstructor.findByIdAndDelete = jest.fn();
    DeviceConstructor.findByIdAndUpdate = jest.fn();

    const DelegationConstructor: any = jest.fn().mockImplementation((data) => ({
      ...data,
      _id: 'deleg123',
      save: jest.fn().mockResolvedValue({ _id: 'deleg123', ...data }),
    }));
    DelegationConstructor.find = jest.fn();
    DelegationConstructor.findById = jest.fn();

    mockDeviceModel = DeviceConstructor;
    mockDelegationModel = DelegationConstructor;

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        DelegationService,
        { provide: getModelToken('Device'), useValue: DeviceConstructor },
        { provide: getModelToken('Delegation'), useValue: DelegationConstructor },
      ],
    }).compile();

    service = module.get<DelegationService>(DelegationService);
  });

  describe('registerDevice', () => {
    it('should register a new device for user', async () => {
      const result = await service.registerDevice(
        { name: 'iPhone 15', platform: 'ios' },
        'user123',
      );
      expect(result).toBeDefined();
    });
  });

  describe('getMyDevices', () => {
    it('should return user devices', async () => {
      const devices = [
        { _id: 'd1', name: 'Phone', platform: 'ios', owner: 'user123' },
        { _id: 'd2', name: 'Tablet', platform: 'android', owner: 'user123' },
      ];
      mockDeviceModel.find.mockResolvedValue(devices);

      const result = await service.getMyDevices('user123');
      expect(result).toHaveLength(2);
    });
  });

  describe('removeDevice', () => {
    it('should throw NotFoundException when device not found', async () => {
      mockDeviceModel.findById.mockResolvedValue(null);

      await expect(
        service.removeDevice('nonexistent', 'user123'),
      ).rejects.toThrow(NotFoundException);
    });

    it('should throw ForbiddenException when non-owner tries to remove', async () => {
      mockDeviceModel.findById.mockResolvedValue({
        _id: 'device1',
        owner: { toString: () => 'otherUser' },
      });

      await expect(
        service.removeDevice('device1', 'user123'),
      ).rejects.toThrow(ForbiddenException);
    });
  });

  describe('createDelegation', () => {
    it('should create a delegation with permissions', async () => {
      mockDeviceModel.findById.mockResolvedValue({
        _id: 'device1',
        owner: { toString: () => 'user123' },
      });

      const result = await service.createDelegation(
        {
          delegateId: 'user456',
          targetDeviceId: 'device1',
          permissions: ['playback_control', 'volume_control'],
        },
        'user123',
      );
      expect(result).toBeDefined();
    });
  });

  describe('hasPermission', () => {
    it('should return false when no active delegation exists', async () => {
      mockDelegationModel.findOne.mockResolvedValue(null);

      const result = await service.hasPermission('user456', 'device1', 'playback_control');
      expect(result).toBe(false);
    });
  });
});
