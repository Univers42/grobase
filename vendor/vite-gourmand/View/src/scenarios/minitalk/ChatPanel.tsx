/**
 * Chat Component for Minitalk
 */

import React, { useState } from 'react';
import type { MinitalkMessage } from './types';
import './ChatPanel.css';

interface Props {
  messages: MinitalkMessage[];
  role: 'client' | 'professional';
  onSend: (content: string) => void;
}

export const ChatPanel: React.FC<Props> = ({ messages, role, onSend }) => {
  const [input, setInput] = useState('');

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!input.trim()) return;
    onSend(input.trim());
    setInput('');
  };

  return (
    <div className="chat-panel">
      <div className="chat-messages">
        {messages.length === 0 && <p className="chat-empty">Aucun message</p>}
        {messages.map((msg) => (
          <div key={msg.id} className={`chat-message ${msg.senderRole === role ? 'own' : 'other'}`}>
            <span className="msg-sender">{msg.senderName}</span>
            <p className="msg-content">{msg.content}</p>
            <span className="msg-time">
              {new Date(msg.timestamp).toLocaleTimeString('fr-FR', {
                hour: '2-digit',
                minute: '2-digit',
              })}
            </span>
          </div>
        ))}
      </div>
      <form className="chat-input" onSubmit={handleSubmit}>
        <input
          type="text"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Votre message..."
          aria-label="Message"
        />
        <button type="submit" disabled={!input.trim()}>
          Envoyer
        </button>
      </form>
    </div>
  );
};
