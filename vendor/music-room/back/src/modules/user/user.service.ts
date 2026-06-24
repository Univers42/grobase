import {
  Injectable,
  NotFoundException,
  ConflictException,
  BadRequestException,
} from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model, Types } from 'mongoose';
import { User } from './schemas/user.schema';
import { Friend, FriendStatus } from './schemas/friend.schema';
import {
  UpdatePublicInfoDto,
  UpdateFriendsInfoDto,
  UpdatePrivateInfoDto,
  UpdateMusicPreferencesDto,
} from './dto';

@Injectable()
export class UserService {
  constructor(
    @InjectModel(User.name) private readonly userModel: Model<User>,
    @InjectModel(Friend.name) private readonly friendModel: Model<Friend>,
  ) {}

  // ─── Get Own Profile ─────────────────────────────────

  async getMyProfile(userId: string): Promise<User> {
    const user = await this.userModel
      .findById(userId)
      .select('-passwordHash -refreshTokenHash -emailVerificationToken -passwordResetToken');
    if (!user) throw new NotFoundException('User not found');
    return user;
  }

  // ─── Get Other User's Profile (privacy-aware) ───────

  async getUserProfile(requesterId: string, targetId: string) {
    const target = await this.userModel.findById(targetId);
    if (!target) throw new NotFoundException('User not found');

    // Always return public info
    const result: Record<string, unknown> = {
      _id: target._id,
      publicInfo: target.publicInfo,
      musicPreferences: target.musicPreferences,
    };

    // If requester is the target user, return everything
    if (requesterId === targetId) {
      return {
        ...result,
        friendsInfo: target.friendsInfo,
        privateInfo: target.privateInfo,
        email: target.email,
        linkedAccounts: target.linkedAccounts,
        isEmailVerified: target.isEmailVerified,
      };
    }

    // Check if they are friends
    const friendship = await this.friendModel.findOne({
      $or: [
        { requester: requesterId, recipient: targetId },
        { requester: targetId, recipient: requesterId },
      ],
      status: FriendStatus.ACCEPTED,
    });

    if (friendship) {
      result.friendsInfo = target.friendsInfo;
    }

    return result;
  }

  // ─── Update Profile Sections ─────────────────────────

  async updatePublicInfo(userId: string, dto: UpdatePublicInfoDto): Promise<User> {
    const updateFields: Record<string, unknown> = {};
    if (dto.displayName !== undefined) updateFields['publicInfo.displayName'] = dto.displayName;
    if (dto.avatar !== undefined) updateFields['publicInfo.avatar'] = dto.avatar;
    if (dto.bio !== undefined) updateFields['publicInfo.bio'] = dto.bio;

    const user = await this.userModel.findByIdAndUpdate(
      userId,
      { $set: updateFields },
      { new: true },
    ).select('-passwordHash -refreshTokenHash');

    if (!user) throw new NotFoundException('User not found');
    return user;
  }

  async updateFriendsInfo(userId: string, dto: UpdateFriendsInfoDto): Promise<User> {
    const updateFields: Record<string, unknown> = {};
    if (dto.phone !== undefined) updateFields['friendsInfo.phone'] = dto.phone;
    if (dto.city !== undefined) updateFields['friendsInfo.city'] = dto.city;
    if (dto.age !== undefined) updateFields['friendsInfo.age'] = dto.age;

    const user = await this.userModel.findByIdAndUpdate(
      userId,
      { $set: updateFields },
      { new: true },
    ).select('-passwordHash -refreshTokenHash');

    if (!user) throw new NotFoundException('User not found');
    return user;
  }

