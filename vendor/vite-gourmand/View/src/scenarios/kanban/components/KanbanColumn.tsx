/**
 * KanbanColumn - Single column with tasks
 */

import { useState } from 'react';
import type { KanbanColumn as ColumnType, KanbanTask, KanbanTag } from '../types';
import { TaskCard } from './TaskCard';
import './KanbanColumn.css';

interface KanbanColumnProps {
  column: ColumnType;
  tags: KanbanTag[];
  isEditing: boolean;
  onEditStart: () => void;
  onEditSave: (title: string, color?: string) => void;
  onEditCancel: () => void;
  onDelete: () => void;
  onTaskClick: (task: KanbanTask) => void;
  onTaskDelete: (taskId: string) => void;
  onDragStart: (task: KanbanTask) => void;
  onDragOver: (e: React.DragEvent) => void;
  onDrop: () => void;
  onAddTask: () => void;
}

export function KanbanColumn({
  column,
  isEditing,
  onEditStart,
  onEditSave,
  onEditCancel,
  onDelete,
  onTaskClick,
  onTaskDelete,
  onDragStart,
  onDragOver,
  onDrop,
  onAddTask,
}: KanbanColumnProps) {
  const [editTitle, setEditTitle] = useState(column.title);
  const [editColor, setEditColor] = useState(column.color || '#722f37');

  const handleSave = () => {
    if (editTitle.trim()) {
      onEditSave(editTitle.trim(), editColor);
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') handleSave();
    if (e.key === 'Escape') onEditCancel();
  };

  return (
    <div
      className="kanban-column"
      onDragOver={onDragOver}
      onDrop={onDrop}
      style={{ borderTopColor: column.color }}
    >
      {/* Column Header */}
      <div className="column-header">
        {isEditing ? (
          <div className="column-edit-form">
            <input
              type="text"
              value={editTitle}
              onChange={(e) => setEditTitle(e.target.value)}
              onKeyDown={handleKeyDown}
              className="column-edit-input"
              autoFocus
              placeholder="Nom de la colonne"
            />
            <div className="column-edit-colors">
              {['#6b8e23', '#c9a227', '#3b82f6', '#722f37', '#8b5cf6', '#f97316'].map((color) => (
                <button
                  key={color}
                  className={`color-option ${editColor === color ? 'selected' : ''}`}
                  style={{ backgroundColor: color }}
                  onClick={() => setEditColor(color)}
                  aria-label={`Couleur ${color}`}
                />
              ))}
            </div>
            <div className="column-edit-actions">
              <button className="btn-save" onClick={handleSave}>
                ✓
              </button>
              <button className="btn-cancel" onClick={onEditCancel}>
                ✕
              </button>
            </div>
          </div>
        ) : (
          <>
            <h3
              className="column-title"
              onDoubleClick={onEditStart}
              title="Double-cliquez pour modifier"
            >
              {column.title}
              <span className="task-count">{column.tasks.length}</span>
            </h3>
            <div className="column-actions">
              <button className="column-action-btn" onClick={onEditStart} aria-label="Modifier">
                ✏️
              </button>
              <button
                className="column-action-btn delete"
                onClick={onDelete}
                aria-label="Supprimer"
              >
                🗑️
              </button>
            </div>
          </>
        )}
      </div>

      {/* Tasks */}
      <div className="column-tasks">
        {column.tasks.map((task) => (
          <TaskCard
            key={task.id}
            task={task}
            onDragStart={() => onDragStart(task)}
            onClick={() => onTaskClick(task)}
            onDelete={() => onTaskDelete(task.id)}
          />
        ))}

        {/* Empty state */}
        {column.tasks.length === 0 && <div className="column-empty">Déposez une commande ici</div>}
      </div>

      {/* Add Card Placeholder */}
      <button className="add-card-btn" onClick={onAddTask}>
        <span className="add-icon">+</span>
        <span className="add-text">Ajouter une commande</span>
      </button>
    </div>
  );
}
