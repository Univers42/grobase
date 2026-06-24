import { Test, TestingModule } from '@nestjs/testing';
import { UserService } from './user.service';
import { getModelToken } from '@nestjs/mongoose';
import { NotFoundException } from '@nestjs/common';

describe('UserService', () => {
  let service: UserService;
  let mockUserModel: any;
  let mockFriendModel: any;

  const mockUser = {
    _id: 'user123',
    email: 'test@example.com',
    publicInfo: { displayName: 'Test User', bio: 'Hello!' },
    friendsInfo: { showFriendsList: true },
    privateInfo: { phoneNumber: '555-0123' },
    musicPreferences: { favoriteGenres: ['Rock'], favoriteMoods: ['Happy'] },
    save: jest.fn().mockResolvedValue(true),
  };

  beforeEach(async () => {
    mockUserModel = {
      findById: jest.fn(),
      findOne: jest.fn(),
    };

    mockFriendModel = {
      findOne: jest.fn(),
      find: jest.fn(),
      create: jest.fn(),
      findByIdAndDelete: jest.fn(),
    };

    // Make mockFriendModel callable as constructor
    const FriendConstructor: any = jest.fn().mockImplementation((data) => ({
      ...data,
      save: jest.fn().mockResolvedValue({ _id: 'friend123', ...data }),
    }));
    Object.assign(FriendConstructor, mockFriendModel);

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        UserService,
        { provide: getModelToken('User'), useValue: mockUserModel },
        { provide: getModelToken('Friend'), useValue: FriendConstructor },
      ],
    }).compile();

    service = module.get<UserService>(UserService);
  });

  describe('getProfile', () => {
    it('should throw NotFoundException when user not found', async () => {
      mockUserModel.findById.mockResolvedValue(null);

      await expect(
        service.getProfile('nonexistent', 'viewer123'),
      ).rejects.toThrow(NotFoundException);
    });

    it('should return public info for non-friend viewers', async () => {
      mockUserModel.findById.mockResolvedValue(mockUser);
      mockFriendModel.findOne.mockResolvedValue(null); // not friends

      const result = await service.getProfile('user123', 'stranger');

      expect(result.publicInfo).toBeDefined();
      // Private info should not be returned for strangers
      expect(result.privateInfo).toBeUndefined();
    });
  });

  describe('updatePublicInfo', () => {
    it('should update user display name and bio', async () => {
      const updatedUser = {
        ...mockUser,
        publicInfo: { displayName: 'Updated Name', bio: 'New bio' },
        save: jest.fn().mockResolvedValue(true),
      };
      mockUserModel.findById.mockResolvedValue(updatedUser);

      const result = await service.updatePublicInfo('user123', {
        displayName: 'Updated Name',
        bio: 'New bio',
      });

      expect(updatedUser.save).toHaveBeenCalled();
    });
  });

  describe('sendFriendRequest', () => {
    it('should throw when sending request to self', async () => {
      await expect(
        service.sendFriendRequest('user123', 'user123'),
      ).rejects.toThrow();
    });

    it('should throw when request already exists', async () => {
      mockFriendModel.findOne.mockResolvedValue({ _id: 'existing' });

      await expect(
        service.sendFriendRequest('user123', 'user456'),
      ).rejects.toThrow();
    });
  });
});
