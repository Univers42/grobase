import { Injectable } from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model } from 'mongoose';
import { RequestLog, RequestLogDocument } from './schemas';

@Injectable()
export class LoggingService {
  constructor(
    @InjectModel(RequestLog.name)
    private requestLogModel: Model<RequestLogDocument>,
  ) {}

  /** Get platform usage breakdown */
  async getPlatformStats(days = 30) {
    const since = new Date(Date.now() - days * 24 * 60 * 60 * 1000);
    return this.requestLogModel.aggregate([
      { $match: { createdAt: { $gte: since }, platform: { $exists: true, $ne: null } } },
      { $group: { _id: '$platform', count: { $sum: 1 } } },
      { $sort: { count: -1 } },
    ]);
  }

  /** Get error rate breakdown */
  async getErrorStats(days = 7) {
    const since = new Date(Date.now() - days * 24 * 60 * 60 * 1000);
    return this.requestLogModel.aggregate([
      { $match: { createdAt: { $gte: since } } },
      {
        $group: {
          _id: null,
          total: { $sum: 1 },
          errors: {
            $sum: { $cond: [{ $gte: ['$statusCode', 400] }, 1, 0] },
          },
        },
      },
      {
        $project: {
          _id: 0,
          total: 1,
          errors: 1,
          errorRate: { $divide: ['$errors', '$total'] },
        },
      },
    ]);
  }

  /** Get slowest endpoints */
  async getSlowestEndpoints(limit = 10) {
    return this.requestLogModel.aggregate([
      {
        $group: {
          _id: { method: '$method', url: '$url' },
          avgResponseTime: { $avg: '$responseTime' },
          maxResponseTime: { $max: '$responseTime' },
          count: { $sum: 1 },
        },
      },
      { $sort: { avgResponseTime: -1 } },
      { $limit: limit },
    ]);
  }

  /** Get recent logs (paginated) */
  async getRecentLogs(page = 1, limit = 50) {
    const skip = (page - 1) * limit;
    const [logs, total] = await Promise.all([
      this.requestLogModel
        .find()
        .sort({ createdAt: -1 })
        .skip(skip)
        .limit(limit)
        .lean()
        .exec(),
      this.requestLogModel.countDocuments(),
    ]);
    return { logs, total, page, limit };
  }
}
