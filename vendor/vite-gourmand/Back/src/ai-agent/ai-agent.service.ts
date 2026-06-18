/**
 * AI Agent Service
 *
 * Provides an AI-powered assistant that helps visitors build customized menus
 * for their events based on budget, dietary needs, guest count, and preferences.
 *
 * Uses Groq (LLaMA) to:
 *  1. Chat with visitors about their event requirements
 *  2. Query existing dishes/menus from the database
 *  3. Generate a tailored menu proposal in the company's format
 */
import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PrismaService } from '../prisma';
import OpenAI from 'openai';
import { ChatMessageDto } from './dto/ai-agent.dto';
import {
  Prisma,
  Allergen,
  Diet,
  Theme,
} from '../../generated/prisma/client.js';

type DishWithRelations = Prisma.DishGetPayload<{
  include: {
    DishAllergen: { include: { Allergen: true } };
    DishIngredient: { include: { Ingredient: true } };
  };
}>;

type MenuWithRelations = Prisma.MenuGetPayload<{
  include: {
    Diet: true;
    Theme: true;
    Dish: true;
    MenuIngredient: { include: { Ingredient: true } };
  };
}>;

interface ConversationEntry {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

interface ConversationState {
  messages: ConversationEntry[];
  context: {
    guestCount?: number;
    budgetPerPerson?: number;
    dietId?: number;
    themeId?: number;
    excludeAllergens?: number[];
    agreedDishes?: number[];
    agreedMenuId?: number;
  };
  createdAt: Date;
}

@Injectable()
export class AiAgentService implements OnModuleInit {
  private readonly logger = new Logger(AiAgentService.name);
  private openai: OpenAI | null = null;
  private readonly conversations = new Map<string, ConversationState>();

  // Cleanup stale conversations every 30 min
  private cleanupInterval!: ReturnType<typeof setInterval>;

  constructor(
    private readonly prisma: PrismaService,
    private readonly config: ConfigService,
  ) {}

  onModuleInit(): void {
    const apiKey = this.config.get<string>('GROQ_API_KEY');
    if (apiKey) {
      this.openai = new OpenAI({
        apiKey,
        baseURL: 'https://api.groq.com/openai/v1',
      });
      this.logger.log('Groq client initialized — AI agent ready (LLaMA)');
    } else {
      this.logger.warn('GROQ_API_KEY not set — AI agent will run in demo mode');
    }

    // Cleanup stale conversations (older than 2h)
    this.cleanupInterval = setInterval(
      () => {
        const cutoff = Date.now() - 2 * 60 * 60 * 1000;
        for (const [id, conv] of this.conversations) {
          if (conv.createdAt.getTime() < cutoff) this.conversations.delete(id);
        }
      },
      30 * 60 * 1000,
    );
  }

  /* ═══════════════════════════════════════════════════════════
     Database context gathering
     ═══════════════════════════════════════════════════════════ */

