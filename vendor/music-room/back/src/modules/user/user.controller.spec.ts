import { Test, TestingModule } from '@nestjs/testing';
import { UserController } from './user.controller';
import { UserService } from './user.service';

describe('UserController', () => {
  let controller: UserController;
  let userService: jest.Mocked<Partial<UserService>>;

  beforeEach(async () => {
    userService = {
      getProfile: jest.fn(),
      updatePublicInfo: jest.fn(),
      updatePrivateInfo: jest.fn(),
      updateMusicPreferences: jest.fn(),
      searchUsers: jest.fn(),
      sendFriendRequest: jest.fn(),
      acceptFriendRequest: jest.fn(),
      declineFriendRequest: jest.fn(),
      getFriends: jest.fn(),
      removeFriend: jest.fn(),
    };

    const module: TestingModule = await Test.createTestingModule({
      controllers: [UserController],
      providers: [{ provide: UserService, useValue: userService }],
    }).compile();

    controller = module.get<UserController>(UserController);
  });

  it('should be defined', () => {
    expect(controller).toBeDefined();
  });

  describe('getProfile', () => {
    it('should get profile with requester context', async () => {
      const profile = { _id: 'u2', publicInfo: { displayName: 'Bob' } };
      userService.getProfile.mockResolvedValue(profile as any);

      const result = await controller.getProfile('u2', { _id: 'u1' } as any);

      expect(userService.getProfile).toHaveBeenCalledWith('u2', 'u1');
      expect(result).toEqual(profile);
    });
  });

  describe('updatePublicInfo', () => {
    it('should update public info for current user', async () => {
      const dto = { displayName: 'New Name' };
      const user = { _id: 'u1' };
      userService.updatePublicInfo.mockResolvedValue({} as any);

      await controller.updatePublicInfo(user as any, dto as any);

      expect(userService.updatePublicInfo).toHaveBeenCalledWith('u1', dto);
    });
  });

  describe('searchUsers', () => {
    it('should search users with query', async () => {
      const users = [{ _id: 'u1' }, { _id: 'u2' }];
      userService.searchUsers.mockResolvedValue(users as any);

      const result = await controller.searchUsers('bob');

      expect(userService.searchUsers).toHaveBeenCalledWith('bob');
      expect(result).toHaveLength(2);
    });
  });

  describe('sendFriendRequest', () => {
    it('should send friend request from current user', async () => {
      const user = { _id: 'u1' };
      userService.sendFriendRequest.mockResolvedValue({} as any);

      await controller.sendFriendRequest(user as any, 'u2');

      expect(userService.sendFriendRequest).toHaveBeenCalledWith('u1', 'u2');
    });
  });

  describe('getFriends', () => {
    it('should return friends list for current user', async () => {
      const user = { _id: 'u1' };
      const friends = [{ _id: 'f1' }];
      userService.getFriends.mockResolvedValue(friends as any);

      const result = await controller.getFriends(user as any);

      expect(userService.getFriends).toHaveBeenCalledWith('u1');
      expect(result).toHaveLength(1);
    });
  });
});
