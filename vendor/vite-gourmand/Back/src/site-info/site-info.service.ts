/**
 * Site Info Service
 * Aggregates public-facing information from the database:
 *   – Company details (name, slogan, contact, established date)
 *   – Owners from CompanyOwner junction table
 *   – Event count from Event table
 *   – Dynamic years of experience calculation
 */
import { Injectable, Logger } from '@nestjs/common';
import { PrismaService } from '../prisma';

interface CompanyInfo {
  id: number;
  name: string;
  slogan: string | null;
  description: string | null;
  first_opening_date: Date;
  address: string;
  city: string;
  postal_code: string;
  country: string;
  phone: string;
  email: string;
  website: string | null;
}

interface OwnerInfo {
  first_name: string;
  last_name: string | null;
  role: string;
  is_primary: boolean;
}

@Injectable()
export class SiteInfoService {
  private readonly logger = new Logger(SiteInfoService.name);

  constructor(private readonly prisma: PrismaService) {}

  async getPublicInfo() {
    try {
      // Try to get data from new Company/Event tables
      const companyData = await this.getCompanyData();
      if (companyData) {
        return companyData;
      }
    } catch {
      this.logger.warn(
        'Company tables not available, falling back to legacy method',
      );
    }

    // Fallback to legacy method (admin users, env vars)
    return this.getLegacyInfo();
  }

  /**
   * Get data from new Company, CompanyOwner, and Event tables
   */
  private async getCompanyData() {
    // Get the primary/active company
    const company = await this.prisma.$queryRaw<CompanyInfo[]>`
      SELECT id, name, slogan, description, first_opening_date,
             address, city, postal_code, country, phone, email, website
      FROM "Company"
      WHERE is_active = true
      ORDER BY id ASC
      LIMIT 1
    `;

    if (!company || company.length === 0) {
      return null;
    }

    const mainCompany = company[0];
    const companyId = mainCompany.id;

    // Get owners from junction table
    const owners = await this.prisma.$queryRaw<OwnerInfo[]>`
      SELECT u.first_name, u.last_name, co.role, co.is_primary
      FROM "CompanyOwner" co
      JOIN "User" u ON co.user_id = u.id
      WHERE co.company_id = ${companyId}
        AND u.is_active = true
        AND u.is_deleted = false
      ORDER BY co.is_primary DESC, co.joined_at ASC
    `;

    // Get event count
    const eventCountResult = await this.prisma.$queryRaw<{ count: bigint }[]>`
      SELECT COUNT(*) as count
      FROM "Event"
      WHERE company_id = ${companyId}
    `;
    const eventCount = Number(eventCountResult[0]?.count || 0);

    // Calculate years of experience from first_opening_date
    const firstOpeningDate = new Date(mainCompany.first_opening_date);
    const establishedYear = firstOpeningDate.getFullYear();
    const yearsOfExperience = new Date().getFullYear() - establishedYear;

    return {
      company: {
        name: mainCompany.name,
        slogan: mainCompany.slogan,
        description: mainCompany.description,
      },
      owners: owners.map((o: OwnerInfo) => ({
        firstName: o.first_name,
        lastName: o.last_name,
        role: o.role,
        isPrimary: o.is_primary,
      })),
      yearsOfExperience,
      establishedYear,
      eventCount,
      phone: mainCompany.phone,
      email: mainCompany.email,
      address: `${mainCompany.address}, ${mainCompany.postal_code} ${mainCompany.city}`,
      city: mainCompany.city,
      website: mainCompany.website,
    };
  }

  /**
   * Legacy fallback: get data from admin users and env vars
   */
  private async getLegacyInfo() {
    const [eventCount, owners] = await Promise.all([
      // Count delivered / confirmed orders as "events"
      this.prisma.order.count({
        where: { status: { in: ['delivered', 'confirmed', 'completed'] } },
      }),
      // Fetch admin users as owners
      this.prisma.user.findMany({
        where: {
          Role: { name: 'admin' },
          is_active: true,
          is_deleted: false,
        },
        select: { first_name: true, last_name: true },
        orderBy: { created_at: 'asc' },
      }),
    ]);

    // Default established year
    const establishedYear = 2001;
    const yearsOfExperience = new Date().getFullYear() - establishedYear;

    return {
      company: {
        name: 'Vite & Gourmand',
        slogan: "Traiteur d'exception pour tous vos événements",
        description: null,
      },
      owners: owners.map(
        (o: { first_name: string; last_name: string | null }) => ({
          firstName: o.first_name,
          lastName: o.last_name,
          role: 'owner',
          isPrimary: false,
        }),
      ),
      yearsOfExperience,
      establishedYear,
      eventCount,
      phone: '05 56 00 00 00',
      email: 'contact@vite-gourmand.fr',
      address: '15 Rue Sainte-Catherine, 33000 Bordeaux',
      city: 'Bordeaux',
      website: null,
    };
  }
}