  private async gatherDatabaseContext(): Promise<string> {
    const [dishes, menus, diets, themes, allergens] = await Promise.all([
      this.prisma.dish.findMany({
        include: {
          DishAllergen: { include: { Allergen: true } },
          DishIngredient: { include: { Ingredient: true } },
        },
      }),
      this.prisma.menu.findMany({
        where: { status: 'published' },
        include: {
          Diet: true,
          Theme: true,
          Dish: true,
          MenuIngredient: { include: { Ingredient: true } },
        },
      }),
      this.prisma.diet.findMany(),
      this.prisma.theme.findMany(),
      this.prisma.allergen.findMany(),
    ]);

    const dishList = dishes
      .map((d: DishWithRelations) => {
        const allergenNames = d.DishAllergen.map(
          (da: { Allergen: { name: string } }) => da.Allergen.name,
        ).join(', ');
        const ingredients = d.DishIngredient.map(
          (di: {
            Ingredient: { name: string; unit: string | null };
            quantity: unknown;
          }) =>
            `${di.Ingredient.name} (${String(di.quantity)}${di.Ingredient.unit ?? ''})`,
        ).join(', ');
        return `  - [ID:${d.id}] "${d.title}" (${d.course_type ?? 'plat'}) — ${d.description || 'Pas de description'}. Allergènes: ${allergenNames || 'aucun'}. Ingrédients: ${ingredients || 'non renseignés'}`;
      })
      .join('\n');

    const menuList = menus
      .map((m: MenuWithRelations) => {
        const dishNames = m.Dish.map((d: { title: string }) => d.title).join(
          ', ',
        );
        return `  - [ID:${m.id}] "${m.title}" — ${String(m.price_per_person)}€/pers, min ${m.person_min} pers. Régime: ${m.Diet?.name || 'aucun'}. Thème: ${m.Theme?.name || 'aucun'}. Plats: ${dishNames || 'aucun'}${m.is_seasonal ? ' (saisonnier)' : ''}`;
      })
      .join('\n');

    const dietList = diets
      .map((d: Diet) => `  - [ID:${d.id}] ${d.name}: ${d.description}`)
      .join('\n');
    const themeList = themes
      .map((t: Theme) => `  - [ID:${t.id}] ${t.name}: ${t.description}`)
      .join('\n');
    const allergenList = allergens
      .map((a: Allergen) => `  - [ID:${a.id}] ${a.name}`)
      .join('\n');

    return `
═══ BASE DE DONNÉES VITE & GOURMAND ═══

PLATS DISPONIBLES (${dishes.length}):
${dishList}

MENUS PUBLIÉS (${menus.length}):
${menuList}

RÉGIMES ALIMENTAIRES:
${dietList}

THÈMES:
${themeList}

ALLERGÈNES RÉPERTORIÉS:
${allergenList}
`;
  }

  /* ═══════════════════════════════════════════════════════════
     System prompt
     ═══════════════════════════════════════════════════════════ */

  private buildSystemPrompt(dbContext: string): string {
    return `Tu es l'assistant IA de "Vite & Gourmand", un service de traiteur haut de gamme.
Ton rôle est d'aider les visiteurs (clients potentiels) à composer un menu personnalisé pour leur événement.
Tu es intégré dans la page de commande, à côté d'un formulaire de brief que le visiteur remplit en parallèle.

CHAMPS OBLIGATOIRES À COLLECTER :
Avant de pouvoir proposer un menu, tu DOIS obtenir ces informations essentielles :
- 🎉 Type d'événement (mariage, anniversaire, séminaire, baptême, etc.)
- 👥 Nombre de convives
- 💰 Budget par personne
- 📅 Date souhaitée de l'événement
Si le visiteur ne les a pas encore fournis, pose la question de manière naturelle et chaleureuse.
Ne propose JAMAIS un menu complet tant que ces 4 champs ne sont pas renseignés.

INFORMATIONS RECOMMANDÉES (à demander si pertinent) :
- 🥗 Régimes alimentaires (végétarien, halal, sans gluten…)
- ⚠️ Allergies à prendre en compte
- 🎨 Thème ou ambiance souhaitée

RÈGLES :
1. Tu parles TOUJOURS en français, de manière professionnelle mais chaleureuse et accueillante.
2. Tu t'appuies UNIQUEMENT sur les plats et menus réels de la base de données ci-dessous.
3. Tu poses des questions pour comprendre les besoins : nombre de convives, budget, régime alimentaire, allergies, thème de l'événement, préférences.
4. Tu proposes des menus adaptés au budget (prix/personne × nombre de convives).
5. Tu respectes STRICTEMENT les contraintes d'allergènes et de régime.
6. Tu suggères des services complémentaires pour enrichir l'expérience : décoration, animation, boissons, service en salle, location de matériel.
7. Quand un menu est validé, tu le présentes dans un format structuré clair.

FORMAT MENU PERSONNALISÉ :
═══════════════════════════
🍽️ MENU « [Nom du menu] »
Pour [X] convives — [budget]€/personne
Thème : [thème] | Régime : [régime]
───────────────────────────
🥗 ENTRÉE : [Nom du plat]
🍖 PLAT : [Nom du plat]
🍰 DESSERT : [Nom du plat]
───────────────────────────
💰 Total estimé : [X]€ ([Y]€/pers × [Z] convives)
📝 Notes : [remarques spéciales]
═══════════════════════════

8. Si le client veut un menu existant adapté, propose des modifications plutôt que de créer from scratch.
9. Donne des estimations de coût réalistes basées sur les prix dans la base.
10. Si tu ne peux pas satisfaire une demande avec les plats existants, dis-le clairement et propose une alternative.
11. Propose toujours des services additionnels (boissons, desserts supplémentaires, décoration) pour enrichir l'expérience.
12. Quand la proposition est validée, invite le visiteur à vérifier le brief à droite puis à cliquer "Envoyer la demande" pour que l'équipe reçoive un ticket avec tous les détails.
13. Tes réponses doivent être concises mais chaleureuses. Ne répète jamais le format du menu dans la conversation, utilise-le uniquement pour les propositions finales.
14. Les informations remplies par le visiteur apparaissent automatiquement dans le brief à droite — tu peux y faire référence en disant "je vois que vous avez indiqué…".

${dbContext}`;
  }

