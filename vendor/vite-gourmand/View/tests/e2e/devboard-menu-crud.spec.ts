import { expect, request as playwrightRequest, test } from '@playwright/test';
import type { APIRequestContext } from '@playwright/test';

const apiURL = process.env.PLAYWRIGHT_API_URL ?? 'http://localhost:3000';
const employeeEmail = process.env.PLAYWRIGHT_EMPLOYEE_EMAIL ?? 'manager@vitegourmand.fr';
const employeePassword = process.env.PLAYWRIGHT_EMPLOYEE_PASSWORD ?? 'Manager123!';
const clientEmail = process.env.PLAYWRIGHT_CLIENT_EMAIL ?? 'alice.dupont@email.fr';
const clientPassword = process.env.PLAYWRIGHT_CLIENT_PASSWORD ?? 'Client123!';

const crudEndpoints = [
  'users',
  'roles',
  'orders',
  'menus',
  'menu-images',
  'menu-dishes',
  'dishes',
  'ingredients',
  'menu-ingredients',
  'dish-ingredients',
  'dish-allergens',
  'diets',
  'themes',
  'allergens',
  'working-hours',
];

const requiredTables = [
  'User',
  'Role',
  'Order',
  'Menu',
  'MenuImage',
  'MenuDish',
  'Dish',
  'Ingredient',
  'MenuIngredient',
  'DishIngredient',
  'DishAllergen',
  'Diet',
  'Theme',
  'Allergen',
  'WorkingHours',
];

async function login(context: APIRequestContext, email: string, password: string) {
  const response = await context.post('/api/auth/login', {
    data: { email, password },
  });
  expect(response.ok()).toBeTruthy();
}

async function csrfToken(context: APIRequestContext): Promise<string> {
  const state = await context.storageState();
  const csrf = state.cookies.find((cookie) => cookie.name === 'vg_csrf_token');
  if (!csrf?.value) {
    throw new Error('Missing CSRF token cookie');
  }
  return csrf.value;
}

async function postCrud<T>(context: APIRequestContext, endpoint: string, data: unknown): Promise<T> {
  const response = await context.post(`/api/crud/${endpoint}`, {
    data,
    headers: { 'X-CSRF-Token': await csrfToken(context) },
  });
  expect(response.ok()).toBeTruthy();
  const body = await response.json();
  return body.data as T;
}

async function deleteCrud(context: APIRequestContext, endpoint: string, key: string | number) {
  const response = await context.delete(`/api/crud/${endpoint}/${key}`, {
    headers: { 'X-CSRF-Token': await csrfToken(context) },
  });
  expect(response.ok()).toBeTruthy();
}

test.describe('DevBoard menu CRUD API', () => {
  test('employee can create a menu with a dish and photo, while clients cannot access CRUD', async () => {
    const employee = await playwrightRequest.newContext({ baseURL: apiURL });
    const client = await playwrightRequest.newContext({ baseURL: apiURL });
    const runId = `pw-${Date.now()}`;
    let menuId: number | null = null;
    let dishId: number | null = null;
    let imageId: number | null = null;

    try {
      await login(employee, employeeEmail, employeePassword);

      const schemaResponse = await employee.get('/api/crud/schema');
      expect(schemaResponse.ok()).toBeTruthy();
      const schemaBody = await schemaResponse.json();
      const schemaNames = schemaBody.data.map((model: { name: string }) => model.name);
      expect(schemaNames).toEqual(expect.arrayContaining(requiredTables));

      for (const endpoint of crudEndpoints) {
        const response = await employee.get(`/api/crud/${endpoint}?limit=5`);
        expect(response.ok(), endpoint).toBeTruthy();
        const body = await response.json();
        expect(Array.isArray(body.data.data), endpoint).toBeTruthy();
      }

      const csrfBlocked = await employee.post('/api/crud/menus', {
        data: { title: 'CSRF blocked', person_min: 1, price_per_person: 1 },
      });
      expect(csrfBlocked.status()).toBe(403);

      const dish = await postCrud<{ id: number }>(employee, 'dishes', {
        title: `Playwright Dish ${runId}`,
        description: 'Dish created by Playwright API verification',
        photo_url: 'https://images.unsplash.com/photo-1546069901-ba9599a7e63c',
        course_type: 'plat',
      });
      dishId = dish.id;

      const menu = await postCrud<{ id: number }>(employee, 'menus', {
        title: `Playwright Menu ${runId}`,
        description: 'Menu created by Playwright API verification',
        conditions: 'Minimum 4 personnes',
        person_min: 4,
        price_per_person: 39.9,
        remaining_qty: 12,
        status: 'published',
      });
      menuId = menu.id;

      const image = await postCrud<{ id: number }>(employee, 'menu-images', {
        menu_id: menuId,
        image_url: 'https://images.unsplash.com/photo-1555244162-803834f70033',
        alt_text: `Menu Playwright ${runId}`,
        display_order: 0,
        is_primary: true,
      });
      imageId = image.id;

      const link = await postCrud<{ menu_id: number; dish_id: number }>(employee, 'menu-dishes', {
        menu_id: menuId,
        dish_id: dishId,
      });
      expect(link).toMatchObject({ menu_id: menuId, dish_id: dishId });

      const publicMenu = await employee.get(`/api/menus/${menuId}`);
      expect(publicMenu.ok()).toBeTruthy();
      const publicMenuBody = await publicMenu.json();
      expect(publicMenuBody.data.title).toBe(`Playwright Menu ${runId}`);
      expect(publicMenuBody.data.MenuImage.length).toBeGreaterThanOrEqual(1);
      expect(publicMenuBody.data.Dish.length).toBeGreaterThanOrEqual(1);

      await login(client, clientEmail, clientPassword);
      const clientCrud = await client.get('/api/crud/schema');
      expect(clientCrud.status()).toBe(403);
    } finally {
      if (menuId && dishId) {
        const key = encodeURIComponent(JSON.stringify({ menu_id: menuId, dish_id: dishId }));
        await deleteCrud(employee, 'menu-dishes', key).catch(() => undefined);
      }
      if (imageId) await deleteCrud(employee, 'menu-images', imageId).catch(() => undefined);
      if (menuId) await deleteCrud(employee, 'menus', menuId).catch(() => undefined);
      if (dishId) await deleteCrud(employee, 'dishes', dishId).catch(() => undefined);
      await employee.dispose();
      await client.dispose();
    }
  });
});
