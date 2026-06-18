import {
  Injectable,
  NotFoundException,
  ForbiddenException,
  ConflictException,
} from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model, Types } from 'mongoose';
import { Device, DeviceDocument } from './schemas/device.schema';
import {
  Delegation,
  DelegationDocument,
  DelegationStatus,
  DelegationPermission,
} from './schemas/delegation.schema';
import {
  RegisterDeviceDto,
  UpdateDeviceDto,
  CreateDelegationDto,
  UpdateDelegationPermissionsDto,
} from './dto';

@Injectable()
export class DelegationService {
  constructor(
    @InjectModel(Device.name) private deviceModel: Model<DeviceDocument>,
    @InjectModel(Delegation.name) private delegationModel: Model<DelegationDocument>,
  ) {}

  // ─── Device management ───

  async registerDevice(userId: string, dto: RegisterDeviceDto): Promise<DeviceDocument> {
    const device = new this.deviceModel({
      owner: new Types.ObjectId(userId),
      ...dto,
      lastSeenAt: new Date(),
    });
    return device.save();
  }

  async getMyDevices(userId: string): Promise<DeviceDocument[]> {
    return this.deviceModel
      .find({ owner: new Types.ObjectId(userId), isActive: true })
      .sort({ lastSeenAt: -1 })
      .exec();
  }

  async updateDevice(
    deviceId: string,
    userId: string,
    dto: UpdateDeviceDto,
  ): Promise<DeviceDocument> {
    const device = await this.deviceModel.findById(deviceId).exec();
    if (!device) throw new NotFoundException('Device not found');
    if (device.owner.toString() !== userId) {
      throw new ForbiddenException('Not your device');
    }
    Object.assign(device, dto, { lastSeenAt: new Date() });
    return device.save();
  }

  async removeDevice(deviceId: string, userId: string): Promise<void> {
    const device = await this.deviceModel.findById(deviceId).exec();
    if (!device) throw new NotFoundException('Device not found');
    if (device.owner.toString() !== userId) {
      throw new ForbiddenException('Not your device');
    }
    device.isActive = false;
    await device.save();

    // Revoke all delegations tied to this device
    await this.delegationModel.updateMany(
      { targetDevice: new Types.ObjectId(deviceId), status: DelegationStatus.ACTIVE },
      { $set: { status: DelegationStatus.REVOKED, revokedAt: new Date() } },
    );
  }

  async heartbeat(deviceId: string, userId: string): Promise<void> {
    await this.deviceModel.updateOne(
      { _id: new Types.ObjectId(deviceId), owner: new Types.ObjectId(userId) },
      { $set: { lastSeenAt: new Date() } },
    );
  }

  // ─── Delegation management ───

  async createDelegation(
    granterId: string,
    dto: CreateDelegationDto,
  ): Promise<DelegationDocument> {
    if (granterId === dto.delegate) {
      throw new ConflictException('Cannot delegate to yourself');
    }

    // If a target device is specified, verify the granter owns it
    if (dto.targetDevice) {
      const device = await this.deviceModel.findById(dto.targetDevice).exec();
      if (!device || device.owner.toString() !== granterId) {
        throw new ForbiddenException('Target device not found or not yours');
      }
    }

    // Check for existing active delegation
    const existing = await this.delegationModel.findOne({
      granter: new Types.ObjectId(granterId),
      delegate: new Types.ObjectId(dto.delegate),
      status: { $in: [DelegationStatus.PENDING, DelegationStatus.ACTIVE] },
    });
    if (existing) {
      throw new ConflictException('Active delegation already exists for this user');
    }

    const delegation = new this.delegationModel({
      granter: new Types.ObjectId(granterId),
      delegate: new Types.ObjectId(dto.delegate),
      targetDevice: dto.targetDevice ? new Types.ObjectId(dto.targetDevice) : undefined,
      permissions: dto.permissions,
      expiresAt: dto.expiresAt ? new Date(dto.expiresAt) : undefined,
    });
    return delegation.save();
  }

  async acceptDelegation(delegationId: string, userId: string): Promise<DelegationDocument> {
    const delegation = await this.delegationModel.findById(delegationId).exec();
    if (!delegation) throw new NotFoundException('Delegation not found');
    if (delegation.delegate.toString() !== userId) {
      throw new ForbiddenException('Not the delegate');
    }
    if (delegation.status !== DelegationStatus.PENDING) {
      throw new ConflictException(`Delegation is ${delegation.status}`);
    }
    delegation.status = DelegationStatus.ACTIVE;
    return delegation.save();
  }

  async revokeDelegation(delegationId: string, userId: string): Promise<DelegationDocument> {
    const delegation = await this.delegationModel.findById(delegationId).exec();
    if (!delegation) throw new NotFoundException('Delegation not found');

    // Either granter or delegate can revoke
    const isGranter = delegation.granter.toString() === userId;
    const isDelegate = delegation.delegate.toString() === userId;
    if (!isGranter && !isDelegate) {
      throw new ForbiddenException('Not involved in this delegation');
    }

    delegation.status = DelegationStatus.REVOKED;
    delegation.revokedAt = new Date();
    return delegation.save();
  }

  async updatePermissions(
    delegationId: string,
    userId: string,
    dto: UpdateDelegationPermissionsDto,
  ): Promise<DelegationDocument> {
    const delegation = await this.delegationModel.findById(delegationId).exec();
    if (!delegation) throw new NotFoundException('Delegation not found');
    if (delegation.granter.toString() !== userId) {
      throw new ForbiddenException('Only the granter can update permissions');
    }
    if (delegation.status === DelegationStatus.REVOKED || delegation.status === DelegationStatus.EXPIRED) {
      throw new ConflictException(`Cannot update a ${delegation.status} delegation`);
    }
    delegation.permissions = dto.permissions;
    return delegation.save();
  }

  async getGrantedDelegations(userId: string): Promise<DelegationDocument[]> {
    return this.delegationModel
      .find({ granter: new Types.ObjectId(userId) })
      .populate('delegate', 'email publicInfo')
      .populate('targetDevice', 'name platform')
      .sort({ createdAt: -1 })
      .exec();
  }

  async getReceivedDelegations(userId: string): Promise<DelegationDocument[]> {
    return this.delegationModel
      .find({ delegate: new Types.ObjectId(userId) })
      .populate('granter', 'email publicInfo')
      .populate('targetDevice', 'name platform')
      .sort({ createdAt: -1 })
      .exec();
  }

  /**
   * Check if a user has a specific delegation permission from another user.
   * Used by other services/guards to verify delegated access.
   */
  async hasPermission(
    delegateId: string,
    granterId: string,
    permission: DelegationPermission,
  ): Promise<boolean> {
    const now = new Date();
    const delegation = await this.delegationModel.findOne({
      granter: new Types.ObjectId(granterId),
      delegate: new Types.ObjectId(delegateId),
      status: DelegationStatus.ACTIVE,
      permissions: permission,
      $or: [
        { expiresAt: { $exists: false } },
        { expiresAt: null },
        { expiresAt: { $gt: now } },
      ],
    });
    return !!delegation;
  }
}