  /* ═══════════════════════════════════════════════════════════
     System prompt for Event Planner / Contact page concierge
     ═══════════════════════════════════════════════════════════ */

  private buildEventPlannerPrompt(dbContext: string): string {
    return `Tu es le "Concierge Événementiel IA" de "Vite & Gourmand", un traiteur gastronomique haut de gamme.
Tu es intégré dans la page Contact du site. Ton rôle est triple :
1. AIDER le client à mieux réfléchir à son événement en posant les bonnes questions
2. INSPIRER le client avec des idées concrètes et des suggestions premium
3. GÉNÉRER un message de demande de devis parfaitement structuré et détaillé

TU ES UN VENDEUR SUBTIL : tu enrichis naturellement la demande du client en suggérant des prestations complémentaires, sans jamais forcer. Tu plantes des idées qui donnent envie.

PROCESSUS CONVERSATIONNEL :
Étape 1 — DÉCOUVERTE (pose 1-2 questions max à la fois, jamais plus)
  • Type d'événement + occasion spéciale ?
  • Nombre de convives approximatif ?
  • Date / période envisagée ?
  • Lieu (chez eux, salle louée, plein air ?) ?

Étape 2 — APPROFONDISSEMENT (dès que tu as le type + nb convives)
  • Budget par personne ? (si hésitant, donne des fourchettes : "nos formules vont de 25€ à 65€/pers")
  • Ambiance souhaitée ? (élégant, champêtre, décontracté, thématique…)
  • Contraintes alimentaires ? (végétarien, halal, allergies…)
  • Attentes particulières ? (animations, décoration, bar à cocktails…)

Étape 3 — INSPIRATION & UPSELL SUBTIL
  Quand tu as assez d'infos, propose 2-3 idées concrètes tirées des vrais menus de la base :
  • Un menu adapté avec prix indicatif
  • Des options "signature" qui font la différence (ex : "Pour un mariage de 80 pers, notre menu Gastronomie avec bar à fromages serait magnifique")
  • Services complémentaires : "Avez-vous pensé à notre service de mise en place ? Ou à un bar à cocktails pour l'apéritif ?"
  NE POUSSE PAS, INSPIRE. Phrase type : "Beaucoup de nos clients pour ce type d'événement apprécient aussi…"

Étape 4 — GÉNÉRATION DU MESSAGE
  Quand le client est satisfait, génère un message de demande de devis structuré :

  📋 DEMANDE DE DEVIS — [Type d'événement]
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  📅 Date : [date]
  👥 Nombre de convives : [nombre]
  📍 Lieu : [lieu]
  💰 Budget envisagé : [budget]€/personne

  🍽️ Formule souhaitée :
  • [détails menu / préférences]

  🥗 Contraintes alimentaires :
  • [régimes / allergies]

  ✨ Services complémentaires souhaités :
  • [liste des extras]

  💬 Précisions supplémentaires :
  [notes additionnelles du client]
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Dis ensuite : "Voici votre demande ! Cliquez sur 'Copier dans le formulaire' et envoyez — notre équipe vous répondra sous 24h avec un devis détaillé."

RÈGLES STRICTES :
- Parle TOUJOURS en français, chaleureux et professionnel
- JAMAIS plus de 2 questions à la fois — c'est une conversation, pas un interrogatoire
- Base tes suggestions sur les VRAIS menus et plats de la base de données
- Donne des prix indicatifs réalistes basés sur les menus existants
- Valorise CHAQUE événement : un anniversaire de 15 personnes mérite autant d'attention qu'un mariage de 200
- Quand tu suggères un extra, explique POURQUOI ça améliore l'expérience
- Sois concis : max 5-6 lignes par réponse (sauf la proposition finale)
- Utilise les emojis avec goût, pas trop

${dbContext}`;
  }

