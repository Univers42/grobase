#!/usr/bin/env npx tsx
/**
 * CLI Script: Update menu images with real Unsplash photos
 * Usage: npm run seed:images
 *
 * This script updates existing MenuImage records with real Unsplash URLs
 * SQL seeds own the menu data - we only update images
 */
import { PrismaClient } from '../generated/prisma/client';
import { PrismaPg } from '@prisma/adapter-pg';
import { Pool } from 'pg';
import * as https from 'https';

// Load environment variables
import * as dotenv from 'dotenv';
dotenv.config();

const UNSPLASH_ACCESS_KEY = process.env.UNSPLASH_ACCESS_KEY || 'C8nO7p1Ycs39qE6H0bttbJ6LSxgQ9KGZLvM4zf8XiDI';
const DATABASE_URL = process.env.DATABASE_URL;

if (!DATABASE_URL) {
  console.error('❌ DATABASE_URL is not set in .env');
  process.exit(1);
}

// Create connection pool and Prisma adapter
const pool = new Pool({ connectionString: DATABASE_URL });
const adapter = new PrismaPg(pool);
const prisma = new PrismaClient({ adapter });

/** Maps menu titles to Unsplash search queries */
const MENU_IMAGE_QUERIES: Record<string, string> = {
  // Original 10 menus
  'Menu Prestige Mariage': 'wedding banquet elegant dinner',
  'Menu Végétarien Élégant': 'vegetarian gourmet platter',
  'Cocktail Entreprise': 'corporate cocktail canapés appetizers',
  'Brunch Dominical': 'sunday brunch breakfast spread',
  'Menu Gastronomique': 'fine dining gourmet french cuisine',
  'Barbecue Festif': 'bbq grilled meat outdoor party',
  'Menu Végan Découverte': 'vegan plant based colorful dishes',
  'Menu Noël Traditionnel': 'christmas dinner traditional french',
  'Menu Pâques': 'easter spring dinner lamb',
  'Menu Brouillon Test': 'food platter catering',
  // French Classics
  'Coq au Vin Bourguignon': 'coq au vin french chicken wine',
  'Boeuf Bourguignon Festif': 'beef bourguignon stew french',
  'Cassoulet Toulousain': 'cassoulet french beans duck sausage',
  'Blanquette de Veau': 'blanquette veal cream sauce french',
  'Bouillabaisse Marseillaise': 'bouillabaisse fish soup french',
  // Mediterranean
  'Paella Valenciana': 'paella spanish seafood rice',
  'Mezzé Libanais': 'mezze lebanese hummus falafel',
  'Tajine d\'Agneau': 'tagine lamb moroccan apricot',
  'Moussaka Grecque': 'moussaka greek eggplant',
  'Antipasti Italien': 'antipasti italian charcuterie cheese',
  // Asian Fusion
  'Sushi & Sashimi Premium': 'sushi sashimi japanese platter',
  'Dim Sum Cantonais': 'dim sum dumplings chinese',
  'Pad Thai Royal': 'pad thai noodles shrimp',
  'Bibimbap Coréen': 'bibimbap korean rice bowl',
  'Curry Indien Végétarien': 'indian curry vegetarian',
  // Special Occasions
  'Menu Baptême Classique': 'baptism celebration dinner elegant',
  'Menu Anniversaire 50 ans': 'birthday party celebration cake',
  'Menu Saint-Valentin': 'valentines day romantic dinner',
  'Menu Nouvel An': 'new years eve champagne celebration',
  'Menu Communion': 'communion celebration traditional',
  // Healthy & Diet Options
  'Menu Sans Gluten Gourmet': 'gluten free gourmet food',
  'Menu Halal Prestige': 'halal meat elegant dinner',
  'Menu Casher Traditionnel': 'kosher traditional jewish food',
  'Buddha Bowl Party': 'buddha bowl healthy colorful',
  'Brunch Végan Festif': 'vegan brunch avocado toast',
};

interface UnsplashPhoto {
  urls: { regular: string; small: string };
  alt_description: string | null;
  user: { name: string };
}

async function fetchUnsplashPhoto(query: string): Promise<UnsplashPhoto | null> {
  return new Promise((resolve) => {
    const encodedQuery = encodeURIComponent(query);
    const url = `https://api.unsplash.com/photos/random?query=${encodedQuery}&orientation=landscape&client_id=${UNSPLASH_ACCESS_KEY}`;

    https.get(url, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        try {
          if (res.statusCode !== 200) {
            console.error(`  ⚠️  Unsplash API error: ${res.statusCode}`);
            resolve(null);
            return;
          }
          resolve(JSON.parse(data));
        } catch {
          resolve(null);
        }
      });
    }).on('error', () => resolve(null));
  });
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  console.log('📸 Updating menu images with Unsplash photos...\n');

  const menus = await prisma.menu.findMany({
    select: { id: true, title: true },
  });

  console.log(`Found ${menus.length} menus to update\n`);

  let updated = 0;
  let errors = 0;

  for (const menu of menus) {
    const query = MENU_IMAGE_QUERIES[menu.title] || `${menu.title} food`;
    console.log(`  Processing: ${menu.title}`);
    console.log(`    Query: "${query}"`);

    const photo = await fetchUnsplashPhoto(query);

    if (photo) {
      const existing = await prisma.menuImage.findFirst({
        where: { menu_id: menu.id, is_primary: true },
      });

      const imageData = {
        image_url: photo.urls.regular,
        alt_text: photo.alt_description || menu.title,
      };

      if (existing) {
        await prisma.menuImage.update({
          where: { id: existing.id },
          data: imageData,
        });
        console.log(`    ✅ Updated existing image`);
      } else {
        await prisma.menuImage.create({
          data: {
            menu_id: menu.id,
            ...imageData,
            display_order: 0,
            is_primary: true,
          },
        });
        console.log(`    ✅ Created new image`);
      }

      console.log(`    Photo by: ${photo.user.name}`);
      console.log(`    URL: ${photo.urls.small.substring(0, 60)}...`);
      updated++;
    } else {
      console.log(`    ❌ No photo found`);
      errors++;
    }

    // Rate limit: Unsplash allows 50 req/hour for demo apps
    await delay(300);
    console.log('');
  }

  console.log('\n📊 Summary:');
  console.log(`   Updated: ${updated} images`);
  console.log(`   Errors: ${errors}`);

  await prisma.$disconnect();
  await pool.end();
}

main().catch(async (e) => {
  console.error('Error:', e);
  await prisma.$disconnect();
  await pool.end();
  process.exit(1);
});
