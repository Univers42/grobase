/**
 * Generic CRUD Service
 */
import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma';

export interface FindOptions {
  page?: number;
  limit?: number;
  where?: Record<string, unknown>;
  orderBy?: Record<string, 'asc' | 'desc'>;
  include?: Record<string, boolean | object>;
}

export interface PaginatedResult<T> {
  data: T[];
  meta: {
    total: number;
    page: number;
    limit: number;
    totalPages: number;
  };
}

export type PrismaWhereUnique = Record<string, unknown>;

type PrismaModel = {
  findMany: (args: Record<string, unknown>) => Promise<unknown[]>;
  findUnique: (args: Record<string, unknown>) => Promise<unknown>;
  create: (args: Record<string, unknown>) => Promise<unknown>;
  update: (args: Record<string, unknown>) => Promise<unknown>;
  delete: (args: Record<string, unknown>) => Promise<unknown>;
  count: (args: Record<string, unknown>) => Promise<number>;
};

@Injectable()
export class CrudService {
  constructor(private readonly prisma: PrismaService) {}

  private getModel(model: string): PrismaModel {
    return (this.prisma as unknown as Record<string, PrismaModel>)[model];
  }

  async findAll<T>(
    model: string,
    options: FindOptions = {},
  ): Promise<PaginatedResult<T>> {
    const { page = 1, limit = 20, where = {}, orderBy = {}, include } = options;
    const skip = (page - 1) * limit;
    const prismaModel = this.getModel(model);

    const [data, total] = await Promise.all([
      prismaModel.findMany({
        where,
        orderBy,
        include,
        skip,
        take: limit,
      }),
      prismaModel.count({ where }),
    ]);

    return {
      data: data as T[],
      meta: {
        total,
        page,
        limit,
        totalPages: Math.ceil(total / limit),
      },
    };
  }

  async findOne<T>(
    model: string,
    where: PrismaWhereUnique,
    include?: Record<string, unknown>,
  ): Promise<T | null> {
    const prismaModel = this.getModel(model);
    return prismaModel.findUnique({
      where,
      include,
    }) as Promise<T | null>;
  }

  async create<T>(model: string, data: Record<string, unknown>): Promise<T> {
    const prismaModel = this.getModel(model);
    return prismaModel.create({ data }) as Promise<T>;
  }

  async update<T>(
    model: string,
    where: PrismaWhereUnique,
    data: Record<string, unknown>,
  ): Promise<T> {
    const prismaModel = this.getModel(model);
    return prismaModel.update({
      where,
      data,
    }) as Promise<T>;
  }

  async delete(model: string, where: PrismaWhereUnique): Promise<void> {
    const prismaModel = this.getModel(model);
    await prismaModel.delete({ where });
  }

  // Alias for delete
  async remove(model: string, where: PrismaWhereUnique): Promise<void> {
    return this.delete(model, where);
  }

  async exists(
    model: string,
    where: Record<string, unknown>,
  ): Promise<boolean> {
    const prismaModel = this.getModel(model);
    const count = await prismaModel.count({ where });
    return count > 0;
  }
}