  /* ═══════════════════════════════════════════════════════════
     System prompt for Public Assistant mode
     ═══════════════════════════════════════════════════════════ */

  private buildPublicAssistantPrompt(dbContext: string): string {
    return `Tu es l'assistant virtuel de "Vite & Gourmand", un service de traiteur gastronomique.
Tu apparais comme un petit robot sympathique dans le coin de l'écran des pages publiques et du profil utilisateur.

TON RÔLE :
Tu es un assistant d'accueil et de renseignements. Tu aides les visiteurs à :
1. 🏪 Découvrir le concept de Vite & Gourmand (traiteur événementiel haut de gamme, menus personnalisés, chef passionné)
2. 📋 Comprendre les menus et plats disponibles
3. 🎉 Connaître les promotions actuelles
4. ✉️ Préparer leur demande de contact (devis, renseignements)
5. 🧭 Les orienter vers la bonne page (contact, menus, commande)

STYLE DE COMMUNICATION :
- Sois chaleureux, accueillant et professionnel
- Réponds en français
- Sois concis (2-4 phrases max par réponse sauf demande détaillée)
- Utilise des emojis avec modération pour rendre les échanges vivants
- Ne sois pas trop formel, reste accessible

INFORMATIONS À CONNAÎTRE SUR VITE & GOURMAND :
- Traiteur gastronomique spécialisé dans les événements (mariages, anniversaires, séminaires, baptêmes)
- Cuisine française raffinée avec des produits frais et de saison
- Menus personnalisables selon les besoins (régimes alimentaires, allergies, budget)
- Services complémentaires disponibles (décoration, animation, boissons, location matériel)
- Équipe passionnée dirigée par un chef expérimenté
- Devis gratuit sous 24h après demande

QUAND AIDER À RÉDIGER UN MESSAGE :
Si le visiteur veut contacter l'équipe, propose-lui de l'aider à structurer sa demande en lui posant des questions :
- Type d'événement
- Nombre de convives
- Date souhaitée
- Budget approximatif
- Contraintes particulières (allergies, régime)
Puis génère un brouillon de message professionnel qu'il pourra copier dans le formulaire.

REDIRECTION :
- Pour commander : invite à aller sur la page "Commander"
- Pour un devis : invite à aller sur la page "Contact"
- Pour voir les menus : invite à aller sur la page "Nos Menus"

${dbContext}`;
  }

  /* ═══════════════════════════════════════════════════════════
     Chat
     ═══════════════════════════════════════════════════════════ */

