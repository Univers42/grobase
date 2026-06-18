import { Card, CardContent, CardHeader, CardTitle } from '../components/ui/card';
import { Button } from '../components/ui/button';
import {
  ArrowLeft,
  Scale,
  FileText,
  Shield,
  AlertTriangle,
  Clock,
  CreditCard,
  Truck,
  Phone,
  Mail,
  MapPin,
} from 'lucide-react';
import type { Page } from './Home';

type LegalPageProps = {
  section: 'mentions' | 'cgv';
  setCurrentPage: (page: Page) => void;
};

/**
 * LegalPage - Mentions légales et CGV
 *
 * Color scheme from graphical chart:
 * - Deep Bordeaux (#722F37) - Primary brand color
 * - Champagne (#D4AF37) - Accent
 * - Crème (#FFF8F0) - Light backgrounds
 * - Vert olive (#556B2F) - Success
 * - Noir charbon (#1A1A1A) - Text
 */
export default function LegalPage({ section, setCurrentPage }: Readonly<LegalPageProps>) {
  return (
    <div className="min-h-screen bg-[#FFF8F0]">
      {/* Header Section */}
      <div className="bg-[#1A1A1A] py-16 sm:py-20">
        <div className="max-w-4xl mx-auto px-6 sm:px-8 lg:px-12">
          <Button
            onClick={() => setCurrentPage('home')}
            variant="ghost"
            className="mb-8 text-white/70 hover:text-white hover:bg-white/10"
          >
            <ArrowLeft className="h-4 w-4 mr-2" />
            Retour à l'accueil
          </Button>
          <div className="flex flex-col sm:flex-row items-start sm:items-center gap-3 sm:gap-5">
            <div className="w-12 h-12 sm:w-16 sm:h-16 bg-gradient-to-br from-[#722F37] to-[#5a252c] rounded-xl sm:rounded-2xl flex items-center justify-center shadow-lg shadow-[#722F37]/30 flex-shrink-0">
              {section === 'mentions' ? (
                <Scale className="h-5 w-5 sm:h-8 sm:w-8 text-white" />
              ) : (
                <FileText className="h-5 w-5 sm:h-8 sm:w-8 text-white" />
              )}
            </div>
            <div>
              <h1 className="text-2xl sm:text-3xl lg:text-4xl font-bold text-white">
                {section === 'mentions' ? 'Mentions légales' : 'Conditions Générales de Vente'}
              </h1>
              <p className="text-white/60 mt-1">
                {section === 'mentions'
                  ? 'Informations légales et réglementaires'
                  : 'Conditions applicables à toute commande'}
              </p>
            </div>
          </div>
        </div>
      </div>

      <div className="max-w-4xl mx-auto px-6 sm:px-8 lg:px-12 py-12 -mt-8">
        {section === 'mentions' ? (
          <Card className="bg-white border-0 shadow-xl rounded-3xl overflow-hidden">
            <CardHeader className="bg-gradient-to-r from-[#FFF8F0] to-white border-b border-[#722F37]/10 py-6 px-5 sm:px-8">
              <CardTitle className="text-xl text-[#1A1A1A] flex items-center gap-3">
                <Shield className="h-6 w-6 text-[#722F37]" />
                Informations légales
              </CardTitle>
            </CardHeader>
            <CardContent className="p-5 sm:p-8 lg:p-10 space-y-10">
              {/* Section 1 */}
              <section>
                <h2 className="text-xl font-bold text-[#1A1A1A] mb-4 pb-2 border-b-2 border-[#D4AF37] flex items-center gap-3">
                  <span className="w-8 h-8 bg-[#722F37] rounded-lg flex items-center justify-center text-white text-sm font-bold">
                    1
                  </span>{' '}
                  Éditeur du site
                </h2>
                <div className="bg-[#FFF8F0] rounded-2xl p-6 space-y-4 border border-[#722F37]/10">
                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <div>
                      <span className="font-semibold text-[#1A1A1A]">Raison sociale</span>
                      <p className="text-[#1A1A1A]/70">Vite & Gourmand</p>
                    </div>
                    <div>
                      <span className="font-semibold text-[#1A1A1A]">Forme juridique</span>
                      <p className="text-[#1A1A1A]/70">Entreprise individuelle</p>
                    </div>
                  </div>
                  <div className="pt-4 border-t border-[#722F37]/10 space-y-3">
                    <div className="flex items-center gap-3 text-[#1A1A1A]/70">
                      <MapPin className="h-5 w-5 text-[#722F37]" />
                      15 Rue Sainte-Catherine, 33000 Bordeaux
                    </div>
                    <div className="flex items-center gap-3 text-[#1A1A1A]/70">
                      <Phone className="h-5 w-5 text-[#722F37]" />
                      +33 5 56 00 00 00
                    </div>
                    <div className="flex items-center gap-3 text-[#1A1A1A]/70">
                      <Mail className="h-5 w-5 text-[#722F37]" />
                      <a
                        href="mailto:contact@vite-gourmand.fr"
                        className="text-[#722F37] hover:underline"
                      >
                        contact@vite-gourmand.fr
                      </a>
                    </div>
                  </div>
                  <div className="pt-4 border-t border-[#722F37]/10">
                    <span className="font-semibold text-[#1A1A1A]">
                      Directeurs de la publication
                    </span>
                    <p className="text-[#1A1A1A]/70">Julie et José Martinez</p>
                  </div>
                </div>
              </section>

              {/* Section 2 */}
              <section>
                <h2 className="text-xl font-bold text-[#1A1A1A] mb-4 pb-2 border-b-2 border-[#D4AF37] flex items-center gap-3">
                  <span className="w-8 h-8 bg-[#722F37] rounded-lg flex items-center justify-center text-white text-sm font-bold">
                    2
                  </span>{' '}
                  Hébergement
                </h2>
                <p className="text-[#1A1A1A]/70 bg-[#FFF8F0] rounded-2xl p-6 border border-[#722F37]/10">
                  Le site est hébergé par notre infrastructure cloud sécurisée. Serveur situé en
                  France, conformément aux réglementations européennes.
                </p>
              </section>

              {/* Section 3 */}
              <section>
                <h2 className="text-xl font-bold text-[#1A1A1A] mb-4 pb-2 border-b-2 border-[#D4AF37] flex items-center gap-3">
                  <span className="w-8 h-8 bg-[#722F37] rounded-lg flex items-center justify-center text-white text-sm font-bold">
                    3
                  </span>{' '}
                  Protection des données personnelles (RGPD)
                </h2>
                <div className="space-y-6">
                  <p className="text-[#1A1A1A]/70 leading-relaxed">
                    Conformément au Règlement (UE) 2016/679 du Parlement européen et du Conseil du
                    27 avril 2016 (Règlement Général sur la Protection des Données — RGPD) et à la
                    loi n°78-17 du 6 janvier 1978 modifiée dite « Informatique et Libertés », Vite
                    &amp; Gourmand s'engage à protéger la vie privée des utilisateurs de son site et
                    à garantir un niveau de protection élevé de leurs données personnelles.
                  </p>

                  {/* 3.1 Responsable du traitement */}
                  <div>
                    <h3 className="text-base font-semibold text-[#1A1A1A] mb-2">
                      3.1 — Responsable du traitement
                    </h3>
                    <p className="text-[#1A1A1A]/70 leading-relaxed">
                      Le responsable du traitement est <strong>Vite &amp; Gourmand</strong>,
                      entreprise individuelle, dont le siège se situe au 15 Rue Sainte-Catherine,
                      33000 Bordeaux. Contact DPO :{' '}
                      <a
                        href="mailto:rgpd@vite-gourmand.fr"
                        className="text-[#722F37] hover:underline font-semibold"
                      >
                        rgpd@vite-gourmand.fr
                      </a>
                    </p>
                  </div>

                  {/* 3.2 Données collectées */}
                  <div className="bg-[#722F37]/5 rounded-2xl p-6 border border-[#722F37]/10">
                    <h3 className="font-semibold text-[#722F37] mb-3 flex items-center gap-2">
                      <Shield className="h-5 w-5" />
                      3.2 — Données personnelles collectées
                    </h3>
                    <ul className="space-y-2 text-[#1A1A1A]/70">
                      {[
                        {
                          cat: 'Identification',
                          items: 'nom, prénom, adresse email, téléphone, adresse postale',
                        },
                        {
                          cat: 'Connexion',
                          items: 'adresse IP, logs de connexion, horodatage, navigateur, OS',
                        },
                        {
                          cat: 'Commande',
                          items:
                            "historique d'achats, préférences alimentaires, allergènes, montants",
                        },
                        {
                          cat: 'Navigation',
                          items: 'pages visitées, durée, interactions (cookies techniques)',
                        },
                        {
                          cat: 'Communication',
                          items: 'messages de contact, échanges support, conversations IA',
                        },
                        {
                          cat: 'Fidélité',
                          items: "points accumulés, récompenses, code d'affiliation",
                        },
                        {
                          cat: 'Newsletter',
                          items: "consentement, email, date d'inscription, préférences",
                        },
                      ].map((d) => (
                        <li key={d.cat} className="flex items-start gap-2">
                          <span className="w-1.5 h-1.5 bg-[#722F37] rounded-full mt-2 flex-shrink-0" />
                          <span>
                            <strong className="text-[#1A1A1A]">{d.cat} :</strong> {d.items}
                          </span>
                        </li>
                      ))}
                    </ul>
                  </div>

                  {/* 3.3 Bases légales et finalités */}
                  <div>
                    <h3 className="text-base font-semibold text-[#1A1A1A] mb-3">
                      3.3 — Bases légales, finalités et durées de conservation
                    </h3>
                    <div className="overflow-x-auto rounded-xl border border-[#722F37]/10">
                      <table className="w-full text-sm">
                        <thead>
                          <tr className="bg-[#722F37] text-white">
                            <th className="text-left p-3 font-semibold">Finalité</th>
                            <th className="text-left p-3 font-semibold">Base légale (RGPD)</th>
                            <th className="text-left p-3 font-semibold">Conservation</th>
                          </tr>
                        </thead>
                        <tbody className="text-[#1A1A1A]/70">
                          {[
                            [
                              'Gestion des comptes utilisateurs',
                              'Exécution du contrat (Art. 6.1.b)',
                              'Durée du compte + 3 ans',
                            ],
                            [
                              'Traitement et suivi des commandes',
                              'Exécution du contrat (Art. 6.1.b)',
                              '5 ans (obligation comptable)',
                            ],
                            [
                              'Programme de fidélité et affiliation',
                              'Consentement (Art. 6.1.a)',
                              'Durée du compte + 1 an',
                            ],
                            [
                              'Newsletters et promotions',
                              'Consentement explicite (Art. 6.1.a)',
                              "Jusqu'au retrait du consentement",
                            ],
                            [
                              'Réponse aux demandes de contact',
                              'Intérêt légitime (Art. 6.1.f)',
                              '1 an après dernier échange',
                            ],
                            [
                              'Assistant IA (chatbot)',
                              'Consentement (Art. 6.1.a)',
                              'Durée de la session uniquement',
                            ],
                            [
                              'Sécurité et prévention des fraudes',
                              'Intérêt légitime (Art. 6.1.f)',
                              '12 mois glissants',
                            ],
                            [
                              'Obligations légales et fiscales',
                              'Obligation légale (Art. 6.1.c)',
                              '10 ans (documents comptables)',
                            ],
                          ].map(([f, b, d]) => (
                            <tr
                              key={f}
                              className={
                                [
                                  'Gestion des comptes utilisateurs',
                                  'Programme de fidélité et affiliation',
                                  'Réponse aux demandes de contact',
                                  'Sécurité et prévention des fraudes',
                                ].includes(f)
                                  ? 'bg-[#FFF8F0]'
                                  : 'bg-white'
                              }
                            >
                              <td className="p-3 border-t border-[#722F37]/5">{f}</td>
                              <td className="p-3 border-t border-[#722F37]/5">{b}</td>
                              <td className="p-3 border-t border-[#722F37]/5">{d}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  </div>

                  {/* 3.4 Destinataires */}
                  <div>
                    <h3 className="text-base font-semibold text-[#1A1A1A] mb-2">
                      3.4 — Destinataires des données
                    </h3>
                    <ul className="space-y-2 text-[#1A1A1A]/70 ml-4">
                      <li className="flex items-start gap-2">
                        <span className="w-1.5 h-1.5 bg-[#722F37] rounded-full mt-2 flex-shrink-0" />
                        <span>
                          <strong>Personnel interne :</strong> direction, service client, équipe
                          technique — accès limité au strict nécessaire
                        </span>
                      </li>
                      <li className="flex items-start gap-2">
                        <span className="w-1.5 h-1.5 bg-[#722F37] rounded-full mt-2 flex-shrink-0" />
                        <span>
                          <strong>Hébergeur :</strong> infrastructure cloud sécurisée, serveurs en
                          Union Européenne
                        </span>
                      </li>
                      <li className="flex items-start gap-2">
                        <span className="w-1.5 h-1.5 bg-[#722F37] rounded-full mt-2 flex-shrink-0" />
                        <span>
                          <strong>Base de données :</strong> Supabase (PostgreSQL managé,
                          chiffrement au repos/transit, SOC2)
                        </span>
                      </li>
                      <li className="flex items-start gap-2">
                        <span className="w-1.5 h-1.5 bg-[#722F37] rounded-full mt-2 flex-shrink-0" />
                        <span>
                          <strong>IA :</strong> Groq (LLaMA) — conversations non stockées, non
                          utilisées pour entraînement
                        </span>
                      </li>
                      <li className="flex items-start gap-2">
                        <span className="w-1.5 h-1.5 bg-[#722F37] rounded-full mt-2 flex-shrink-0" />
                        <span>
                          <strong>Service email :</strong> prestataire SMTP transactionnel et
                          newsletters — aucune revente
                        </span>
                      </li>
                    </ul>
                    <div className="bg-[#D4AF37]/10 rounded-xl p-4 border border-[#D4AF37]/20 mt-3">
                      <p className="text-[#1A1A1A]/80 text-sm">
                        ⚠️ Aucune donnée n'est transférée hors de l'Espace Économique Européen
                        (EEE). Aucune donnée n'est vendue, louée ou cédée à des tiers à des fins
                        commerciales.
                      </p>
                    </div>
                  </div>

                  {/* 3.5 Vos droits */}
                  <div>
                    <h3 className="text-base font-semibold text-[#1A1A1A] mb-2">
                      3.5 — Vos droits
                    </h3>
                    <p className="text-[#1A1A1A]/70 mb-3">
                      Conformément aux articles 15 à 22 du RGPD, vous disposez des droits suivants :
                    </p>
                    <ul className="space-y-2 text-[#1A1A1A]/70 ml-4">
                      {[
                        [
                          "Droit d'accès (Art. 15)",
                          'obtenir la confirmation que vos données sont traitées et en recevoir une copie',
                        ],
                        [
                          'Droit de rectification (Art. 16)',
                          'corriger des données inexactes ou compléter des données incomplètes',
                        ],
                        [
                          "Droit à l'effacement (Art. 17)",
                          "demander la suppression de vos données (« droit à l'oubli »)",
                        ],
                        [
                          'Droit à la limitation (Art. 18)',
                          'restreindre le traitement de vos données dans certains cas',
                        ],
                        [
                          'Droit à la portabilité (Art. 20)',
                          'recevoir vos données dans un format structuré, couramment utilisé et lisible par machine',
                        ],
                        [
                          "Droit d'opposition (Art. 21)",
                          'vous opposer au traitement, notamment à des fins de prospection commerciale',
                        ],
                        [
                          'Retrait du consentement',
                          'à tout moment, sans affecter la licéité du traitement antérieur',
                        ],
                        [
                          'Réclamation auprès de la CNIL',
                          "Commission Nationale de l'Informatique et des Libertés — www.cnil.fr",
                        ],
                      ].map(([right, desc]) => (
                        <li key={right} className="flex items-start gap-2">
                          <span className="w-1.5 h-1.5 bg-[#722F37] rounded-full mt-2 flex-shrink-0" />
                          <span>
                            <strong>{right} :</strong> {desc}
                          </span>
                        </li>
                      ))}
                    </ul>
                    <p className="text-[#1A1A1A]/70 mt-3">
                      Pour exercer vos droits, envoyez un email à{' '}
                      <a
                        href="mailto:rgpd@vite-gourmand.fr"
                        className="text-[#722F37] hover:underline font-semibold"
                      >
                        rgpd@vite-gourmand.fr
                      </a>{' '}
                      accompagné d'une copie de pièce d'identité. Réponse garantie sous 30 jours
                      maximum.
                    </p>
                  </div>

                  {/* 3.6 Sécurité */}
                  <div>
                    <h3 className="text-base font-semibold text-[#1A1A1A] mb-2">
                      3.6 — Mesures de sécurité
                    </h3>
                    <ul className="grid grid-cols-1 sm:grid-cols-2 gap-2 text-[#1A1A1A]/70 ml-4">
                      {[
                        'Chiffrement TLS/SSL (HTTPS)',
                        'Mots de passe hashés (bcrypt, 12 rounds)',
                        'Authentification JWT sécurisée',
                        'Politique de mots de passe robuste',
                        'Row Level Security (RLS) en base',
                        "Contrôle d'accès RBAC par rôles",
                        'Protection CSRF et rate limiting',
                        'Sauvegardes automatiques régulières',
                      ].map((item) => (
                        <li key={item} className="flex items-center gap-2">
                          <span className="w-1.5 h-1.5 bg-[#556B2F] rounded-full" />
                          {item}
                        </li>
                      ))}
                    </ul>
                  </div>

                  {/* Contact DPO */}
                  <div className="bg-[#556B2F]/10 rounded-2xl p-6 border border-[#556B2F]/20">
                    <p className="text-[#556B2F] font-semibold mb-1">
                      📧 Contact DPO / Exercice de vos droits
                    </p>
                    <p className="text-[#556B2F]">
                      <a
                        href="mailto:rgpd@vite-gourmand.fr"
                        className="font-semibold hover:underline"
                      >
                        rgpd@vite-gourmand.fr
                      </a>{' '}
                      — Vite &amp; Gourmand, Service RGPD, 15 Rue Sainte-Catherine, 33000 Bordeaux
                    </p>
                  </div>
                </div>
              </section>

              {/* Section 4 — Cookies (page utilisateur final, conforme CNIL) */}
              <section id="cookies">
                <h2 className="text-xl font-bold text-[#1A1A1A] mb-4 pb-2 border-b-2 border-[#D4AF37] flex items-center gap-3">
                  <span className="w-8 h-8 bg-[#722F37] rounded-lg flex items-center justify-center text-white text-sm font-bold">
                    4
                  </span>
                  <span>Cookies</span>
                </h2>

                <p className="text-[#1A1A1A]/75 leading-relaxed mb-4">
                  Lorsque vous visitez notre site, nous utilisons des petits fichiers appelés <strong>cookies</strong>{' '}
                  (et un stockage local équivalent). Certains sont indispensables pour que le site
                  fonctionne, d'autres demandent votre accord. Vous pouvez modifier votre choix à
                  tout moment en cliquant sur <em>« Gérer mes cookies »</em> en bas de page.
                </p>

                <p className="text-[#1A1A1A]/75 leading-relaxed mb-6">
                  Nous n'utilisons <strong>aucun outil de publicité ni de profilage commercial</strong>{' '}
                  (pas de Google Analytics, pas de Meta Pixel, pas de tracking publicitaire). Vos
                  mots de passe ne sont jamais stockés dans des cookies — seuls des <strong>jetons de session signés</strong>{' '}
                  permettent de vous garder connecté(e).
                </p>

                {/* Tableau récapitulatif */}
                <div className="overflow-x-auto rounded-xl border border-[#722F37]/15 mb-6">
                  <table className="w-full text-sm">
                    <thead className="bg-[#722F37] text-white">
                      <tr>
                        <th className="text-left px-4 py-3 font-semibold">Nom</th>
                        <th className="text-left px-4 py-3 font-semibold">À quoi ça sert</th>
                        <th className="text-left px-4 py-3 font-semibold">Durée</th>
                        <th className="text-left px-4 py-3 font-semibold">Type</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-[#722F37]/10">
                      <tr className="bg-white">
                        <td className="px-4 py-3 font-mono text-xs text-[#722F37]">
                          vg_access_token
                        </td>
                        <td className="px-4 py-3 text-[#1A1A1A]/75">
                          Vous garde connecté(e) après la saisie de votre mot de passe. Ne contient
                          pas votre mot de passe, juste une preuve de connexion signée.
                        </td>
                        <td className="px-4 py-3 text-[#1A1A1A]/75 whitespace-nowrap">
                          15 minutes
                        </td>
                        <td className="px-4 py-3">
                          <span className="inline-block px-2 py-0.5 rounded-full text-xs font-semibold bg-[#556B2F]/15 text-[#556B2F]">
                            Nécessaire
                          </span>
                        </td>
                      </tr>
                      <tr className="bg-[#FFF8F0]/40">
                        <td className="px-4 py-3 font-mono text-xs text-[#722F37]">
                          vg_csrf_token
                        </td>
                        <td className="px-4 py-3 text-[#1A1A1A]/75">
                          Protège vos formulaires contre les attaques de type <em>cross-site request forgery</em>{' '}
                          (un faux site qui essaierait d'agir en votre nom).
                        </td>
                        <td className="px-4 py-3 text-[#1A1A1A]/75 whitespace-nowrap">
                          15 minutes
                        </td>
                        <td className="px-4 py-3">
                          <span className="inline-block px-2 py-0.5 rounded-full text-xs font-semibold bg-[#556B2F]/15 text-[#556B2F]">
                            Nécessaire
                          </span>
                        </td>
                      </tr>
                      <tr className="bg-white">
                        <td className="px-4 py-3 font-mono text-xs text-[#722F37]">
                          accessToken
                          <br />
                          refreshToken
                        </td>
                        <td className="px-4 py-3 text-[#1A1A1A]/75">
                          Stockés dans la mémoire de votre navigateur, ils prolongent votre session
                          sans vous redemander votre mot de passe à chaque page.
                        </td>
                        <td className="px-4 py-3 text-[#1A1A1A]/75 whitespace-nowrap">
                          7 jours max.
                        </td>
                        <td className="px-4 py-3">
                          <span className="inline-block px-2 py-0.5 rounded-full text-xs font-semibold bg-[#556B2F]/15 text-[#556B2F]">
                            Nécessaire
                          </span>
                        </td>
                      </tr>
                      <tr className="bg-[#FFF8F0]/40">
                        <td className="px-4 py-3 font-mono text-xs text-[#722F37]">
                          vg.consent.v1
                        </td>
                        <td className="px-4 py-3 text-[#1A1A1A]/75">
                          Mémorise votre choix de cookies pour ne pas vous redemander à chaque
                          visite.
                        </td>
                        <td className="px-4 py-3 text-[#1A1A1A]/75 whitespace-nowrap">13 mois</td>
                        <td className="px-4 py-3">
                          <span className="inline-block px-2 py-0.5 rounded-full text-xs font-semibold bg-[#556B2F]/15 text-[#556B2F]">
                            Nécessaire
                          </span>
                        </td>
                      </tr>
                      <tr className="bg-white">
                        <td className="px-4 py-3 font-mono text-xs text-[#722F37]">
                          vg.consent.anonId
                        </td>
                        <td className="px-4 py-3 text-[#1A1A1A]/75">
                          Identifiant aléatoire (sans nom ni email) permettant de prouver que vous
                          avez bien donné votre consentement, en cas de contrôle CNIL.
                        </td>
                        <td className="px-4 py-3 text-[#1A1A1A]/75 whitespace-nowrap">
                          Jusqu'à effacement
                        </td>
                        <td className="px-4 py-3">
                          <span className="inline-block px-2 py-0.5 rounded-full text-xs font-semibold bg-[#556B2F]/15 text-[#556B2F]">
                            Nécessaire
                          </span>
                        </td>
                      </tr>
                      <tr className="bg-[#FFF8F0]/40">
                        <td className="px-4 py-3 font-mono text-xs text-[#722F37]">
                          vg_remember_me
                        </td>
                        <td className="px-4 py-3 text-[#1A1A1A]/75">
                          Si vous cochez « Se souvenir de moi », mémorise votre adresse email et
                          votre prénom pour les pré-remplir au prochain login.{' '}
                          <strong>Ne contient jamais votre mot de passe.</strong>
                        </td>
                        <td className="px-4 py-3 text-[#1A1A1A]/75 whitespace-nowrap">30 jours</td>
                        <td className="px-4 py-3">
                          <span className="inline-block px-2 py-0.5 rounded-full text-xs font-semibold bg-[#D4AF37]/20 text-[#7c5a00]">
                            Fonctionnel
                          </span>
                        </td>
                      </tr>
                      <tr className="bg-white">
                        <td className="px-4 py-3 font-mono text-xs text-[#722F37]">g_state</td>
                        <td className="px-4 py-3 text-[#1A1A1A]/75">
                          Posé par <strong>Google</strong> uniquement si vous activez la « Connexion
                          via Google ». Sans cette activation, aucun cookie Google n'est déposé.
                        </td>
                        <td className="px-4 py-3 text-[#1A1A1A]/75 whitespace-nowrap">
                          Variable (Google)
                        </td>
                        <td className="px-4 py-3">
                          <span className="inline-block px-2 py-0.5 rounded-full text-xs font-semibold bg-[#D4AF37]/20 text-[#7c5a00]">
                            Tiers (Google)
                          </span>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>

                {/* Comment gérer */}
                <div className="bg-[#FFF8F0] border border-[#722F37]/15 rounded-xl p-5 mb-4">
                  <h3 className="font-bold text-[#722F37] mb-2 text-base">
                    Comment changer d'avis ?
                  </h3>
                  <ul className="space-y-1.5 text-sm text-[#1A1A1A]/75 list-disc pl-5">
                    <li>
                      Cliquez sur <strong>« Gérer mes cookies »</strong> en bas de chaque page pour
                      rouvrir le panneau de préférences.
                    </li>
                    <li>
                      Vous pouvez aussi supprimer tous les cookies depuis votre navigateur
                      (paramètres &gt; vie privée &gt; cookies).
                    </li>
                    <li>
                      Votre choix expire automatiquement après 13 mois — nous vous redemanderons
                      votre accord (recommandation CNIL).
                    </li>
                  </ul>
                </div>

                <div className="bg-[#556B2F]/8 border border-[#556B2F]/20 rounded-xl p-5">
                  <h3 className="font-bold text-[#556B2F] mb-2 text-base">Vos droits</h3>
                  <p className="text-sm text-[#1A1A1A]/75 leading-relaxed">
                    Conformément au RGPD, vous avez le droit d'accéder à vos données, de les
                    rectifier, de les effacer, de limiter ou de vous opposer à leur traitement, et
                    de les recevoir dans un format portable. Pour toute demande, contactez-nous à{' '}
                    <a href="mailto:contact@vite-gourmand.fr" className="text-[#722F37] underline">
                      contact@vite-gourmand.fr
                    </a>
                    . Vous pouvez également déposer une réclamation auprès de la{' '}
                    <a
                      href="https://www.cnil.fr"
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-[#722F37] underline"
                    >
                      CNIL
                    </a>
                    {'.'}
                  </p>
                </div>
              </section>

              {/* Sections 5-7 */}
              {[
                {
                  num: '5',
                  title: 'Propriété intellectuelle',
                  content:
                    "L'ensemble des contenus présents sur ce site sont la propriété exclusive de Vite & Gourmand. Toute reproduction est strictement interdite sans autorisation.",
                },
                {
                  num: '6',
                  title: 'Responsabilité',
                  content:
                    "Vite & Gourmand s'efforce d'assurer l'exactitude des informations. Les photos sont présentées à titre indicatif.",
                },
                {
                  num: '7',
                  title: 'Liens hypertextes',
                  content:
                    'Le site peut contenir des liens externes. Vite & Gourmand décline toute responsabilité quant au contenu de ces sites.',
                },
              ].map((section) => (
                <section key={section.num}>
                  <h2 className="text-xl font-bold text-[#1A1A1A] mb-4 pb-2 border-b-2 border-[#D4AF37] flex items-center gap-3">
                    <span className="w-8 h-8 bg-[#722F37] rounded-lg flex items-center justify-center text-white text-sm font-bold">
                      {section.num}
                    </span>
                    {section.title}
                  </h2>
                  <p className="text-[#1A1A1A]/70 leading-relaxed">{section.content}</p>
                </section>
              ))}

              {/* Footer */}
              <div className="bg-[#1A1A1A] text-white rounded-2xl p-6 mt-8">
                <p className="text-sm">
                  <span className="font-semibold text-[#D4AF37]">Dernière mise à jour:</span>{' '}
                  Février 2026
                </p>
              </div>
            </CardContent>
          </Card>
        ) : (
          <Card className="bg-white border-0 shadow-xl rounded-3xl overflow-hidden">
            <CardHeader className="bg-gradient-to-r from-[#FFF8F0] to-white border-b border-[#722F37]/10 py-6 px-5 sm:px-8">
              <CardTitle className="text-xl text-[#1A1A1A] flex items-center gap-3">
                <FileText className="h-6 w-6 text-[#722F37]" />
                Conditions Générales de Vente
              </CardTitle>
            </CardHeader>
            <CardContent className="p-5 sm:p-8 lg:p-10 space-y-10">
              {/* CGV Sections */}
              <section>
                <h2 className="text-xl font-bold text-[#1A1A1A] mb-4 pb-2 border-b-2 border-[#D4AF37] flex items-center gap-3">
                  <span className="w-8 h-8 bg-[#722F37] rounded-lg flex items-center justify-center text-white text-sm font-bold">
                    1
                  </span>{' '}
                  Objet
                </h2>
                <p className="text-[#1A1A1A]/70 leading-relaxed">
                  Les présentes CGV régissent les relations contractuelles entre Vite & Gourmand et
                  ses clients dans le cadre de la vente de prestations traiteur.
                </p>
              </section>

              <section>
                <h2 className="text-xl font-bold text-[#1A1A1A] mb-4 pb-2 border-b-2 border-[#D4AF37] flex items-center gap-3">
                  <span className="w-8 h-8 bg-[#722F37] rounded-lg flex items-center justify-center text-white text-sm font-bold">
                    2
                  </span>{' '}
                  Commandes
                </h2>
                <div className="space-y-4">
                  <p className="text-[#1A1A1A]/70 leading-relaxed">
                    <strong className="text-[#1A1A1A]">2.1</strong> Les commandes sont effectuées
                    via notre site web ou par téléphone.
                  </p>
                  <p className="text-[#1A1A1A]/70 leading-relaxed">
                    <strong className="text-[#1A1A1A]">2.2</strong> La commande n'est définitive
                    qu'après confirmation et réception de l'acompte.
                  </p>
                  <div className="bg-[#D4AF37]/10 rounded-2xl p-6 border border-[#D4AF37]/20">
                    <p className="font-semibold text-[#1A1A1A] mb-3 flex items-center gap-2">
                      <Clock className="h-5 w-5 text-[#D4AF37]" />
                      Délais de commande
                    </p>
                    <ul className="space-y-2 text-[#1A1A1A]/70">
                      <li>• Moins de 20 personnes: 72h minimum</li>
                      <li>• 20 à 50 personnes: 1 semaine minimum</li>
                      <li>• Plus de 50 personnes: 2 semaines minimum</li>
                      <li>• Mariages: 1 mois minimum</li>
                    </ul>
                  </div>
                </div>
              </section>

              <section>
                <h2 className="text-xl font-bold text-[#1A1A1A] mb-4 pb-2 border-b-2 border-[#D4AF37] flex items-center gap-3">
                  <span className="w-8 h-8 bg-[#722F37] rounded-lg flex items-center justify-center text-white text-sm font-bold">
                    3
                  </span>{' '}
                  Prix et paiement
                </h2>
                <div className="space-y-4">
                  <p className="text-[#1A1A1A]/70 leading-relaxed">
                    Les prix sont indiqués en euros TTC. Un devis détaillé est fourni avant toute
                    commande.
                  </p>
                  <div className="bg-[#556B2F]/10 rounded-2xl p-6 border border-[#556B2F]/20">
                    <p className="font-semibold text-[#556B2F] mb-3 flex items-center gap-2">
                      <CreditCard className="h-5 w-5" />
                      Modalités de paiement
                    </p>
                    <ul className="space-y-2 text-[#1A1A1A]/70">
                      <li>• Acompte de 30% à la commande</li>
                      <li>• Solde 7 jours avant la prestation</li>
                      <li>• CB, virement, chèque acceptés</li>
                    </ul>
                  </div>
                </div>
              </section>

              <section>
                <h2 className="text-xl font-bold text-[#1A1A1A] mb-4 pb-2 border-b-2 border-[#D4AF37] flex items-center gap-3">
                  <span className="w-8 h-8 bg-[#722F37] rounded-lg flex items-center justify-center text-white text-sm font-bold">
                    4
                  </span>{' '}
                  Livraison
                </h2>
                <div className="bg-[#722F37]/5 rounded-2xl p-6 border border-[#722F37]/10">
                  <p className="font-semibold text-[#722F37] mb-3 flex items-center gap-2">
                    <Truck className="h-5 w-5" />
                    Zone de livraison
                  </p>
                  <ul className="space-y-2 text-[#1A1A1A]/70">
                    <li>• Gironde: livraison incluse jusqu'à 30km</li>
                    <li>• 30 à 50 km: 0.50€/km supplémentaire</li>
                    <li>• Au-delà: sur devis</li>
                  </ul>
                </div>
              </section>

              <section>
                <h2 className="text-xl font-bold text-[#1A1A1A] mb-4 pb-2 border-b-2 border-[#D4AF37] flex items-center gap-3">
                  <span className="w-8 h-8 bg-[#722F37] rounded-lg flex items-center justify-center text-white text-sm font-bold">
                    5
                  </span>{' '}
                  Annulation
                </h2>
                <div className="bg-red-50 rounded-2xl p-6 border border-red-200">
                  <p className="font-semibold text-red-700 mb-3 flex items-center gap-2">
                    <AlertTriangle className="h-5 w-5" />
                    Conditions d'annulation
                  </p>
                  <ul className="space-y-2 text-[#1A1A1A]/70">
                    <li>• +15 jours: remboursement intégral</li>
                    <li>• 8-15 jours: retenue de 30%</li>
                    <li>• 3-7 jours: retenue de 50%</li>
                    <li>• -3 jours: retenue de 80%</li>
                    <li>• Jour même: aucun remboursement</li>
                  </ul>
                </div>
              </section>

              {/* Footer */}
              <div className="bg-[#1A1A1A] text-white rounded-2xl p-6 mt-8">
                <p className="text-sm">
                  <span className="font-semibold text-[#D4AF37]">Dernière mise à jour:</span>{' '}
                  Février 2026
                  <br />
                  <span className="text-white/60">Version applicable au jour de la commande.</span>
                </p>
              </div>
            </CardContent>
          </Card>
        )}
      </div>
    </div>
  );
}
