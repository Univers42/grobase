/**
 * AddColumnPlaceholder - Button to add new column
 */

import { useState } from 'react';
import './AddColumnPlaceholder.css';

interface AddColumnPlaceholderProps {
  onAdd: (title: string, color?: string) => void;
}

export function AddColumnPlaceholder({ onAdd }: AddColumnPlaceholderProps) {
  const [isOpen, setIsOpen] = useState(false);
  const [title, setTitle] = useState('');
  const [color, setColor] = useState('#722f37');

  const colors = ['#6b8e23', '#c9a227', '#3b82f6', '#722f37', '#8b5cf6', '#f97316', '#14b8a6'];

  const handleSubmit = () => {
    if (title.trim()) {
      onAdd(title.trim(), color);
      setTitle('');
      setColor('#722f37');
      setIsOpen(false);
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') handleSubmit();
    if (e.key === 'Escape') setIsOpen(false);
  };

  if (!isOpen) {
    return (
      <button className="add-column-placeholder" onClick={() => setIsOpen(true)}>
        <span className="add-column-icon">+</span>
        <span className="add-column-text">Ajouter une colonne</span>
      </button>
    );
  }

  return (
    <div className="add-column-form">
      <h4 className="add-column-form-title">Nouvelle colonne</h4>

      <input
        type="text"
        value={title}
        onChange={(e) => setTitle(e.target.value)}
        onKeyDown={handleKeyDown}
        className="add-column-input"
        placeholder="Nom de la colonne..."
        autoFocus
      />

      <div className="add-column-colors">
        {colors.map((c) => (
          <button
            key={c}
            className={`color-btn ${color === c ? 'selected' : ''}`}
            style={{ backgroundColor: c }}
            onClick={() => setColor(c)}
            aria-label={`Couleur ${c}`}
          />
        ))}
      </div>

      <div className="add-column-actions">
        <button className="btn-add-col" onClick={handleSubmit} disabled={!title.trim()}>
          Ajouter
        </button>
        <button className="btn-cancel-col" onClick={() => setIsOpen(false)}>
          Annuler
        </button>
      </div>
    </div>
  );
}