  async chat(userId: number, dto: ChatMessageDto) {
    const convId = dto.conversationId || this.generateConversationId();
    const assistantMode = dto.context?.mode;

    // Get or create conversation
    let conversation = this.conversations.get(convId);
    if (!conversation) {
      const dbContext = await this.gatherDatabaseContext();
      const systemPrompt = this.buildModePrompt(assistantMode, dbContext);

      conversation = {
        messages: [{ role: 'system', content: systemPrompt }],
        context: {
          guestCount: dto.guestCount,
          budgetPerPerson: dto.budgetPerPerson,
          dietId: dto.dietId,
          themeId: dto.themeId,
          excludeAllergens: dto.excludeAllergens,
        },
        createdAt: new Date(),
      };
      this.conversations.set(convId, conversation);

      // Add initial context message if constraints were provided
      const constraints = this.getConversationConstraints(dto);

      if (constraints.length > 0) {
        conversation.messages.push({
          role: 'system',
          content: `Contexte client transmis par l'équipe : ${constraints.join(' | ')}. Utilise ces informations dans tes propositions.`,
        });
      }
    }

    // Add user message
    conversation.messages.push({ role: 'user', content: dto.message });

    // Get AI response
    const assistantMessage = await this.getAiResponse(conversation.messages);
    conversation.messages.push({
      role: 'assistant',
      content: assistantMessage,
    });

    return {
      conversationId: convId,
      message: assistantMessage,
      context: conversation.context,
      messageCount: conversation.messages.filter((m) => m.role !== 'system')
        .length,
    };
  }

  private buildModePrompt(mode: string | undefined, dbContext: string): string {
    if (mode === 'public_assistant')
      return this.buildPublicAssistantPrompt(dbContext);
    if (mode === 'event_planner')
      return this.buildEventPlannerPrompt(dbContext);
    return this.buildSystemPrompt(dbContext);
  }

  private getConversationConstraints(dto: ChatMessageDto): string[] {
    const constraints: string[] = [];
    if (dto.guestCount) constraints.push(`${dto.guestCount} convives`);
    if (dto.budgetPerPerson)
      constraints.push(`budget ${dto.budgetPerPerson}€/personne`);
    if (dto.dietId) constraints.push(`régime alimentaire ID:${dto.dietId}`);
    if (dto.themeId) constraints.push(`thème ID:${dto.themeId}`);
    if (dto.excludeAllergens?.length) {
      constraints.push(
        `allergènes à exclure IDs: ${dto.excludeAllergens.join(', ')}`,
      );
    }
    return constraints;
  }

  /* ═══════════════════════════════════════════════════════════
     AI Response (OpenAI or Demo fallback)
     ═══════════════════════════════════════════════════════════ */

  private async getAiResponse(messages: ConversationEntry[]): Promise<string> {
    if (this.openai) {
      try {
        const response = await this.openai.chat.completions.create({
          model: 'llama-3.3-70b-versatile',
          messages: messages.map((m) => ({ role: m.role, content: m.content })),
          temperature: 0.7,
          max_tokens: 2048,
        });
        return (
          response.choices[0]?.message?.content ||
          "Désolé, je n'ai pas pu générer de réponse."
        );
      } catch (err) {
        this.logger.error('Groq API error', err);
        return "Erreur de communication avec l'IA. Veuillez réessayer dans quelques instants.";
      }
    }

    // Demo mode — no API key
    return this.getDemoResponse(messages);
  }

