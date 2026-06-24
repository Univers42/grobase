/**
 * AddTaskModal - Create new task with full attributes
 */

import { useState } from 'react';
import type { KanbanTask, KanbanTag } from '../types';
import './AddTaskModal.css';

interface AddTaskModalProps {
  availableTags: KanbanTag[];
  onClose: () => void;
  onAdd: (task: Omit<KanbanTask, 'id' | 'createdAt'>) => void;
}

export function AddTaskModal({ availableTags, onClose, onAdd }: AddTaskModalProps) {
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [priority, setPriority] = useState<KanbanTask['priority']>('medium');
  const [selectedTags, setSelectedTags] = useState<KanbanTag[]>([]);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!title.trim()) return;

    onAdd({
      title: title.trim(),
      description: description.trim() || undefined,
      priority,
      tags: selectedTags,
      subtasks: [],
      messages: [],
      unreadCount: 0,
    });
    onClose();
  };

  const toggleTag = (tag: KanbanTag) => {
    setSelectedTags((prev) =>
      prev.some((t) => t.id === tag.id) ? prev.filter((t) => t.id !== tag.id) : [...prev, tag],
    );
  };

  return (
    <div className="add-task-overlay" onClick={onClose}>
      <div className="add-task-modal" onClick={(e) => e.stopPropagation()}>
        <h2 className="add-task-title">📦 Nouvelle Commande</h2>

        <form onSubmit={handleSubmit} className="add-task-form">
          {/* Title */}
          <div className="form-group">
            <label className="form-label">Titre *</label>
            <input
              type="text"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              className="form-input"
              placeholder="Ex: Commande #1045 - Menu Bordelais"
              autoFocus
              required
            />
          </div>

          {/* Description */}
          <div className="form-group">
            <label className="form-label">Description</label>
            <textarea
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              className="form-textarea"
              placeholder="Détails de la commande..."
              rows={3}
            />
          </div>

          {/* Priority */}
          <div className="form-group">
            <label className="form-label">Priorité</label>
            <div className="priority-selector">
              {(['urgent', 'high', 'medium', 'low'] as const).map((p) => (
                <button
                  key={p}
                  type="button"
                  className={`priority-btn ${priority === p ? 'active' : ''} priority-${p}`}
                  onClick={() => setPriority(p)}
                >
                  {p === 'urgent' ? '🔥' : p === 'high' ? '⬆️' : p === 'medium' ? '➡️' : '⬇️'}
                  {p}
                </button>
              ))}
            </div>
          </div>

          {/* Tags */}
          <div className="form-group">
            <label className="form-label">Tags</label>
            <div className="tag-selector">
              {availableTags.map((tag) => (
                <button
                  key={tag.id}
                  type="button"
                  className={`tag-btn ${selectedTags.some((t) => t.id === tag.id) ? 'active' : ''}`}
                  style={{
                    backgroundColor: selectedTags.some((t) => t.id === tag.id)
                      ? `${tag.color}40`
                      : `${tag.color}15`,
                    color: tag.color,
                    borderColor: selectedTags.some((t) => t.id === tag.id)
                      ? tag.color
                      : 'transparent',
                  }}
                  onClick={() => toggleTag(tag)}
                >
                  {tag.name}
                </button>
              ))}
            </div>
          </div>

          {/* Actions */}
          <div className="form-actions">
            <button type="button" className="btn-cancel" onClick={onClose}>
              Annuler
            </button>
            <button type="submit" className="btn-submit" disabled={!title.trim()}>
              Créer la commande
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
