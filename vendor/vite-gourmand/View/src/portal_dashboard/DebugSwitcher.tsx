/**
 * Debug Switcher Component
 * Floating panel for superadmin to switch between bot views
 */

import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { usePortalAuth } from './PortalAuthContext';
import { DEBUG_BOTS, type BotId, type DashboardUser } from './types';
import './DebugSwitcher.css';

export function DebugSwitcher() {
  const { user } = usePortalAuth();
  const [isOpen, setIsOpen] = useState(false);
  const [activeBot, setActiveBot] = useState<BotId | null>(null);
  const navigate = useNavigate();

  // Only show for superadmin
  if (user?.role !== 'superadmin') return null;

  const handleBotSelect = (botId: BotId) => {
    const bot = DEBUG_BOTS[botId];
    setActiveBot(botId);
    navigateToBot(bot, navigate);
  };

  const handleExitDebug = () => {
    setActiveBot(null);
    navigate('/dev');
  };

  return (
    <div className="debug-switcher">
      <button className="debug-toggle" onClick={() => setIsOpen(!isOpen)} title="Debug Mode">
        🔧
      </button>

      {isOpen && (
        <DebugPanel
          activeBot={activeBot}
          onSelect={handleBotSelect}
          onExit={handleExitDebug}
          onClose={() => setIsOpen(false)}
        />
      )}
    </div>
  );
}

interface DebugPanelProps {
  activeBot: BotId | null;
  onSelect: (botId: BotId) => void;
  onExit: () => void;
  onClose: () => void;
}

function DebugPanel({ activeBot, onSelect, onExit, onClose }: Readonly<DebugPanelProps>) {
  const bots = Object.entries(DEBUG_BOTS) as [BotId, DashboardUser][];

  return (
    <div className="debug-panel">
      <header className="debug-panel-header">
        <span>🔧 Debug Mode</span>
        <button onClick={onClose}>✕</button>
      </header>

      <div className="debug-panel-body">
        <p className="debug-hint">View as different roles:</p>

        {bots.map(([id, bot]) => (
          <BotButton key={id} bot={bot} isActive={activeBot === id} onClick={() => onSelect(id)} />
        ))}
      </div>

      {activeBot && (
        <footer className="debug-panel-footer">
          <button className="debug-exit" onClick={onExit}>
            ← Back to Superadmin
          </button>
        </footer>
      )}
    </div>
  );
}

interface BotButtonProps {
  bot: DashboardUser;
  isActive: boolean;
  onClick: () => void;
}

function BotButton({ bot, isActive, onClick }: Readonly<BotButtonProps>) {
  const icons: Record<string, string> = {
    admin: '👔',
    employee: '👷',
    customer: '👤',
  };

  return (
    <button className={`debug-bot ${isActive ? 'active' : ''}`} onClick={onClick}>
      <span className="debug-bot-icon">{icons[bot.role]}</span>
      <span className="debug-bot-info">
        <span className="debug-bot-name">{bot.name}</span>
        <span className="debug-bot-role">{bot.role}</span>
      </span>
    </button>
  );
}

function navigateToBot(bot: DashboardUser, navigate: ReturnType<typeof useNavigate>) {
  switch (bot.role) {
    case 'admin':
      navigate('/admin');
      break;
    case 'employee':
      navigate('/employee');
      break;
    case 'customer':
      // Customer can't access dashboard, show unauthorized
      navigate('/unauthorized');
      break;
  }
}
