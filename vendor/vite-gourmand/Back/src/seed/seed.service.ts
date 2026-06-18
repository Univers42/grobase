/**
 * Seed Service - Updates MenuImage with real Unsplash photos
 * SQL seeds own the schema and menu data - we only update images
 */
import { Injectable, Logger } from '@nestjs/common';
import { PrismaService } from '../prisma';
import { UnsplashService, UnsplashPhoto } from '../unsplash';

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
  "Tajine d'Agneau": 'tagine lamb moroccan apricot',
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

@Injectable()
export class SeedService {
  private readonly logger = new Logger(SeedService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly unsplash: UnsplashService,
  ) {}

  /**
   * Update existing menu images with real Unsplash URLs
   * Does NOT create new menus - SQL seeds own the data
   */
  async updateMenuImages(): Promise<{ updated: number; errors: number }> {
    let updated = 0;
    let errors = 0;

    const menus = await this.prisma.menu.findMany({
      select: { id: true, title: true },
    });

    this.logger.log(`Found ${menus.length} menus to update images for`);

    for (const menu of menus) {
      try {
        const query = MENU_IMAGE_QUERIES[menu.title] || `${menu.title} food`;
        const photo = await this.fetchPhotoSafe(query);

        if (photo) {
          await this.updateOrCreateMenuImage(menu.id, menu.title, photo);
          updated++;
          this.logger.log(`Updated image for: ${menu.title}`);
        } else {
          errors++;
          this.logger.warn(`No photo found for: ${menu.title}`);
        }

        // Rate limit: Unsplash allows 50 req/hour for demo apps
        await this.delay(200);
      } catch (error) {
        errors++;
        this.logger.error(`Failed to update: ${menu.title}`, String(error));
      }
    }

    return { updated, errors };
  }

  /**
   * Update existing MenuImage or create if none exists
   */
  private async updateOrCreateMenuImage(
    menuId: number,
    title: string,
    photo: UnsplashPhoto,
  ) {
    const existing = await this.prisma.menuImage.findFirst({
      where: { menu_id: menuId, is_primary: true },
    });

    const imageData = {
      image_url: photo.urls.regular,
      alt_text: photo.alt_description || title,
    };

    if (existing) {
      await this.prisma.menuImage.update({
        where: { id: existing.id },
        data: imageData,
      });
    } else {
      await this.prisma.menuImage.create({
        data: {
          menu_id: menuId,
          ...imageData,
          display_order: 0,
          is_primary: true,
        },
      });
    }
  }

  private async fetchPhotoSafe(query: string): Promise<UnsplashPhoto | null> {
    try {
      return await this.unsplash.getRandomPhoto(query);
    } catch {
      this.logger.warn(`Failed to fetch Unsplash photo for: ${query}`);
      return null;
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
