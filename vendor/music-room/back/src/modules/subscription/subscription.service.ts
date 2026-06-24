import {
  Injectable,
  NotFoundException,
  ConflictException,
  Logger,
} from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model, Types } from 'mongoose';
import {
  Subscription,
  SubscriptionDocument,
  SubscriptionPlan,
  SubscriptionStatus,
  PLAN_FEATURES,
} from './schemas';
import { UpgradePlanDto, CancelSubscriptionDto } from './dto';

@Injectable()
export class SubscriptionService {
  private readonly logger = new Logger(SubscriptionService.name);

  constructor(
    @InjectModel(Subscription.name)
    private subscriptionModel: Model<SubscriptionDocument>,
  ) {}

  /**
   * Get or create subscription for a user.
   * Every user gets a FREE plan by default.
   */
  async getSubscription(userId: string): Promise<SubscriptionDocument> {
    let sub = await this.subscriptionModel
      .findOne({ user: new Types.ObjectId(userId) })
      .exec();

    if (!sub) {
      sub = await this.subscriptionModel.create({
        user: new Types.ObjectId(userId),
        plan: SubscriptionPlan.FREE,
        status: SubscriptionStatus.ACTIVE,
        features: PLAN_FEATURES[SubscriptionPlan.FREE],
      });
    }

    return sub;
  }

  /**
   * Upgrade (or downgrade) a user's plan.
   * In production this would integrate with Stripe / payment provider.
   */
  async upgradePlan(
    userId: string,
    dto: UpgradePlanDto,
  ): Promise<SubscriptionDocument> {
    const sub = await this.getSubscription(userId);

    if (sub.plan === dto.plan) {
      throw new ConflictException(`Already on the ${dto.plan} plan`);
    }

    // In production: verify paymentToken with Stripe, create subscription
    // For now, simulate immediate upgrade
    const now = new Date();
    const periodEnd = new Date(now);
    periodEnd.setMonth(periodEnd.getMonth() + 1);

    sub.plan = dto.plan;
    sub.status = SubscriptionStatus.ACTIVE;
    sub.features = PLAN_FEATURES[dto.plan];
    sub.currentPeriodStart = now;
    sub.currentPeriodEnd = periodEnd;
    sub.cancelledAt = undefined;

    this.logger.log(`User ${userId} upgraded to ${dto.plan}`);
    return sub.save();
  }

  /**
   * Cancel a subscription — reverts to FREE at period end.
   */
  async cancelSubscription(
    userId: string,
    dto: CancelSubscriptionDto,
  ): Promise<SubscriptionDocument> {
    const sub = await this.getSubscription(userId);

    if (sub.plan === SubscriptionPlan.FREE) {
      throw new ConflictException('Cannot cancel a free plan');
    }

    if (sub.status === SubscriptionStatus.CANCELLED) {
      throw new ConflictException('Subscription already cancelled');
    }

    if (dto.cancelAtPeriodEnd) {
      // Mark as cancelled but keep active until period end
      sub.status = SubscriptionStatus.CANCELLED;
      sub.cancelledAt = new Date();
    } else {
      // Immediate cancellation — revert to free
      sub.plan = SubscriptionPlan.FREE;
      sub.status = SubscriptionStatus.ACTIVE;
      sub.features = PLAN_FEATURES[SubscriptionPlan.FREE];
      sub.cancelledAt = new Date();
      sub.currentPeriodEnd = undefined;
    }

    this.logger.log(`User ${userId} cancelled subscription`);
    return sub.save();
  }

  /**
   * Handle webhook from payment provider
   */
  async handleWebhook(type: string, externalId: string, data?: Record<string, any>): Promise<void> {
    const sub = await this.subscriptionModel
      .findOne({ externalId })
      .exec();

    if (!sub) {
      this.logger.warn(`Webhook: subscription ${externalId} not found`);
      return;
    }

    switch (type) {
      case 'payment_succeeded':
        sub.status = SubscriptionStatus.ACTIVE;
        if (data?.periodEnd) {
          sub.currentPeriodEnd = new Date(data.periodEnd);
        }
        await sub.save();
        break;

      case 'payment_failed':
        sub.status = SubscriptionStatus.PAST_DUE;
        await sub.save();
        break;

      case 'subscription_expired':
        sub.plan = SubscriptionPlan.FREE;
        sub.status = SubscriptionStatus.EXPIRED;
        sub.features = PLAN_FEATURES[SubscriptionPlan.FREE];
        await sub.save();
        break;

      default:
        this.logger.warn(`Unhandled webhook type: ${type}`);
    }
  }

  /**
   * Check if a user's plan allows an action based on features.
   */
  async checkFeature(userId: string, feature: keyof Subscription['features']): Promise<boolean> {
    const sub = await this.getSubscription(userId);
    const value = sub.features[feature];
    if (typeof value === 'boolean') return value;
    if (typeof value === 'number') return value === -1 || value > 0;
    return false;
  }

  /**
   * Get remaining quota for numeric features.
   * Returns -1 for unlimited.
   */
  async getFeatureLimit(userId: string, feature: keyof Subscription['features']): Promise<number> {
    const sub = await this.getSubscription(userId);
    const value = sub.features[feature];
    if (typeof value === 'number') return value;
    return 0;
  }
}
