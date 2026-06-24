/**
 * AdminAiAgent — AI-powered menu customization chat interface
 *
 * Connects to POST /api/ai-agent/chat for conversational menu building.
 * Helps staff discuss client needs with an AI that knows the full dish catalogue,
 * and generates formatted menu proposals with budget calculations.
 */
import { useState, useEffect, useRef, useCallback } from 'react';
import { apiRequest } from '../../services/api';

/* ── types ─────────────────────────────────────────────────── */

interface Message {
  role: 'user' | 'assistant';
  content: string;
}

interface ChatResponse {
  conversationId: string;
  message: string;
  context: Record<string, unknown>;
  messageCount: number;
}

interface AgentStatus {
  aiEnabled: boolean;
  model: string;
  activeConversations: number;
}

/* ── main component ────────────────────────────────────────── */

export function AdminAiAgent() {
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState('');
  const [conversationId, setConversationId] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [status, setStatus] = useState<AgentStatus | null>(null);

  // Guest count & budget quick-set
  const [guestCount, setGuestCount] = useState<string>('');
  const [budget, setBudget] = useState<string>('');

  const scrollRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  // Auto-scroll to bottom on new messages
  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [messages, loading]);

  // Fetch agent status on mount
  useEffect(() => {
    apiRequest<{ data: AgentStatus } | AgentStatus>('/api/ai-agent/status')
      .then((res) => setStatus('data' in res ? res.data : res))
      .catch(() => setStatus(null));
  }, []);

  const sendMessage = useCallback(
    async (text?: string) => {
      const msg = text || input.trim();
      if (!msg || loading) return;

      setInput('');
      setMessages((prev) => [...prev, { role: 'user', content: msg }]);
      setLoading(true);

      try {
        const body: Record<string, unknown> = {
          message: msg,
        };
        if (conversationId) body.conversationId = conversationId;
        if (guestCount && !conversationId) body.guestCount = Number(guestCount);
        if (budget && !conversationId) body.budgetPerPerson = Number(budget);

        const raw = await apiRequest<{ data: ChatResponse } | ChatResponse>('/api/ai-agent/chat', {
          method: 'POST',
          body,
        });
        const res: ChatResponse = 'data' in raw ? raw.data : raw;

        setConversationId(res.conversationId);
        setMessages((prev) => [...prev, { role: 'assistant', content: res.message }]);
      } catch (err: unknown) {
        const errMsg = err instanceof Error ? err.message : 'Erreur de communication';
        setMessages((prev) => [...prev, { role: 'assistant', content: `⚠️ Erreur: ${errMsg}` }]);
      } finally {
        setLoading(false);
        inputRef.current?.focus();
      }
    },
    [input, loading, conversationId, guestCount, budget],
  );

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  };

  const newConversation = () => {
    setMessages([]);
    setConversationId(null);
    setGuestCount('');
    setBudget('');
  };

  const hasStarted = messages.length > 0;

  return (
    <div
      style={{
        height: '100%',
        display: 'flex',
        flexDirection: 'column',
        background: '#faf8f6',
        borderRadius: 16,
        overflow: 'hidden',
      }}
    >
      {/* ── Header ─────────────────────────────────────────── */}
      <div
        style={{
          background: 'linear-gradient(135deg, #722F37 0%, #8a3a44 60%, #D4AF37 100%)',
          padding: '18px 24px',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
        }}
      >
        <div>
          <h2
            style={{
              margin: 0,
              color: 'white',
              fontSize: 17,
              fontWeight: 700,
              display: 'flex',
              alignItems: 'center',
              gap: 8,
            }}
          >
            🤖 Assistant Menu Personnalisé
          </h2>
          <p style={{ margin: '4px 0 0', color: 'rgba(255,255,255,.7)', fontSize: 12 }}>
            IA pour composer des menus sur mesure — budget, régime, convives
          </p>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          {status && (
            <span
              style={{
                fontSize: 10,
                fontWeight: 700,
                padding: '4px 10px',
                borderRadius: 20,
                background: status.aiEnabled ? 'rgba(85,107,47,.25)' : 'rgba(255,255,255,.15)',
                color: status.aiEnabled ? '#90EE90' : 'rgba(255,255,255,.6)',
              }}
            >
              {status.aiEnabled ? `✅ ${status.model}` : '⚠️ Mode démo'}
            </span>
          )}
          {hasStarted && (
            <button
              type="button"
              onClick={newConversation}
              style={{
                background: 'rgba(255,255,255,.15)',
                border: 'none',
                color: 'white',
                borderRadius: 8,
                padding: '6px 14px',
                cursor: 'pointer',
                fontSize: 12,
                fontWeight: 600,
              }}
            >
              + Nouvelle discussion
            </button>
          )}
        </div>
      </div>

      {/* ── Welcome / Quick Setup ──────────────────────────── */}
      {!hasStarted && (
        <div
          style={{
            padding: 30,
            textAlign: 'center',
            flex: 1,
            display: 'flex',
            flexDirection: 'column',
            justifyContent: 'center',
          }}
        >
          <div style={{ fontSize: 50, marginBottom: 12 }}>🍽️</div>
          <h3 style={{ margin: '0 0 8px', fontSize: 20, fontWeight: 700, color: '#722F37' }}>
            Créer un menu personnalisé
          </h3>
          <p
            style={{
              margin: '0 0 24px',
              fontSize: 14,
              color: '#777',
              maxWidth: 500,
              marginInline: 'auto',
              lineHeight: 1.6,
            }}
          >
            Décrivez les besoins de votre client et l'IA proposera un menu adapté à partir de notre
            carte, en respectant le budget et les contraintes alimentaires.
          </p>

          {/* Quick params */}
          <div
            style={{
              display: 'flex',
              gap: 12,
              justifyContent: 'center',
              flexWrap: 'wrap',
              marginBottom: 24,
            }}
          >
            <QuickParam
              icon="👥"
              label="Convives"
              value={guestCount}
              onChange={setGuestCount}
              placeholder="ex: 50"
              type="number"
            />
            <QuickParam
              icon="💰"
              label="Budget/pers (€)"
              value={budget}
              onChange={setBudget}
              placeholder="ex: 35"
              type="number"
            />
          </div>

          {/* Quick starters */}
          <div style={{ display: 'flex', gap: 8, justifyContent: 'center', flexWrap: 'wrap' }}>
            {QUICK_STARTERS.map((q) => (
              <button
                type="button"
                key={q.label}
                onClick={() => sendMessage(q.prompt)}
                style={{
                  padding: '10px 18px',
                  borderRadius: 12,
                  border: '1px solid #e8e4e0',
                  background: 'white',
                  cursor: 'pointer',
                  fontSize: 13,
                  fontWeight: 500,
                  color: '#555',
                  transition: 'all .15s',
                  boxShadow: '0 1px 3px rgba(0,0,0,.04)',
                }}
                onMouseEnter={(e) => {
                  e.currentTarget.style.borderColor = '#D4AF37';
                  e.currentTarget.style.color = '#722F37';
                }}
                onMouseLeave={(e) => {
                  e.currentTarget.style.borderColor = '#e8e4e0';
                  e.currentTarget.style.color = '#555';
                }}
              >
                {q.icon} {q.label}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* ── Chat Messages ──────────────────────────────────── */}
      {hasStarted && (
        <div
          ref={scrollRef}
          style={{
            flex: 1,
            overflowY: 'auto',
            padding: '20px 24px',
            display: 'flex',
            flexDirection: 'column',
            gap: 14,
          }}
        >
          {messages.map((msg, i) => (
            <ChatBubble key={`${msg.role}-${i}`} message={msg} />
          ))}

          {loading && (
            <div
              style={{
                alignSelf: 'flex-start',
                background: 'white',
                borderRadius: '16px 16px 16px 4px',
                padding: '14px 20px',
                boxShadow: '0 1px 3px rgba(0,0,0,.06)',
                maxWidth: '80%',
              }}
            >
              <TypingDots />
            </div>
          )}
        </div>
      )}

      {/* ── Input Bar ──────────────────────────────────────── */}
      <div
        style={{
          padding: '14px 20px',
          background: 'white',
          borderTop: '1px solid #eee',
          display: 'flex',
          gap: 10,
          alignItems: 'flex-end',
        }}
      >
        <textarea
          ref={inputRef}
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder="Décrivez les besoins du client… (Entrée pour envoyer)"
          rows={1}
          style={{
            flex: 1,
            resize: 'none',
            border: '1px solid #e0dcd8',
            borderRadius: 12,
            padding: '12px 16px',
            fontSize: 14,
            fontFamily: 'inherit',
            lineHeight: 1.5,
            outline: 'none',
            transition: 'border-color .15s',
            minHeight: 44,
            maxHeight: 120,
            overflow: 'auto',
          }}
          onFocus={(e) => {
            e.currentTarget.style.borderColor = '#D4AF37';
          }}
          onBlur={(e) => {
            e.currentTarget.style.borderColor = '#e0dcd8';
          }}
        />
        <button
          type="button"
          onClick={() => sendMessage()}
          disabled={!input.trim() || loading}
          style={{
            width: 44,
            height: 44,
            borderRadius: 12,
            border: 'none',
            cursor: 'pointer',
            background: input.trim() && !loading ? '#722F37' : '#ddd',
            color: 'white',
            fontSize: 18,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            transition: 'background .15s',
            flexShrink: 0,
          }}
          aria-label="Envoyer"
        >
          ↑
        </button>
      </div>
    </div>
  );
}

/* ═══════════════════════════════════════════════════════════
   Sub-components
   ═══════════════════════════════════════════════════════════ */

function ChatBubble({ message }: Readonly<{ message: Message }>) {
  const isUser = message.role === 'user';
  return (
    <div
      style={{
        alignSelf: isUser ? 'flex-end' : 'flex-start',
        maxWidth: '80%',
      }}
    >
      <div
        style={{
          background: isUser ? 'linear-gradient(135deg, #722F37, #8a3a44)' : 'white',
          color: isUser ? 'white' : '#333',
          borderRadius: isUser ? '16px 16px 4px 16px' : '16px 16px 16px 4px',
          padding: '14px 18px',
          fontSize: 14,
          lineHeight: 1.7,
          boxShadow: '0 1px 3px rgba(0,0,0,.06)',
          whiteSpace: 'pre-wrap',
          wordBreak: 'break-word',
        }}
      >
        <FormattedContent content={message.content} isUser={isUser} />
      </div>
    </div>
  );
}

/** Renders markdown-like formatting (bold, headers, lists) */
function FormattedContent({ content, isUser }: Readonly<{ content: string; isUser: boolean }>) {
  if (isUser) return <>{content}</>;

  // Split by lines and render with basic formatting
  const lines = content.split('\n');
  return (
    <>
      {lines.map((line, i) => {
        const key = `line-${i}`;

        // Headers / decorative lines
        if (line.startsWith('═') || line.startsWith('───')) {
          return (
            <hr
              key={key}
              style={{ border: 'none', borderTop: '1px solid #e8e4e0', margin: '8px 0' }}
            />
          );
        }

        // Empty line
        if (!line.trim()) {
          return <div key={key} style={{ height: 8 }} />;
        }

        // Blockquote (> text)
        if (line.startsWith('> ')) {
          return (
            <div
              key={key}
              style={{
                borderLeft: '3px solid #D4AF37',
                paddingLeft: 12,
                margin: '6px 0',
                fontSize: 12,
                color: '#888',
                fontStyle: 'italic',
              }}
            >
              {renderInlineFormatting(line.substring(2))}
            </div>
          );
        }

        // Numbered list
        if (/^\d+\.\s/.test(line)) {
          return (
            <div key={key} style={{ paddingLeft: 8, margin: '3px 0' }}>
              {renderInlineFormatting(line)}
            </div>
          );
        }

        // Bullet with emoji or dash
        if (
          /^[-•]\s/.test(line) ||
          /^(?:[\u{1F300}-\u{1FAFF}]|\u2705|\u2728|\u26A0\uFE0F)/u.test(line)
        ) {
          return (
            <div key={key} style={{ paddingLeft: 4, margin: '3px 0' }}>
              {renderInlineFormatting(line)}
            </div>
          );
        }

        return (
          <div key={key} style={{ margin: '2px 0' }}>
            {renderInlineFormatting(line)}
          </div>
        );
      })}
    </>
  );
}

function renderInlineFormatting(text: string) {
  return text.split(/(\*\*.+?\*\*)/g).map((part, index) => {
    if (part.startsWith('**') && part.endsWith('**')) {
      return <b key={`${part}-${index}`}>{part.slice(2, -2)}</b>;
    }
    return <span key={`${part}-${index}`}>{part}</span>;
  });
}

function QuickParam({
  icon,
  label,
  value,
  onChange,
  placeholder,
  type,
}: Readonly<{
  icon: string;
  label: string;
  value: string;
  onChange: (v: string) => void;
  placeholder: string;
  type: string;
}>) {
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 8,
        background: 'white',
        borderRadius: 12,
        border: '1px solid #e8e4e0',
        padding: '8px 14px',
        minWidth: 160,
      }}
    >
      <span style={{ fontSize: 18 }}>{icon}</span>
      <div style={{ flex: 1 }}>
        <label
          style={{
            fontSize: 10,
            color: '#999',
            fontWeight: 600,
            textTransform: 'uppercase',
            letterSpacing: 0.5,
            display: 'block',
          }}
        >
          {label}
        </label>
        <input
          type={type}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder={placeholder}
          style={{
            border: 'none',
            outline: 'none',
            fontSize: 14,
            fontWeight: 600,
            width: '100%',
            color: '#333',
            background: 'transparent',
          }}
        />
      </div>
    </div>
  );
}

