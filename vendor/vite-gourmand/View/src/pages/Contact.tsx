import { useState, useRef, useCallback, useEffect } from 'react';
import {
  MapPin,
  Phone,
  Mail,
  Clock,
  Send,
  CheckCircle,
  MessageSquare,
  ArrowRight,
  Sparkles,
  User,
  FileText,
  ChevronRight,
  ExternalLink,
  Ticket,
  Bot,
  Wand2,
  ChefHat,
  Wine,
  Heart,
  Building2,
  PartyPopper,
  Baby,
  Loader2,
  Lightbulb,
  Zap,
} from 'lucide-react';
import { Button } from '../components/ui/button';
import { Input } from '../components/ui/input';
import { Label } from '../components/ui/label';
import { usePublicData } from '../contexts/PublicDataContext';
import { apiRequest } from '../services/api';

/* ── Quick-reply suggestions ── */
const QUICK_SUBJECTS = [
  { label: '🎂 Anniversaire', value: 'Devis pour un anniversaire' },
  { label: '💒 Mariage', value: 'Devis pour un mariage' },
  { label: '🏢 Entreprise', value: "Événement d'entreprise" },
  { label: '🍽️ Menu sur mesure', value: 'Demande de menu personnalisé' },
  { label: '❓ Question', value: 'Question générale' },
];

/* ── AI Event Scenario Cards ── */
const AI_SCENARIOS = [
  {
    icon: Heart,
    emoji: '💒',
    title: 'Mariage',
    subtitle: 'Réception & Cocktail',
    prompt: 'Je prépare un mariage et je cherche un traiteur pour la réception.',
    color: '#722F37',
    suggestions: ['Menu gastronomique', 'Bar à cocktails', 'Pièce montée', 'Service en salle'],
  },
  {
    icon: PartyPopper,
    emoji: '🎂',
    title: 'Anniversaire',
    subtitle: 'Fête & Célébration',
    prompt: "J'organise un anniversaire et j'aimerais un buffet ou menu sur mesure.",
    color: '#D4AF37',
    suggestions: ['Buffet varié', 'Gâteau personnalisé', 'Finger food', 'Options enfants'],
  },
  {
    icon: Building2,
    emoji: '🏢',
    title: 'Entreprise',
    subtitle: 'Séminaire & Team building',
    prompt: "J'organise un événement d'entreprise (séminaire, team building, cocktail).",
    color: '#556B2F',
    suggestions: ['Cocktail dînatoire', 'Pauses café', 'Déjeuner assis', 'Buffet debout'],
  },
  {
    icon: Baby,
    emoji: '👶',
    title: 'Baptême',
    subtitle: 'Cérémonie & Réception',
    prompt: 'Je prépare un baptême et je recherche un traiteur pour la réception.',
    color: '#4A90D9',
    suggestions: ['Menu familial', 'Dragées', 'Brunch', 'Desserts variés'],
  },
  {
    icon: ChefHat,
    emoji: '🍽️',
    title: 'Sur mesure',
    subtitle: 'Événement personnalisé',
    prompt: "J'ai un projet d'événement particulier et j'aimerais créer un menu sur mesure.",
    color: '#8B5CF6',
    suggestions: ['Menu signature', 'Chef à domicile', 'Accord mets-vins', 'Expérience unique'],
  },
  {
    icon: Wine,
    emoji: '🍷',
    title: 'Dégustation',
    subtitle: 'Soirée œnologique',
    prompt:
      "J'organise une soirée dégustation de vins avec accords mets et je cherche un traiteur.",
    color: '#B8860B',
    suggestions: ['Accords mets-vins', 'Plateau fromages', 'Tapas premium', 'Sommelier'],
  },
];

function getScenarioSubjectLabel(titleLower: string): string {
  if (titleLower === 'sur mesure') return 'un événement sur mesure';
  if (titleLower === 'entreprise') return "un événement d'entreprise";
  return `un ${titleLower}`;
}

/* ── AI Smart Tips by subject ── */
const SMART_TIPS: Record<string, string[]> = {
  mariage: [
    '💡 Pensez à prévoir les régimes alimentaires de vos invités',
    '🥂 Un cocktail dînatoire en attendant le dîner fait toujours sensation',
    '🍰 Notre pièce montée choux est la préférée de nos mariés',
    '📍 Indiquez le lieu pour adapter la logistique',
  ],
  anniversaire: [
    "💡 Mentionnez l'âge pour adapter l'ambiance du menu",
    '🎵 Nos formules incluent des options animation',
    '🍰 Un gâteau personnalisé est toujours un plus',
    "👶 Précisez s'il y aura des enfants pour des menus adaptés",
  ],
  entreprise: [
    '💡 Précisez le format : assis, debout ou cocktail',
    '☕ Nos pauses café/viennoiseries sont un classique',
    '🥗 Les formules végétariennes sont souvent appréciées en entreprise',
    '🧾 Nous fournissons des factures pour vos notes de frais',
  ],
  default: [
    '💡 Plus votre message est détaillé, plus notre devis sera précis',
    '📅 Indiquez la date, même approximative',
    '👥 Le nombre de convives nous aide à estimer le budget',
    '🥗 Mentionnez les régimes alimentaires ou allergies',
  ],
};