  async updatePrivateInfo(userId: string, dto: UpdatePrivateInfoDto): Promise<User> {
    const updateFields: Record<string, unknown> = {};
    if (dto.emailNotifications !== undefined) updateFields['privateInfo.emailNotifications'] = dto.emailNotifications;
    if (dto.personalNotes !== undefined) updateFields['privateInfo.personalNotes'] = dto.personalNotes;

    const user = await this.userModel.findByIdAndUpdate(
      userId,
      { $set: updateFields },
      { new: true },
    ).select('-passwordHash -refreshTokenHash');

    if (!user) throw new NotFoundException('User not found');
    return user;
  }

  async updateMusicPreferences(userId: string, dto: UpdateMusicPreferencesDto): Promise<User> {
    const updateFields: Record<string, unknown> = {};
    if (dto.favoriteGenres !== undefined) updateFields['musicPreferences.favoriteGenres'] = dto.favoriteGenres;
    if (dto.favoriteArtists !== undefined) updateFields['musicPreferences.favoriteArtists'] = dto.favoriteArtists;
    if (dto.preferredMoods !== undefined) updateFields['musicPreferences.preferredMoods'] = dto.preferredMoods;

    const user = await this.userModel.findByIdAndUpdate(
      userId,
      { $set: updateFields },
      { new: true },
    ).select('-passwordHash -refreshTokenHash');

    if (!user) throw new NotFoundException('User not found');
    return user;
  }

  // ─── Friend System ───────────────────────────────────

  async sendFriendRequest(requesterId: string, recipientId: string): Promise<Friend> {
    if (requesterId === recipientId) {
      throw new BadRequestException('Cannot send friend request to yourself');
    }

    const recipientExists = await this.userModel.exists({ _id: recipientId });
    if (!recipientExists) throw new NotFoundException('User not found');

    // Check if friendship already exists (in either direction)
    const existing = await this.friendModel.findOne({
      $or: [
        { requester: requesterId, recipient: recipientId },
        { requester: recipientId, recipient: requesterId },
      ],
    });

    if (existing) {
      if (existing.status === FriendStatus.ACCEPTED) {
        throw new ConflictException('Already friends');
      }
      throw new ConflictException('Friend request already exists');
    }

    return this.friendModel.create({
      requester: new Types.ObjectId(requesterId),
      recipient: new Types.ObjectId(recipientId),
      status: FriendStatus.PENDING,
    });
  }

  async acceptFriendRequest(userId: string, requesterId: string): Promise<Friend> {
    const friendship = await this.friendModel.findOne({
      requester: requesterId,
      recipient: userId,
      status: FriendStatus.PENDING,
    });

    if (!friendship) {
      throw new NotFoundException('No pending friend request from this user');
    }

    friendship.status = FriendStatus.ACCEPTED;
    return friendship.save();
  }

  async removeFriend(userId: string, friendId: string): Promise<{ message: string }> {
    const result = await this.friendModel.findOneAndDelete({
      $or: [
        { requester: userId, recipient: friendId },
        { requester: friendId, recipient: userId },
      ],
    });

    if (!result) throw new NotFoundException('Friendship not found');
    return { message: 'Friend removed successfully' };
  }

  async getFriends(userId: string): Promise<User[]> {
    const friendships = await this.friendModel.find({
      $or: [{ requester: userId }, { recipient: userId }],
      status: FriendStatus.ACCEPTED,
    });

    const friendIds = friendships.map((f) =>
      f.requester.toString() === userId ? f.recipient : f.requester,
    );

    return this.userModel
      .find({ _id: { $in: friendIds } })
      .select('publicInfo musicPreferences');
  }

  async getPendingRequests(userId: string): Promise<Friend[]> {
    return this.friendModel
      .find({ recipient: userId, status: FriendStatus.PENDING })
      .populate('requester', 'publicInfo');
  }

  // ─── Helper: check if two users are friends ──────────

  async areFriends(userA: string, userB: string): Promise<boolean> {
    const friendship = await this.friendModel.findOne({
      $or: [
        { requester: userA, recipient: userB },
        { requester: userB, recipient: userA },
      ],
      status: FriendStatus.ACCEPTED,
    });
    return !!friendship;
  }
}