function TypingDots() {
  return (
    <div style={{ display: 'flex', gap: 5, alignItems: 'center', height: 20 }}>
      {[0, 1, 2].map((i) => (
        <div
          key={i}
          style={{
            width: 8,
            height: 8,
            borderRadius: '50%',
            background: '#bbb',
            animation: `typing-bounce 1.2s ease-in-out ${i * 0.15}s infinite`,
          }}
        />
      ))}
      <style>{`
        @keyframes typing-bounce {
          0%, 80%, 100% { transform: translateY(0); opacity: .4; }
          40% { transform: translateY(-6px); opacity: 1; }
        }
      `}</style>
    </div>
  );
}

/* ── constants ────────────────────────────────────────────── */

const QUICK_STARTERS = [
  {
    icon: '🎉',
    label: 'Anniversaire',
    prompt: "Je cherche un menu pour un anniversaire. Qu'est-ce que vous proposez ?",
  },
  {
    icon: '💍',
    label: 'Mariage',
    prompt: 'Je dois préparer un menu de mariage. Quelles sont les options disponibles ?',
  },
  {
    icon: '🏢',
    label: 'Séminaire',
    prompt:
      "Je cherche un menu pour un séminaire d'entreprise, quelque chose de professionnel mais convivial.",
  },
  {
    icon: '🥗',
    label: 'Végétarien',
    prompt: "Mon client a besoin d'un menu entièrement végétarien. Que pouvez-vous proposer ?",
  },
  {
    icon: '💰',
    label: 'Petit budget',
    prompt:
      "J'ai un client avec un budget serré, environ 20€ par personne. Quelles options avons-nous ?",
  },
];