export default function ContactPage() {
  const [formData, setFormData] = useState({
    name: '',
    email: '',
    phone: '',
    subject: '',
    message: '',
  });
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [submitSuccess, setSubmitSuccess] = useState(false);
  const [ticketNumber, setTicketNumber] = useState<string | null>(null);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [focusedField, setFocusedField] = useState<string | null>(null);
  const { siteInfo, workingHours } = usePublicData();
  const formRef = useRef<HTMLFormElement>(null);

  /* ── AI Chat state ─────────────────────────────────────── */
  const [aiMessages, setAiMessages] = useState<{ role: 'user' | 'assistant'; content: string }[]>(
    [],
  );
  const [aiInput, setAiInput] = useState('');
  const [aiConvId, setAiConvId] = useState<string | null>(null);
  const [aiLoading, setAiLoading] = useState(false);
  const [aiOpen, setAiOpen] = useState(false);
  const aiScrollRef = useRef<HTMLDivElement>(null);

  /* ── AI Enhance state ─────────────────────────────────── */
  const [isEnhancing, setIsEnhancing] = useState(false);
  const [activeScenario, setActiveScenario] = useState<string | null>(null);
  const [showSmartTips, setShowSmartTips] = useState(false);
  const [currentTipIndex, setCurrentTipIndex] = useState(0);

  useEffect(() => {
    if (aiScrollRef.current) aiScrollRef.current.scrollTop = aiScrollRef.current.scrollHeight;
  }, [aiMessages, aiLoading]);

  /* ── Smart tips rotation ─────────────────────────────── */
  const getSmartTipsKey = useCallback(() => {
    const subject = formData.subject.toLowerCase();
    if (subject.includes('mariage')) return 'mariage';
    if (subject.includes('anniversaire')) return 'anniversaire';
    if (subject.includes('entreprise') || subject.includes('séminaire')) return 'entreprise';
    return 'default';
  }, [formData.subject]);

  useEffect(() => {
    if (!showSmartTips) return;
    const interval = setInterval(() => {
      const tips = SMART_TIPS[getSmartTipsKey()];
      setCurrentTipIndex((prev) => (prev + 1) % tips.length);
    }, 4000);
    return () => clearInterval(interval);
  }, [showSmartTips, getSmartTipsKey]);

  const sendAiMessage = useCallback(
    async (text?: string) => {
      const msg = text || aiInput.trim();
      if (!msg || aiLoading) return;

      setAiInput('');
      setAiMessages((prev) => [...prev, { role: 'user', content: msg }]);
      setAiLoading(true);

      try {
        const body: Record<string, unknown> = {
          message: msg,
          context: { mode: 'event_planner', page: 'contact' },
        };
        if (aiConvId) body.conversationId = aiConvId;

        const raw = await apiRequest<
          | { data: { conversationId: string; message: string } }
          | { conversationId: string; message: string }
        >('/api/ai-agent/chat', {
          method: 'POST',
          body,
        });
        const res = 'data' in raw ? raw.data : raw;

        setAiConvId(res.conversationId);
        setAiMessages((prev) => [...prev, { role: 'assistant', content: res.message }]);
      } catch {
        setAiMessages((prev) => [
          ...prev,
          { role: 'assistant', content: '⚠️ Erreur de communication. Veuillez réessayer.' },
        ]);
      } finally {
        setAiLoading(false);
      }
    },
    [aiInput, aiLoading, aiConvId],
  );

  /* ── AI Enhance Message ─────────────────────────────────── */
  const enhanceMessage = useCallback(async () => {
    if (!formData.message.trim() || isEnhancing) return;
    setIsEnhancing(true);
    try {
      const enhancePrompt = `Le client a rédigé ce brouillon de message pour une demande de devis traiteur. Reformule-le en un message professionnel, structuré et complet, en gardant toutes les informations originales mais en ajoutant de la clarté et de la structure. Si des informations manquent (date, nombre de convives, budget, allergies), ajoute un petit paragraphe "[À compléter]" à la fin pour rappeler au client de les ajouter. Réponds UNIQUEMENT avec le message amélioré, sans commentaire.

Brouillon du client :
"""
Sujet : ${formData.subject}
${formData.message}
"""`;

      const raw = await apiRequest<
        | { data: { conversationId: string; message: string } }
        | { conversationId: string; message: string }
      >('/api/ai-agent/chat', {
        method: 'POST',
        body: {
          message: enhancePrompt,
          context: { mode: 'event_planner', page: 'contact' },
        },
      });
      const res = 'data' in raw ? raw.data : raw;
      setFormData((prev) => ({ ...prev, message: res.message }));
    } catch {
      // silently fail — keep original message
    } finally {
      setIsEnhancing(false);
    }
  }, [formData.message, formData.subject, isEnhancing]);

  /* ── AI Scenario click handler ──────────────────────────── */
  const handleScenarioClick = useCallback(
    (scenario: (typeof AI_SCENARIOS)[number]) => {
      setActiveScenario(scenario.title);
      const titleLower = scenario.title.toLowerCase();
      const subjectLabel = getScenarioSubjectLabel(titleLower);
      setFormData((prev) => ({
        ...prev,
        subject: prev.subject || `Devis pour ${subjectLabel}`,
      }));
      // Open AI chat and send the scenario prompt
      setAiOpen(true);
      // Small delay so the chat is open before sending
      setTimeout(() => sendAiMessage(scenario.prompt), 100);
    },
    [sendAiMessage],
  );

  const handleSubmit = async (e: React.SubmitEvent) => {
    e.preventDefault();
    setIsSubmitting(true);
    setSubmitError(null);
    try {
      const raw = await apiRequest<
        { data: { id: number; ticket_number: string } } | { id: number; ticket_number: string }
      >('/api/contact', {
        method: 'POST',
        body: {
          name: formData.name,
          email: formData.email,
          phone: formData.phone || undefined,
          title: formData.subject,
          description: formData.message,
        },
      });
      const result = 'data' in raw ? raw.data : raw;
      setTicketNumber(result.ticket_number);
      setSubmitSuccess(true);
      setFormData({ name: '', email: '', phone: '', subject: '', message: '' });
    } catch (err) {
      setSubmitError(
        err instanceof Error ? err.message : 'Une erreur est survenue. Veuillez réessayer.',
      );
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => {
    setFormData((prev) => ({ ...prev, [e.target.name]: e.target.value }));
  };

  const handleQuickSubject = (value: string) => {
    setFormData((prev) => ({ ...prev, subject: value }));
    // Scroll to form if on mobile
    formRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };

  const filledFields = [formData.name, formData.email, formData.subject, formData.message].filter(
    Boolean,
  ).length;
  const progress = (filledFields / 4) * 100;

  return (
    <div className="min-h-screen bg-[#FFF8F0]">
      {/* ═══════════════════════════════════════════════════════════
          Premium Header with depth & decorative elements
          ═══════════════════════════════════════════════════════════ */}
      <header className="relative bg-[#1A1A1A] pt-10 pb-16 sm:pt-14 sm:pb-20 overflow-hidden">
        {/* Decorative background */}
        <div className="absolute inset-0 overflow-hidden">
          <div className="absolute top-0 right-1/4 w-96 h-96 bg-[#722F37]/10 rounded-full blur-3xl -translate-y-1/2" />
          <div className="absolute bottom-0 left-1/3 w-80 h-80 bg-[#D4AF37]/6 rounded-full blur-3xl translate-y-1/2" />
          <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 w-[500px] h-[500px] border border-white/[0.02] rounded-full" />
          <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 w-[350px] h-[350px] border border-white/[0.03] rounded-full" />
        </div>

        <div className="relative max-w-5xl mx-auto px-4 sm:px-6">
          <div className="text-center">
            {/* Decorative line + badge */}
            <div className="flex items-center justify-center gap-4 mb-6">
              <div className="w-12 sm:w-20 h-px bg-gradient-to-r from-transparent to-[#D4AF37]/60" />
              <div className="inline-flex items-center gap-2 bg-gradient-to-r from-[#722F37] to-[#8B3A42] rounded-full px-5 py-2 shadow-lg shadow-[#722F37]/20">
                <MessageSquare className="h-4 w-4 text-[#D4AF37]" />
                <span className="text-[#D4AF37] text-xs font-bold tracking-[0.2em] uppercase">
                  Contact
                </span>
              </div>
              <div className="w-12 sm:w-20 h-px bg-gradient-to-l from-transparent to-[#D4AF37]/60" />
            </div>

            <h1 className="text-4xl sm:text-5xl lg:text-6xl font-black text-white mb-4 tracking-tight">
              Parlons de votre{' '}
              <span className="text-transparent bg-clip-text bg-gradient-to-r from-[#D4AF37] to-[#E8C547]">
                projet
              </span>
            </h1>

            <p className="text-white/75 max-w-xl mx-auto text-sm sm:text-base leading-relaxed mb-8">
              Un événement à organiser, une question sur nos menus ou simplement envie d'échanger ?
              <br className="hidden sm:block" />
              Notre équipe vous répond sous 24 h.
            </p>

            {/* Quick-select subject chips */}
            <div className="flex flex-wrap items-center justify-center gap-2 max-w-2xl mx-auto">
              {QUICK_SUBJECTS.map((qs) => (
                <button
                  key={qs.value}
                  type="button"
                  onClick={() => handleQuickSubject(qs.value)}
                  className={`px-4 py-2 rounded-full text-xs sm:text-sm font-medium transition-all duration-200
                    ${
                      formData.subject === qs.value
                        ? 'bg-[#D4AF37] text-[#1A1A1A] shadow-lg shadow-[#D4AF37]/20 scale-105'
                        : 'bg-white/[0.06] text-white/60 hover:bg-white/[0.12] hover:text-white border border-white/[0.08] hover:border-white/[0.15]'
                    }`}
                >
                  {qs.label}
                </button>
              ))}
            </div>

            {/* Decorative dots */}
            <div className="flex items-center justify-center gap-2 mt-8">
              <div className="w-1.5 h-1.5 rounded-full bg-[#D4AF37]/40" />
              <div className="w-2 h-2 rounded-full bg-[#D4AF37]/60" />
              <div className="w-2.5 h-2.5 rounded-full bg-[#D4AF37]" />
              <div className="w-2 h-2 rounded-full bg-[#D4AF37]/60" />
              <div className="w-1.5 h-1.5 rounded-full bg-[#D4AF37]/40" />
            </div>
          </div>
        </div>
      </header>

      {/* ═══════════════════════════════════════════════════════════
          AI Event Wizard — Scenario Cards
          ═══════════════════════════════════════════════════════════ */}
      <div className="max-w-5xl mx-auto px-4 sm:px-6 -mt-6 sm:-mt-8 relative z-20">
        <div className="bg-white/80 backdrop-blur-sm rounded-2xl border border-[#D4AF37]/20 p-4 sm:p-5 shadow-lg">
          <div className="flex items-center gap-2 mb-3">
            <div className="w-7 h-7 rounded-lg bg-gradient-to-br from-[#D4AF37] to-[#B8960B] flex items-center justify-center">
              <Zap className="h-3.5 w-3.5 text-white" />
            </div>
            <div>
              <h2 className="font-bold text-[#1A1A1A] text-sm">
                <span aria-hidden="true">🪄</span> Assistant IA — Quel est votre événement ?
              </h2>
              <p className="text-[#1A1A1A]/65 text-[10px]">
                Cliquez pour démarrer une conversation guidée avec notre IA
              </p>
            </div>
          </div>

          <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-2">
            {AI_SCENARIOS.map((scenario) => {
              const Icon = scenario.icon;
              const isActive = activeScenario === scenario.title;
              return (
                <button
                  key={scenario.title}
                  type="button"
                  onClick={() => handleScenarioClick(scenario)}
                  className={`group relative flex flex-col items-center gap-1.5 p-3 rounded-xl border transition-all duration-200 text-center ${
                    isActive
                      ? 'border-[#D4AF37] bg-gradient-to-b from-[#D4AF37]/10 to-[#D4AF37]/5 shadow-md scale-[1.02]'
                      : 'border-[#1A1A1A]/5 bg-white hover:border-[#D4AF37]/30 hover:shadow-md hover:scale-[1.02]'
                  }`}
                >
                  <div
                    className={`w-10 h-10 rounded-xl flex items-center justify-center transition-transform group-hover:scale-110 ${isActive ? 'shadow-md' : ''}`}
                    style={{ background: `${scenario.color}15` }}
                  >
                    <Icon className="h-5 w-5" style={{ color: scenario.color }} />
                  </div>
                  <span className="font-bold text-[#1A1A1A] text-xs leading-tight">
                    <span aria-hidden="true">{scenario.emoji}</span> {scenario.title}
                  </span>
                  <span className="text-[9px] text-[#1A1A1A]/65 leading-tight hidden sm:block">
                    {scenario.subtitle}
                  </span>
                  {isActive && (
                    <div className="absolute -top-1 -right-1 w-4 h-4 rounded-full bg-[#556B2F] flex items-center justify-center">
                      <CheckCircle className="h-3 w-3 text-white" />
                    </div>
                  )}
                </button>
              );
            })}
          </div>

          {/* Active scenario suggestions */}
          {activeScenario && (
            <div className="mt-3 flex flex-wrap items-center gap-1.5 animate-in slide-in-from-top-2 duration-200">
              <span className="text-[10px] text-[#1A1A1A]/65 font-medium mr-1">Populaire :</span>
              {AI_SCENARIOS.find((s) => s.title === activeScenario)?.suggestions.map((sug) => (
                <span
                  key={sug}
                  className="text-[10px] px-2 py-0.5 rounded-full bg-[#722F37]/5 text-[#722F37]/70 border border-[#722F37]/10"
                >
                  {sug}
                </span>
              ))}
            </div>
          )}
        </div>
      </div>

      {/* ═══════════════════════════════════════════════════════════
          Content — Form + Sidebar
          ═══════════════════════════════════════════════════════════ */}
      <div className="max-w-5xl mx-auto px-4 sm:px-6 mt-4 sm:mt-5 relative z-10">
        <div className="grid lg:grid-cols-5 gap-6 lg:gap-8">
          {/* ── Contact Form (3 cols) ── */}
          <div className="lg:col-span-3">
            <div className="bg-white rounded-3xl shadow-xl shadow-[#1A1A1A]/8 border border-[#1A1A1A]/5 overflow-hidden">
              {/* Form header with progress */}
              <div className="bg-gradient-to-r from-[#FFF8F0] to-white px-6 sm:px-8 py-5 border-b border-[#1A1A1A]/5">
                <div className="flex items-center justify-between mb-3">
                  <div className="flex items-center gap-3">
                    <div className="w-10 h-10 rounded-xl bg-[#722F37]/10 flex items-center justify-center">
                      <Send className="h-5 w-5 text-[#722F37]" />
                    </div>
                    <div>
                      <h2 className="font-bold text-[#1A1A1A] text-base">
                        Envoyez-nous un message
                      </h2>
                      <p className="text-[#1A1A1A]/65 text-xs">
                        Tous les champs marqués * sont obligatoires
                      </p>
                    </div>
                  </div>
                  <div className="hidden sm:flex items-center gap-2">
                    <span className="text-[10px] text-[#1A1A1A]/65 font-medium uppercase tracking-wide">
                      {filledFields}/4
                    </span>
                    <div className="w-20 h-1.5 rounded-full bg-[#1A1A1A]/5 overflow-hidden">
                      <div
                        className="h-full rounded-full bg-gradient-to-r from-[#722F37] to-[#D4AF37] transition-all duration-500 ease-out"
                        style={{ width: `${progress}%` }}
                      />
                    </div>
                  </div>
                </div>
              </div>

              <div className="p-6 sm:p-8">
                {/* Success banner with ticket number */}
                {submitSuccess && (
                  <div className="mb-6 bg-gradient-to-r from-[#556B2F]/10 to-[#556B2F]/5 border border-[#556B2F]/20 rounded-2xl p-5 animate-in slide-in-from-top-2 duration-300">
                    <div className="flex items-start gap-4 mb-4">
                      <div className="w-10 h-10 rounded-full bg-[#556B2F]/15 flex items-center justify-center shrink-0">
                        <CheckCircle className="h-5 w-5 text-[#556B2F]" />
                      </div>
                      <div>
                        <p className="font-bold text-[#1A1A1A] text-sm">
                          Message envoyé avec succès !
                        </p>
                        <p className="text-[#1A1A1A]/65 text-xs mt-0.5">
                          Un email de confirmation vous a été envoyé.
                        </p>
                      </div>
                    </div>
                    {ticketNumber && (
                      <div className="bg-white rounded-xl border border-[#D4AF37]/30 p-4 flex items-center gap-4">
                        <div className="w-10 h-10 rounded-xl bg-[#D4AF37]/10 flex items-center justify-center shrink-0">
                          <Ticket className="h-5 w-5 text-[#D4AF37]" />
                        </div>
                        <div>
                          <p className="text-[10px] text-[#1A1A1A]/65 uppercase tracking-wider font-semibold">
                            Votre numéro de ticket
                          </p>
                          <p className="font-black text-lg text-[#1A1A1A] tracking-wide">
                            {ticketNumber}
                          </p>
                        </div>
                      </div>
                    )}
                    <p className="text-xs text-[#1A1A1A]/65 mt-3">
                      Conservez ce numéro pour suivre votre demande. Nous vous répondrons sous 24 –
                      48 h.
                    </p>
                    <button
                      type="button"
                      onClick={() => {
                        setSubmitSuccess(false);
                        setTicketNumber(null);
                      }}
                      className="mt-3 text-xs text-[#722F37] hover:text-[#722F37]/80 font-semibold underline underline-offset-2"
                    >
                      Envoyer un nouveau message
                    </button>
                  </div>
                )}

                {/* Error banner */}
                {submitError && (
                  <div className="mb-6 flex items-start gap-4 bg-red-50 border border-red-200 rounded-2xl p-5">
                    <div className="w-10 h-10 rounded-full bg-red-100 flex items-center justify-center shrink-0">
                      <span className="text-red-500 text-lg">✕</span>
                    </div>
                    <div>
                      <p className="font-bold text-red-800 text-sm">Erreur lors de l'envoi</p>
                      <p className="text-red-600 text-xs mt-0.5">{submitError}</p>
                    </div>
                  </div>
                )}

                <form ref={formRef} onSubmit={handleSubmit} className="space-y-5">
                  {/* Name + Email side by side */}
                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <div
                      className={`relative transition-all duration-200 ${focusedField === 'name' ? 'scale-[1.01]' : ''}`}
                    >
                      <Label
                        htmlFor="name"
                        className="text-[#1A1A1A] font-semibold text-sm flex items-center gap-1.5 mb-2"
                      >
                        <User className="h-3.5 w-3.5 text-[#722F37]" />
                        Votre nom <span className="text-red-400 text-xs">*</span>
                      </Label>
                      <Input
                        id="name"
                        name="name"
                        value={formData.name}
                        onChange={handleChange}
                        onFocus={() => setFocusedField('name')}
                        onBlur={() => setFocusedField(null)}
                        placeholder="Jean Dupont"
                        required
                        className="h-12 border-[#1A1A1A]/8 focus-visible:ring-[#722F37] bg-[#FFF8F0]/50 hover:border-[#722F37]/30 transition-colors rounded-xl"
                      />
                    </div>
                    <div
                      className={`relative transition-all duration-200 ${focusedField === 'email' ? 'scale-[1.01]' : ''}`}
                    >
                      <Label
                        htmlFor="email"
                        className="text-[#1A1A1A] font-semibold text-sm flex items-center gap-1.5 mb-2"
                      >
                        <Mail className="h-3.5 w-3.5 text-[#D4AF37]" />
                        Votre email <span className="text-red-400 text-xs">*</span>
                      </Label>
                      <Input
                        id="email"
                        name="email"
                        type="email"
                        value={formData.email}
                        onChange={handleChange}
                        onFocus={() => setFocusedField('email')}
                        onBlur={() => setFocusedField(null)}
                        placeholder="jean@exemple.fr"
                        required
                        className="h-12 border-[#1A1A1A]/8 focus-visible:ring-[#722F37] bg-[#FFF8F0]/50 hover:border-[#722F37]/30 transition-colors rounded-xl"
                      />
                    </div>
                  </div>

                  {/* Phone (optional) */}
                  <div
                    className={`relative transition-all duration-200 ${focusedField === 'phone' ? 'scale-[1.01]' : ''}`}
                  >
                    <Label
                      htmlFor="phone"
                      className="text-[#1A1A1A] font-semibold text-sm flex items-center gap-1.5 mb-2"
                    >
                      <Phone className="h-3.5 w-3.5 text-[#556B2F]" />
                      Téléphone{' '}
                      <span className="text-[#1A1A1A]/65 text-xs font-normal">(optionnel)</span>
                    </Label>
                    <Input
                      id="phone"
                      name="phone"
                      type="tel"
                      value={formData.phone}
                      onChange={handleChange}
                      onFocus={() => setFocusedField('phone')}
                      onBlur={() => setFocusedField(null)}
                      placeholder="06 12 34 56 78"
                      className="h-12 border-[#1A1A1A]/8 focus-visible:ring-[#722F37] bg-[#FFF8F0]/50 hover:border-[#722F37]/30 transition-colors rounded-xl"
                    />
                  </div>

                  {/* Subject */}
                  <div
                    className={`relative transition-all duration-200 ${focusedField === 'subject' ? 'scale-[1.01]' : ''}`}
                  >
                    <Label
                      htmlFor="subject"
                      className="text-[#1A1A1A] font-semibold text-sm flex items-center gap-1.5 mb-2"
                    >
                      <FileText className="h-3.5 w-3.5 text-[#722F37]" />
                      Sujet <span className="text-red-400 text-xs">*</span>
                    </Label>
                    <Input
                      id="subject"
                      name="subject"
                      value={formData.subject}
                      onChange={handleChange}
                      onFocus={() => setFocusedField('subject')}
                      onBlur={() => setFocusedField(null)}
                      placeholder="Ex : Demande de devis pour un mariage"
                      required
                      className="h-12 border-[#1A1A1A]/8 focus-visible:ring-[#722F37] bg-[#FFF8F0]/50 hover:border-[#722F37]/30 transition-colors rounded-xl"
                    />
                    {formData.subject && (
                      <div className="absolute right-3 top-[38px] w-5 h-5 rounded-full bg-[#556B2F]/10 flex items-center justify-center">
                        <CheckCircle className="h-3 w-3 text-[#556B2F]" />
                      </div>
                    )}
                  </div>

                  {/* Message */}
                  <div
                    className={`relative transition-all duration-200 ${focusedField === 'message' ? 'scale-[1.01]' : ''}`}
                  >
                    <div className="flex items-center justify-between mb-2">
                      <Label
                        htmlFor="message"
                        className="text-[#1A1A1A] font-semibold text-sm flex items-center gap-1.5"
                      >
                        <MessageSquare className="h-3.5 w-3.5 text-[#D4AF37]" />
                        Votre message <span className="text-red-400 text-xs">*</span>
                      </Label>
                      {/* AI Enhance button */}
                      {formData.message.length > 20 && (
                        <button
                          type="button"
                          onClick={enhanceMessage}
                          disabled={isEnhancing}
                          className="flex items-center gap-1.5 text-[10px] font-semibold px-2.5 py-1 rounded-full bg-gradient-to-r from-[#D4AF37]/10 to-[#D4AF37]/5 border border-[#D4AF37]/20 text-[#D4AF37] hover:from-[#D4AF37]/20 hover:to-[#D4AF37]/10 transition-all disabled:opacity-50"
                        >
                          {isEnhancing ? (
                            <>
                              <Loader2 className="h-3 w-3 animate-spin" />
                              Amélioration…
                            </>
                          ) : (
                            <>
                              <Wand2 className="h-3 w-3" />✨ Améliorer avec l'IA
                            </>
                          )}
                        </button>
                      )}
                    </div>
                    <textarea
                      id="message"
                      name="message"
                      value={formData.message}
                      onChange={(e) => {
                        handleChange(e);
                        if (e.target.value.length > 5 && !showSmartTips) setShowSmartTips(true);
                      }}
                      onFocus={() => {
                        setFocusedField('message');
                        if (formData.message.length > 5) setShowSmartTips(true);
                      }}
                      onBlur={() => {
                        setFocusedField(null);
                        setTimeout(() => setShowSmartTips(false), 300);
                      }}
                      placeholder="Décrivez votre projet, le nombre d'invités, vos préférences alimentaires, votre budget…"
                      required
                      rows={6}
                      className="flex w-full rounded-xl border border-[#1A1A1A]/8 bg-[#FFF8F0]/50 px-4 py-3 text-sm placeholder:text-[#1A1A1A]/65 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#722F37] focus-visible:ring-offset-2 resize-none hover:border-[#722F37]/30 transition-colors"
                    />

                    {/* AI Smart Tips */}
                    {showSmartTips && (
                      <div className="mt-2 flex items-start gap-2 p-2.5 bg-gradient-to-r from-[#D4AF37]/5 to-transparent border border-[#D4AF37]/10 rounded-lg animate-in slide-in-from-bottom-1 duration-200">
                        <Lightbulb className="h-3.5 w-3.5 text-[#D4AF37] shrink-0 mt-0.5" />
                        <p className="text-[11px] text-[#5c5c5c] leading-relaxed transition-opacity duration-300">
                          {SMART_TIPS[getSmartTipsKey()][currentTipIndex]}
                        </p>
                      </div>
                    )}

                    <div className="flex items-center justify-between mt-1.5">
                      <p className="text-[10px] text-[#1A1A1A]/65">
                        <span aria-hidden="true">💡</span> Soyez aussi précis que possible pour un devis plus rapide
                      </p>
                      <p className="text-[10px] text-[#1A1A1A]/65">
                        {formData.message.length} car.
                      </p>
                    </div>
                  </div>

                  {/* Submit button */}
                  <div className="pt-2">
                    <Button
                      type="submit"
                      size="lg"
                      className="w-full h-13 sm:h-12 text-base font-bold shadow-lg shadow-[#722F37]/15 hover:shadow-xl hover:shadow-[#722F37]/25 transition-all rounded-xl"
                      disabled={isSubmitting}
                    >
                      {isSubmitting ? (
                        <>
                          <div className="animate-spin rounded-full h-4 w-4 border-2 border-white border-t-transparent mr-2" />
                          Envoi en cours…
                        </>
                      ) : (
                        <>
                          <Send className="h-4 w-4 mr-2" />
                          Envoyer le message
                          <ArrowRight className="h-4 w-4 ml-2 opacity-60" />
                        </>
                      )}
                    </Button>
                    <p className="text-center text-[10px] text-[#1A1A1A]/65 mt-3">
                      Vos données sont utilisées uniquement pour répondre à votre demande.
                    </p>
                  </div>
                </form>
              </div>
            </div>
          </div>

          {/* ── Sidebar info (2 cols) ── */}
          <div className="lg:col-span-2 space-y-5">
            {/* Quick contact card — with glassmorphism */}
            <div className="bg-white rounded-3xl shadow-xl shadow-[#1A1A1A]/8 border border-[#1A1A1A]/5 overflow-hidden">
              <div className="bg-gradient-to-r from-[#722F37] to-[#8B3A42] px-5 py-4">
                <h2 className="font-bold text-white text-sm uppercase tracking-wider flex items-center gap-2">
                  <Sparkles className="h-4 w-4 text-[#D4AF37]" />
                  Coordonnées
                </h2>
                <p className="text-white/75 text-xs mt-0.5">Contactez-nous directement</p>
              </div>

              <div className="p-5 space-y-1">
                <a
                  href={`tel:${siteInfo?.phone || '+33556000000'}`}
                  className="flex items-center gap-4 group p-3 rounded-xl hover:bg-[#722F37]/5 transition-all duration-200"
                >
                  <div className="w-11 h-11 rounded-xl bg-gradient-to-br from-[#722F37]/10 to-[#722F37]/5 flex items-center justify-center shrink-0 group-hover:scale-110 group-hover:shadow-md transition-all">
                    <Phone className="h-5 w-5 text-[#722F37]" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <p className="font-bold text-[#1A1A1A] text-sm group-hover:text-[#722F37] transition-colors">
                      {siteInfo?.phone || '05 56 00 00 00'}
                    </p>
                    <p className="text-[#1A1A1A]/65 text-xs">Lun – Ven, 9 h – 18 h</p>
                  </div>
                  <ChevronRight className="h-4 w-4 text-[#1A1A1A]/15 group-hover:text-[#722F37]/50 transition-colors shrink-0" />
                </a>

                <a
                  href={`mailto:${siteInfo?.email || 'contact@vite-gourmand.fr'}`}
                  className="flex items-center gap-4 group p-3 rounded-xl hover:bg-[#D4AF37]/5 transition-all duration-200"
                >
                  <div className="w-11 h-11 rounded-xl bg-gradient-to-br from-[#D4AF37]/10 to-[#D4AF37]/5 flex items-center justify-center shrink-0 group-hover:scale-110 group-hover:shadow-md transition-all">
                    <Mail className="h-5 w-5 text-[#D4AF37]" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <p className="font-bold text-[#1A1A1A] text-sm group-hover:text-[#722F37] transition-colors truncate">
                      {siteInfo?.email || 'contact@vite-gourmand.fr'}
                    </p>
                    <p className="text-[#1A1A1A]/65 text-xs">Réponse sous 24 – 48 h</p>
                  </div>
                  <ChevronRight className="h-4 w-4 text-[#1A1A1A]/15 group-hover:text-[#D4AF37]/50 transition-colors shrink-0" />
                </a>

                <a
                  href={`https://maps.google.com/?q=${encodeURIComponent(siteInfo?.address || '15 Rue Sainte-Catherine 33000 Bordeaux')}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="flex items-center gap-4 group p-3 rounded-xl hover:bg-[#556B2F]/5 transition-all duration-200"
                >
                  <div className="w-11 h-11 rounded-xl bg-gradient-to-br from-[#556B2F]/10 to-[#556B2F]/5 flex items-center justify-center shrink-0 group-hover:scale-110 group-hover:shadow-md transition-all">
                    <MapPin className="h-5 w-5 text-[#556B2F]" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <p className="font-bold text-[#1A1A1A] text-sm group-hover:text-[#722F37] transition-colors">
                      {siteInfo?.address || '15 Rue Sainte-Catherine'}
                    </p>
                    <p className="text-[#1A1A1A]/65 text-xs flex items-center gap-1">
                      Voir sur Google Maps <ExternalLink className="h-2.5 w-2.5" />
                    </p>
                  </div>
                  <ChevronRight className="h-4 w-4 text-[#1A1A1A]/15 group-hover:text-[#556B2F]/50 transition-colors shrink-0" />
                </a>
              </div>
            </div>

            {/* Hours — redesigned with visual indicators */}
            <div className="bg-white rounded-3xl shadow-xl shadow-[#1A1A1A]/8 border border-[#1A1A1A]/5 overflow-hidden">
              <div className="px-5 pt-5 pb-3 flex items-center gap-3">
                <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-[#D4AF37]/10 to-[#D4AF37]/5 flex items-center justify-center">
                  <Clock className="h-5 w-5 text-[#D4AF37]" />
                </div>
                <div>
                  <h2 className="font-bold text-[#1A1A1A] text-sm">Horaires d'ouverture</h2>
                  <p className="text-[#1A1A1A]/65 text-xs">Service traiteur & accueil</p>
                </div>
              </div>
              <div className="px-5 pb-5">
                <div className="bg-[#FFF8F0] rounded-xl p-4 space-y-0.5">
                  {workingHours.length > 0
                    ? workingHours.map((row) => {
                        const isClosed = row.opening === row.closing || row.opening === 'Fermé';
                        return (
                          <div
                            key={row.day}
                            className={`flex justify-between items-center py-2.5 px-3 rounded-lg transition-colors ${isClosed ? 'bg-red-50/70' : 'hover:bg-white/60'}`}
                          >
                            <div className="flex items-center gap-2">
                              <div
                                className={`w-2 h-2 rounded-full ${isClosed ? 'bg-red-400' : 'bg-[#556B2F]'}`}
                              />
                              <span className="text-[#1A1A1A]/80 text-sm">{row.day}</span>
                            </div>
                            <span
                              className={`font-semibold text-sm ${isClosed ? 'text-red-700' : 'text-[#1A1A1A]'}`}
                            >
                              {isClosed ? 'Fermé' : `${row.opening} – ${row.closing}`}
                            </span>
                          </div>
                        );
                      })
                    : [
                        { day: 'Lundi – Vendredi', time: '9 h – 18 h', open: true },
                        { day: 'Samedi', time: '10 h – 16 h', open: true },
                        { day: 'Dimanche', time: 'Fermé', open: false },
                      ].map((row) => (
                        <div
                          key={row.day}
                          className={`flex justify-between items-center py-2.5 px-3 rounded-lg transition-colors ${row.open ? 'hover:bg-white/60' : 'bg-red-50/70'}`}
                        >
                          <div className="flex items-center gap-2">
                            <div
                              className={`w-2 h-2 rounded-full ${row.open ? 'bg-[#556B2F]' : 'bg-red-400'}`}
                            />
                            <span className="text-[#1A1A1A]/80 text-sm">{row.day}</span>
                          </div>
                          <span
                            className={`font-semibold text-sm ${row.open ? 'text-[#1A1A1A]' : 'text-red-700'}`}
                          >
                            {row.time}
                          </span>
                        </div>
                      ))}
                </div>
              </div>
            </div>

            {/* AI Event Concierge — interactive chat widget */}
            <div className="bg-white rounded-3xl shadow-xl shadow-[#1A1A1A]/8 border border-[#D4AF37]/20 overflow-hidden">
              {/* Header */}
              <button
                type="button"
                onClick={() => setAiOpen((o) => !o)}
                className="w-full bg-gradient-to-br from-[#722F37] via-[#8B3A42] to-[#722F37] p-5 text-white text-left relative overflow-hidden"
              >
                <div className="absolute top-0 right-0 w-32 h-32 bg-white/5 rounded-full -translate-y-1/2 translate-x-1/2" />
                <div className="absolute bottom-0 left-0 w-24 h-24 bg-[#D4AF37]/10 rounded-full translate-y-1/2 -translate-x-1/2" />
                <div className="relative flex items-center justify-between">
                  <div className="flex items-center gap-3">
                    <div className="w-9 h-9 rounded-xl bg-[#D4AF37]/20 flex items-center justify-center relative">
                      <Sparkles className="h-4 w-4 text-[#D4AF37]" />
                      <span className="absolute -top-1 -right-1 w-2.5 h-2.5 rounded-full bg-[#556B2F] border-2 border-[#722F37] animate-pulse" />
                    </div>
                    <div>
                      <h3 className="font-bold text-sm"><span aria-hidden="true">🪄</span> Concierge Événementiel IA</h3>
                      <p className="text-white/75 text-[11px] mt-0.5">
                        Planifiez • Inspirez-vous • Demandez un devis
                      </p>
                    </div>
                  </div>
                  <div
                    className={`w-6 h-6 rounded-full bg-white/10 flex items-center justify-center transition-transform ${aiOpen ? 'rotate-180' : ''}`}
                  >
                    <ArrowRight className="h-3 w-3 text-white rotate-90" />
                  </div>
                </div>
                {!aiOpen && (
                  <div className="relative flex items-center gap-2 mt-3 text-[#D4AF37] text-[10px] font-semibold">
                    <span className="bg-[#D4AF37]/10 px-2.5 py-1 rounded-full">✓ Gratuit</span>
                    <span className="bg-[#D4AF37]/10 px-2.5 py-1 rounded-full">
                      ✓ Aide au devis
                    </span>
                    <span className="bg-[#D4AF37]/10 px-2.5 py-1 rounded-full">✓ Sur mesure</span>
                  </div>
                )}
              </button>

              {/* Chat body */}
              {aiOpen && (
                <div className="flex flex-col" style={{ height: 420 }}>
                  {/* Messages */}
                  <div
                    ref={aiScrollRef}
                    className="flex-1 overflow-y-auto p-4 space-y-3 bg-[#faf8f6]"
                  >
                    {aiMessages.length === 0 && !aiLoading && (
                      <div className="text-center py-4">
                        <div className="w-12 h-12 rounded-2xl bg-gradient-to-br from-[#D4AF37]/20 to-[#722F37]/10 flex items-center justify-center mx-auto mb-3">
                          <Bot className="h-6 w-6 text-[#D4AF37]" />
                        </div>
                        <p className="font-semibold text-[#1A1A1A] text-xs mb-1">
                          Comment puis-je vous aider ?
                        </p>
                        <p className="text-[10px] text-[#1A1A1A]/65 leading-relaxed max-w-[240px] mx-auto mb-4">
                          Je vous aide à planifier votre événement, choisir le menu idéal et
                          préparer votre demande de devis.
                        </p>
                        <div className="space-y-1.5">
                          {[
                            {
                              icon: '💒',
                              text: 'Planifier un mariage',
                              prompt:
                                'Je prépare un mariage et je cherche un traiteur pour la réception.',
                            },
                            {
                              icon: '🎂',
                              text: 'Organiser un anniversaire',
                              prompt: "J'organise un anniversaire et j'aimerais un buffet ou menu.",
                            },
                            {
                              icon: '🏢',
                              text: "Événement d'entreprise",
                              prompt: "J'organise un événement d'entreprise.",
                            },
                            {
                              icon: '🍽️',
                              text: 'Menu sur mesure',
                              prompt: "J'aimerais créer un menu personnalisé pour un événement.",
                            },
                            {
                              icon: '💰',
                              text: 'Connaître vos tarifs',
                              prompt: 'Quels sont vos tarifs et formules disponibles ?',
                            },
                          ].map((q) => (
                            <button
                              key={q.text}
                              type="button"
                              onClick={() => sendAiMessage(q.prompt)}
                              className="w-full flex items-center gap-2.5 text-left text-[11px] px-3 py-2 rounded-xl border border-[#D4AF37]/15 text-[#1A1A1A]/70 hover:bg-[#722F37]/5 hover:border-[#722F37]/20 hover:text-[#722F37] transition-all"
                            >
                              <span className="text-sm">{q.icon}</span>
                              <span className="font-medium">{q.text}</span>
                              <ChevronRight className="h-3 w-3 ml-auto opacity-30" />
                            </button>
                          ))}
                        </div>
                      </div>
                    )}

                    {aiMessages.map((msg, i) => (
                      <div
                        key={`${msg.role}-${i}-${msg.content.slice(0, 20)}`}
                        className={`flex ${msg.role === 'user' ? 'justify-end' : 'justify-start'}`}
                      >
                        <div className="max-w-[85%]">
                          <div
                            className={`rounded-2xl px-3.5 py-2.5 text-[13px] leading-relaxed ${
                              msg.role === 'user'
                                ? 'bg-gradient-to-br from-[#722F37] to-[#8B3A42] text-white rounded-br-sm'
                                : 'bg-white border border-[#1A1A1A]/5 text-[#333] rounded-bl-sm shadow-sm'
                            }`}
                            style={{ whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}
                          >
                            {msg.content}
                          </div>
                          {msg.role === 'assistant' && (
                            <button
                              type="button"
                              onClick={() => {
                                setFormData((prev) => ({
                                  ...prev,
                                  subject: prev.subject || 'Demande de menu personnalisé',
                                  message: prev.message
                                    ? prev.message + '\n\n--- Proposition IA ---\n' + msg.content
                                    : msg.content,
                                }));
                                formRef.current?.scrollIntoView({
                                  behavior: 'smooth',
                                  block: 'start',
                                });
                              }}
                              className="mt-1 text-[10px] text-[#722F37] hover:text-[#5f2630] flex items-center gap-1 ml-1 transition-colors"
                            >
                              <ArrowRight className="h-2.5 w-2.5 rotate-[-90deg]" />
                              Copier dans le formulaire
                            </button>
                          )}
                        </div>
                      </div>
                    ))}

                    {aiLoading && (
                      <div className="flex justify-start">
                        <div className="bg-white border border-[#1A1A1A]/5 rounded-2xl rounded-bl-sm px-4 py-3 shadow-sm">
                          <div className="flex gap-1.5 items-center h-4">
                            <div
                              className="w-1.5 h-1.5 rounded-full bg-[#D4AF37] animate-bounce"
                              style={{ animationDelay: '0ms' }}
                            />
                            <div
                              className="w-1.5 h-1.5 rounded-full bg-[#D4AF37] animate-bounce"
                              style={{ animationDelay: '150ms' }}
                            />
                            <div
                              className="w-1.5 h-1.5 rounded-full bg-[#D4AF37] animate-bounce"
                              style={{ animationDelay: '300ms' }}
                            />
                          </div>
                        </div>
                      </div>
                    )}
                  </div>

                  {/* Input */}
                  <div className="border-t border-[#1A1A1A]/5 p-3 bg-white">
                    <div className="flex gap-2">
                      <input
                        type="text"
                        value={aiInput}
                        onChange={(e) => setAiInput(e.target.value)}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter' && !e.shiftKey) {
                            e.preventDefault();
                            sendAiMessage();
                          }
                        }}
                        placeholder="Parlez-moi de votre événement…"
                        className="flex-1 text-sm border border-[#1A1A1A]/8 rounded-xl px-3.5 py-2.5 focus:outline-none focus:ring-2 focus:ring-[#722F37] bg-[#FFF8F0]/50"
                      />
                      <button
                        type="button"
                        onClick={() => sendAiMessage()}
                        disabled={!aiInput.trim() || aiLoading}
                        className="w-10 h-10 rounded-xl flex items-center justify-center shrink-0 transition-colors disabled:opacity-30"
                        style={{ background: aiInput.trim() && !aiLoading ? '#722F37' : '#eee' }}
                      >
                        <Send
                          className="h-4 w-4"
                          style={{ color: aiInput.trim() && !aiLoading ? 'white' : '#999' }}
                        />
                      </button>
                    </div>
                    {aiMessages.length > 0 && (
                      <p className="text-[9px] text-[#1A1A1A]/65 text-center mt-1.5">
                        Les réponses IA sont un copier-coller direct vers le formulaire ↗
                      </p>
                    )}
                  </div>
                </div>
              )}
            </div>

            {/* Trust badges + AI value props */}
            <div className="grid grid-cols-3 gap-3">
              <div className="bg-white rounded-2xl border border-[#1A1A1A]/5 p-4 text-center shadow-sm hover:shadow-md transition-shadow">
                <p className="text-2xl font-black text-[#722F37] mb-0.5">24h</p>
                <p className="text-[9px] text-[#1A1A1A]/65 uppercase tracking-wider font-semibold">
                  Réponse max.
                </p>
              </div>
              <div className="bg-white rounded-2xl border border-[#1A1A1A]/5 p-4 text-center shadow-sm hover:shadow-md transition-shadow">
                <p className="text-2xl font-black text-[#D4AF37] mb-0.5">🤖</p>
                <p className="text-[9px] text-[#1A1A1A]/65 uppercase tracking-wider font-semibold">
                  IA Concierge
                </p>
              </div>
              <div className="bg-white rounded-2xl border border-[#1A1A1A]/5 p-4 text-center shadow-sm hover:shadow-md transition-shadow">
                <p className="text-2xl font-black text-[#556B2F] mb-0.5">5★</p>
                <p className="text-[9px] text-[#1A1A1A]/65 uppercase tracking-wider font-semibold">
                  Service
                </p>
              </div>
            </div>

            {/* AI Explanation mini-card */}
            <div className="bg-gradient-to-br from-[#722F37]/5 to-[#D4AF37]/5 rounded-2xl border border-[#D4AF37]/15 p-4">
              <div className="flex items-start gap-3">
                <div className="w-8 h-8 rounded-lg bg-[#D4AF37]/10 flex items-center justify-center shrink-0 mt-0.5">
                  <Wand2 className="h-4 w-4 text-[#D4AF37]" />
                </div>
                <div>
                  <p className="font-bold text-[#1A1A1A] text-xs mb-1">L'IA à votre service</p>
                  <ul className="space-y-1 text-[10px] text-[#1A1A1A]/65 leading-relaxed">
                    <li className="flex items-center gap-1.5">
                      <span className="w-1 h-1 rounded-full bg-[#D4AF37]" />
                      {' '}Cliquez un type d'événement ci-dessus
                    </li>
                    <li className="flex items-center gap-1.5">
                      <span className="w-1 h-1 rounded-full bg-[#D4AF37]" />
                      {' '}L'IA vous guide pas à pas
                    </li>
                    <li className="flex items-center gap-1.5">
                      <span className="w-1 h-1 rounded-full bg-[#D4AF37]" />
                      {' '}Copiez la proposition dans le formulaire
                    </li>
                    <li className="flex items-center gap-1.5">
                      <span className="w-1 h-1 rounded-full bg-[#D4AF37]" />
                      {' '}Votre message est amélioré ✨
                    </li>
                  </ul>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* ── Bottom spacing ── */}
      <div className="h-16" />
    </div>
  );
}