  private getDemoResponse(messages: ConversationEntry[]): string {
    const userMessages = messages.filter((m) => m.role === 'user');
    const lastMsg = userMessages.at(-1)?.content.toLowerCase() || '';
    const systemPrompt =
      messages.find((m) => m.role === 'system')?.content || '';
    const isPublicAssistant = systemPrompt.includes('assistant virtuel');
    const isEventPlanner = systemPrompt.includes('Concierge Événementiel');

    // Public assistant mode — general questions
    if (isPublicAssistant) {
      return this.getPublicAssistantDemoResponse(userMessages, lastMsg);
    }

    // Event planner mode — contact page concierge
    if (isEventPlanner) {
      return this.getEventPlannerDemoResponse(userMessages, lastMsg);
    }

    // Menu builder mode — existing logic
    if (userMessages.length === 1) {
      return `Bonjour ! 👋 Je suis l'assistant IA de Vite & Gourmand.

Je suis là pour vous aider à composer le menu idéal pour votre événement !

Pour commencer, dites-moi :
1. 🎉 Quel **type d'événement** organisez-vous ?
2. 👥 **Combien de convives** seront présents ?
3. 💰 Avez-vous un **budget par personne** en tête ?
4. 🥗 Des **régimes alimentaires** à respecter ? (végétarien, sans gluten…)
5. ⚠️ Des **allergies** à prendre en compte ?

N'hésitez pas, je suis là pour vous guider ! 😊

> ℹ️ **Mode démo** — Les réponses sont pré-configurées. En production, l'IA génère de vraies propositions de menus basées sur notre carte.`;
    }

    if (
      lastMsg.includes('convive') ||
      lastMsg.includes('personne') ||
      /\d+\s*(pers|invit|conviv)/.test(lastMsg)
    ) {
      return `Parfait, j'ai bien noté ! 👥

Maintenant, quel **budget par personne** envisagez-vous ?
Par exemple : 25€, 35€, 50€/personne…

Cela me permettra de vous proposer un menu adapté parmi nos créations. 🍽️

> ℹ️ Mode démo — réponses pré-définies.`;
    }

    if (
      lastMsg.includes('budget') ||
      lastMsg.includes('€') ||
      lastMsg.includes('euro')
    ) {
      return `Excellent, budget noté ! 💰

Y a-t-il des **contraintes alimentaires** à prendre en compte ?
- Végétarien, végan, sans gluten, halal…
- Des **allergies** particulières ?

Notre chef s'adapte à toutes les exigences pour que chacun de vos convives passe un moment inoubliable. ✨

> ℹ️ Mode démo — En production, je vous proposerai un menu complet.`;
    }

    return `Merci pour ces précisions ! 📝

En mode démo, je ne peux malheureusement pas générer de proposition complète.
Mais voici ce que l'assistant complet peut faire pour vous :

✅ Proposer des menus sur mesure adaptés à votre budget
✅ Respecter toutes les contraintes alimentaires et allergies
✅ Calculer le coût total de votre événement
✅ Suggérer des services complémentaires (boissons, décoration…)

En attendant, n'hésitez pas à remplir le **formulaire de contact** à gauche avec vos besoins — notre équipe vous répondra avec une proposition personnalisée sous 24h ! 📧

> ℹ️ Mode démo actif.`;
  }

  /* ═══════════════════════════════════════════════════════════
     Public Assistant Demo Response
     ═══════════════════════════════════════════════════════════ */

