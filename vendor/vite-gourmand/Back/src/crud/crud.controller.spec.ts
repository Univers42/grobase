/**
 * CRUD Controller policy tests
 */
import { BadRequestException, ForbiddenException } from '@nestjs/common';
import { CrudController } from './crud.controller';
import { CrudService } from './crud.service';
import { PrismaService } from '../prisma';
import type { JwtPayload } from '../common/types/request.types';

const user: JwtPayload = { sub: 123, email: 'admin@test.local', role: 'admin' };

function createController() {
  const crudService = {
    findAll: jest.fn(),
    findOne: jest.fn(),
    create: jest.fn(),
    update: jest.fn(),
    remove: jest.fn(),
  };
  const prisma = {
    menu: {
      findMany: jest.fn().mockResolvedValue([]),
      findUnique: jest.fn(),
      update: jest.fn(),
      count: jest.fn().mockResolvedValue(0),
    },
    dish: {
      findUnique: jest.fn(),
      count: jest.fn().mockResolvedValue(0),
    },
  };

  return {
    controller: new CrudController(
      crudService as unknown as CrudService,
      prisma as unknown as PrismaService,
    ),
    crudService,
    prisma,
  };
}

describe('CrudController policies', () => {
  it('exposes the menu management tables required by DevBoard', () => {
    const { controller } = createController();
    const schema = controller.getSchema();
    const names = schema.map((model) => model.name);

    expect(names).toEqual(
      expect.arrayContaining([
        'Menu',
        'MenuImage',
        'MenuDish',
        'Dish',
        'Ingredient',
        'MenuIngredient',
        'DishIngredient',
        'DishAllergen',
      ]),
    );
    expect(schema.find((model) => model.name === 'User')?.canCreate).toBe(false);
    expect(schema.find((model) => model.name === 'User')?.columns.some((c) => c.name === 'password')).toBe(false);
    expect(schema.find((model) => model.name === 'MenuDish')?.primaryKey).toEqual([
      'menu_id',
      'dish_id',
    ]);
  });

  it('sanitizes readonly user records before returning them', async () => {
    const { controller, crudService } = createController();
    crudService.findAll.mockResolvedValue({
      data: [
        {
          id: 1,
          email: 'admin@test.local',
          password: 'hashed-secret',
          first_name: 'Admin',
          private_internal: true,
        },
      ],
      meta: { total: 1, page: 1, limit: 20, totalPages: 1 },
    });

    const result = await controller.getRecords('users');

    expect(crudService.findAll).toHaveBeenCalledWith(
      'user',
      expect.objectContaining({ orderBy: { id: 'asc' } }),
    );
    expect(result.data[0]).toEqual({ id: 1, email: 'admin@test.local', first_name: 'Admin' });
  });

  it('blocks writes to sensitive readonly tables', async () => {
    const { controller } = createController();

    await expect(controller.createRecord('users', { email: 'new@test.local' }, user)).rejects.toBeInstanceOf(
      ForbiddenException,
    );
  });

  it('rejects non-HTTPS media URLs for catalog records', async () => {
    const { controller, crudService } = createController();

    await expect(
      controller.createRecord(
        'menu-images',
        { menu_id: 1, image_url: 'http://example.com/menu.jpg' },
        user,
      ),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(crudService.create).not.toHaveBeenCalled();
  });

  it('creates menus with a server-side creator and an allowlisted payload', async () => {
    const { controller, crudService } = createController();
    crudService.create.mockResolvedValue({ id: 10, title: 'Menu test', created_by: 123, internal: true });

    const result = await controller.createRecord(
      'menus',
      {
        id: 999,
        title: 'Menu test',
        person_min: 4,
        price_per_person: '25.50',
        unexpected: 'ignored',
      },
      user,
    );

    expect(crudService.create).toHaveBeenCalledWith('menu', {
      title: 'Menu test',
      person_min: 4,
      price_per_person: '25.50',
      created_by: 123,
    });
    expect(result).toEqual({ id: 10, title: 'Menu test', created_by: 123 });
  });

  it('connects dishes to menus through the MenuDish virtual table', async () => {
    const { controller, prisma } = createController();
    prisma.menu.findUnique.mockResolvedValue({ id: 1, title: 'Cocktail dinatoire' });
    prisma.dish.findUnique.mockResolvedValue({ id: 2, title: 'Mini quiche' });
    prisma.menu.update.mockResolvedValue({});

    const result = await controller.createRecord('menu-dishes', { menu_id: 1, dish_id: 2 }, user);

    expect(prisma.menu.update).toHaveBeenCalledWith({
      where: { id: 1 },
      data: { Dish: { connect: { id: 2 } } },
    });
    expect(result).toEqual({
      menu_id: 1,
      dish_id: 2,
      menu_title: 'Cocktail dinatoire',
      dish_title: 'Mini quiche',
    });
  });
});