  private getPublicAssistantDemoResponse(
    userMessages: ConversationEntry[],
    lastMsg: string,
  ): string {
    // First message — welcome
    if (userMessages.length === 1) {
      // Detect intent from first message
      if (
        lastMsg.includes('concept') ||
        lastMsg.includes('qui êtes') ||
        lastMsg.includes("c'est quoi")
      ) {
        return `🍽️ **Vite & Gourmand**, c'est votre traiteur gastronomique pour tous vos événements !

Notre équipe passionnée crée des menus sur mesure avec des produits frais et de saison. Que ce soit pour un mariage, un anniversaire ou un séminaire d'entreprise, nous nous adaptons à vos envies et contraintes.

Vous souhaitez en savoir plus sur nos menus ou nos services ? 😊`;
      }

      if (
        lastMsg.includes('menu') ||
        lastMsg.includes('plat') ||
        lastMsg.includes('carte')
      ) {
        return `📋 Nous proposons une variété de menus pour tous les goûts !

- 🥗 **Entrées** : Foie gras, carpaccio, velouté de saison…
- 🍖 **Plats** : Filet de bœuf, suprême de volaille, poisson de saison…
- 🍰 **Desserts** : Panna cotta, tarte tatin, crème brûlée…

Chaque menu est personnalisable selon vos besoins (végétarien, sans gluten, halal…). Rendez-vous sur la page **Nos Menus** pour découvrir toutes nos créations ! 🎨`;
      }

      if (
        lastMsg.includes('promo') ||
        lastMsg.includes('offre') ||
        lastMsg.includes('réduction')
      ) {
        return `🎉 Bonne nouvelle ! Nous avons régulièrement des offres spéciales.

Actuellement, profitez de :
- 🎁 **-10%** pour toute première commande
- 👥 **-5%** à partir de 50 convives
- 🍾 **Champagne offert** pour les mariages de plus de 80 personnes

Contactez-nous pour un devis personnalisé et découvrir les offres du moment ! ✨`;
      }

      if (
        lastMsg.includes('contact') ||
        lastMsg.includes('message') ||
        lastMsg.includes('écrire') ||
        lastMsg.includes('rédiger')
      ) {
        return `✉️ Je peux vous aider à préparer votre message !

Pour que l'équipe puisse vous répondre au mieux, indiquez-moi :
1. 🎉 Le type d'événement (mariage, anniversaire…)
2. 👥 Le nombre de convives
3. 📅 La date souhaitée
4. 💰 Votre budget approximatif

Je vous aiderai à formuler une demande claire et complète ! 😊`;
      }

      // Default welcome
      return `Bonjour ! 👋 Je suis l'assistant virtuel de Vite & Gourmand.

Je peux vous renseigner sur :
- 🏪 Notre concept et nos valeurs
- 📋 Nos menus et plats disponibles  
- 🎉 Nos promotions actuelles
- ✉️ Vous aider à préparer votre demande de devis

Comment puis-je vous aider aujourd'hui ? 😊`;
    }

    // Follow-up messages
    if (
      lastMsg.includes('contact') ||
      lastMsg.includes('devis') ||
      lastMsg.includes('commander')
    ) {
      return `Parfait ! 📝

Pour faire une demande de devis, rendez-vous sur notre page **Contact**. Vous y trouverez un formulaire simple où vous pourrez détailler vos besoins.

Notre équipe vous répondra sous 24h avec une proposition personnalisée ! 🚀

> 💡 Cliquez sur le bouton "Aller au formulaire de contact" ci-dessous pour y accéder directement.`;
    }

    if (
      lastMsg.includes('merci') ||
      lastMsg.includes('super') ||
      lastMsg.includes('parfait')
    ) {
      return `Avec plaisir ! 😊

N'hésitez pas si vous avez d'autres questions. Je suis là pour vous aider !

Bonne visite sur Vite & Gourmand 🍽️✨`;
    }

    // Default fallback
    return `Je suis là pour vous aider ! 😊

Vous pouvez me poser des questions sur :
- Notre concept et nos services
- Nos menus et tarifs
- Comment nous contacter

Ou rendez-vous directement sur la page **Contact** pour une demande de devis personnalisé.

> ℹ️ Mode démo — En production, je peux répondre à toutes vos questions en détail !`;
  }

  /* ═══════════════════════════════════════════════════════════
     Event Planner Demo Response
     ═══════════════════════════════════════════════════════════ */

  private getEventPlannerDemoResponse(
    userMessages: ConversationEntry[],
    lastMsg: string,
  ): string {
    if (userMessages.length === 1) {
      // Detect event type from first message
      if (lastMsg.includes('mariage') || lastMsg.includes('noce')) {
        return `💒 Félicitations pour votre mariage ! C'est un plaisir de vous accompagner dans ce moment unique.

Pour vous proposer le menu parfait, j'aurais besoin de quelques précisions :
- 👥 Combien de convives attendez-vous ?
- 📅 Quelle est la date prévue ?

En attendant, sachez que notre **formule Mariage** inclut un cocktail dînatoire, un menu 3 services et le gâteau. Beaucoup de nos mariés adorent notre bar à fromages artisanal en supplément ! 🧀`;
      }

      if (lastMsg.includes('anniversaire') || lastMsg.includes('fête')) {
        return `🎂 Un anniversaire, quelle belle occasion de se réunir !

Pour créer un moment mémorable, dites-moi :
- 👥 Combien de convives prévoyez-vous ?
- 🎯 C'est pour quel âge ? (ça m'aide à adapter l'ambiance !)

Nos formules anniversaire commencent à partir de 25€/personne avec entrée + plat + dessert. Et notre option "dessert spectacle" avec gâteau sur mesure fait toujours sensation ! ✨`;
      }

      if (
        lastMsg.includes('entreprise') ||
        lastMsg.includes('séminaire') ||
        lastMsg.includes('corporate')
      ) {
        return `🏢 Événement professionnel, excellent choix ! Nous accompagnons régulièrement des entreprises bordelaises.

Pour adapter notre proposition :
- 👥 Combien de collaborateurs seront présents ?
- 🎯 Quel format : déjeuner assis, cocktail dînatoire, buffet ?

Notre formule entreprise inclut des options comme le plateau de viennoiseries pour les pauses et le service en salle. Qu'en pensez-vous ? 💼`;
      }

      // Default welcome
      return `Bonjour ! 👋 Je suis le concierge événementiel de Vite & Gourmand.

Je suis là pour vous aider à imaginer et planifier votre événement. Dites-moi :
- 🎉 Quel type d'événement organisez-vous ?
- 👥 Combien de convives environ ?

Je vous guiderai vers la formule idéale et vous aiderai à rédiger une demande complète ! 😊`;
    }

    // Second message — budget & details
    if (userMessages.length === 2) {
      if (
        lastMsg.includes('budget') ||
        lastMsg.includes('€') ||
        /\d+\s*eur/.test(lastMsg)
      ) {
        return `Parfait, j'ai noté votre budget ! 💰

Pour affiner ma proposition, avez-vous des préférences ou contraintes ?
- 🥗 Régimes alimentaires (végétarien, sans gluten, halal…)
- ⚠️ Allergies à prendre en compte
- 🎨 Ambiance souhaitée (élégant, champêtre, moderne…)

Beaucoup de nos clients apprécient aussi notre **service de mise en place** avec nappage et décoration de table — c'est un vrai plus pour l'ambiance ! 🌸`;
      }

      return `Merci pour ces informations ! 📝

Pour que notre proposition soit vraiment sur mesure :
- 💰 Avez-vous un **budget par personne** en tête ? Nos formules vont de 25€ à 65€/personne.
- 📍 Le lieu est-il déjà défini ?

Et si vous le souhaitez, nous proposons aussi un **service boissons** avec accord mets-vins sélectionné par notre sommelier ! 🍷`;
    }

    // Third+ message — generate the request
    return `Merci pour tous ces détails ! Voici votre demande de devis prête à envoyer :

📋 **DEMANDE DE DEVIS**
━━━━━━━━━━━━━━━━━━━━━━
📅 Date : à confirmer
👥 Convives : à préciser
💰 Budget : selon vos indications

🍽️ Formule souhaitée :
• Menu personnalisé selon vos préférences

✨ Services complémentaires :
• Mise en place et décoration
• Service en salle

💬 Vos précisions sont les bienvenues !
━━━━━━━━━━━━━━━━━━━━━━

Cliquez sur **"Copier dans le formulaire"** ci-dessous puis envoyez votre demande. Notre équipe vous répondra sous 24h avec un devis détaillé ! 🚀

> ℹ️ Mode démo — En production, cette proposition sera personnalisée avec vos vrais menus et tarifs.`;
  }

  /* ═══════════════════════════════════════════════════════════
     Conversation management
     ═══════════════════════════════════════════════════════════ */

  getConversation(conversationId: string) {
    const conv = this.conversations.get(conversationId);
    if (!conv) return null;
    return {
      conversationId,
      messages: conv.messages
        .filter((m) => m.role !== 'system')
        .map((m) => ({ role: m.role, content: m.content })),
      context: conv.context,
      createdAt: conv.createdAt,
    };
  }

  listConversations() {
    const result: { id: string; messageCount: number; createdAt: Date }[] = [];
    for (const [id, conv] of this.conversations) {
      result.push({
        id,
        messageCount: conv.messages.filter((m) => m.role !== 'system').length,
        createdAt: conv.createdAt,
      });
    }
    return result.sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
  }

  deleteConversation(conversationId: string) {
    return this.conversations.delete(conversationId);
  }

  getStatus() {
    return {
      aiEnabled: !!this.openai,
      model: this.openai ? 'llama-3.3-70b-versatile' : 'demo',
      activeConversations: this.conversations.size,
    };
  }

  private generateConversationId(): string {
    return `conv_${Date.now()}_${Math.random().toString(36).substring(2, 8)}`;
  }
}
