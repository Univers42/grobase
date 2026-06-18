/**
 * TaskDetailModal - View/Edit task details with subtasks
 */

import { useState } from 'react';
import type { KanbanTask, KanbanTag } from '../types';
import './TaskDetailModal.css';

interface TaskDetailModalProps {
  task: KanbanTask;
  availableTags: KanbanTag[];
  onClose: () => void;
  onUpdate: (updates: Partial<KanbanTask>) => void;
  onToggleSubtask: (subtaskId: string) => void;
  onAddSubtask: (title: string) => void;
  onMarkMessagesRead: () => void;
}

export function TaskDetailModal({
  task,
  availableTags,
  onClose,
  onUpdate,
  onToggleSubtask,
  onAddSubtask,
  onMarkMessagesRead,
}: TaskDetailModalProps) {
  const [newSubtask, setNewSubtask] = useState('');
  const [isEditingTitle, setIsEditingTitle] = useState(false);
  const [editTitle, setEditTitle] = useState(task.title);
  const [editDescription, setEditDescription] = useState(task.description || '');
  const [showTagPicker, setShowTagPicker] = useState(false);

  const completedCount = task.subtasks.filter((st) => st.completed).length;
  const progress =
    task.subtasks.length > 0 ? Math.round((completedCount / task.subtasks.length) * 100) : 0;

  const handleAddSubtask = () => {
    if (newSubtask.trim()) {
      onAddSubtask(newSubtask.trim());
      setNewSubtask('');
    }
  };

  const handleSaveTitle = () => {
    if (editTitle.trim() !== task.title) {
      onUpdate({ title: editTitle.trim() });
    }
    setIsEditingTitle(false);
  };

  const handleToggleTag = (tag: KanbanTag) => {
    const hasTag = task.tags.some((t) => t.id === tag.id);
    const newTags = hasTag ? task.tags.filter((t) => t.id !== tag.id) : [...task.tags, tag];
    onUpdate({ tags: newTags });
  };

  const handlePriorityChange = (priority: KanbanTask['priority']) => {
    onUpdate({ priority });
  };

  // Mark messages as read when modal opens
  if (task.unreadCount && task.unreadCount > 0) {
    onMarkMessagesRead();
  }

  return (
    <div className="task-modal-overlay" onClick={onClose}>
      <div className="task-modal" onClick={(e) => e.stopPropagation()}>
        {/* Header */}
        <div className="task-modal-header">
          <div className="task-modal-header-content">
            {isEditingTitle ? (
              <input
                type="text"
                value={editTitle}
                onChange={(e) => setEditTitle(e.target.value)}
                onBlur={handleSaveTitle}
                onKeyDown={(e) => e.key === 'Enter' && handleSaveTitle()}
                className="task-title-input"
                autoFocus
              />
            ) : (
              <h2 className="task-modal-title" onClick={() => setIsEditingTitle(true)}>
                {task.title}
              </h2>
            )}
            <span className={`task-priority-badge priority-${task.priority}`}>{task.priority}</span>
          </div>
          <button className="task-modal-close" onClick={onClose}>
            ×
          </button>
        </div>

        <div className="task-modal-body">
          {/* Left Column - Main content */}
          <div className="task-modal-main">
            {/* Description */}
            <div className="task-section">
              <h3 className="section-title">📝 Description</h3>
              <textarea
                value={editDescription}
                onChange={(e) => setEditDescription(e.target.value)}
                onBlur={() => onUpdate({ description: editDescription })}
                className="task-description-input"
                placeholder="Ajouter une description..."
                rows={3}
              />
            </div>

            {/* Subtasks */}
            <div className="task-section">
              <h3 className="section-title">
                ✅ Checklist
                <span className="progress-badge">{progress}%</span>
              </h3>

              {/* Progress bar */}
              <div className="subtask-progress">
                <div className="subtask-progress-fill" style={{ width: `${progress}%` }} />
              </div>

              {/* Subtask list */}
              <div className="subtask-list">
                {task.subtasks.map((subtask) => (
                  <label key={subtask.id} className="subtask-item">
                    <input
                      type="checkbox"
                      checked={subtask.completed}
                      onChange={() => onToggleSubtask(subtask.id)}
                      className="subtask-checkbox"
                    />
                    <span className={`subtask-text ${subtask.completed ? 'completed' : ''}`}>
                      {subtask.title}
                    </span>
                  </label>
                ))}
              </div>

              {/* Add subtask */}
              <div className="add-subtask-form">
                <input
                  type="text"
                  value={newSubtask}
                  onChange={(e) => setNewSubtask(e.target.value)}
                  onKeyDown={(e) => e.key === 'Enter' && handleAddSubtask()}
                  placeholder="Ajouter une sous-tâche..."
                  className="add-subtask-input"
                />
                <button onClick={handleAddSubtask} className="add-subtask-btn">
                  +
                </button>
              </div>
            </div>

            {/* Messages */}
            {task.messages && task.messages.length > 0 && (
              <div className="task-section">
                <h3 className="section-title">💬 Messages ({task.messages.length})</h3>
                <div className="message-list">
                  {task.messages.map((msg) => (
                    <div key={msg.id} className={`message-item ${msg.senderRole}`}>
                      <div className="message-header">
                        <span className="message-sender">{msg.senderName}</span>
                        <span className="message-time">
                          {new Date(msg.timestamp).toLocaleTimeString('fr-FR', {
                            hour: '2-digit',
                            minute: '2-digit',
                          })}
                        </span>
                      </div>
                      <p className="message-content">{msg.content}</p>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>

          {/* Right Column - Metadata */}
          <div className="task-modal-sidebar">
            {/* Priority */}
            <div className="sidebar-section">
              <h4 className="sidebar-title">Priorité</h4>
              <div className="priority-options">
                {(['urgent', 'high', 'medium', 'low'] as const).map((p) => (
                  <button
                    key={p}
                    className={`priority-option ${task.priority === p ? 'active' : ''} priority-${p}`}
                    onClick={() => handlePriorityChange(p)}
                  >
                    {p === 'urgent' ? '🔥' : p === 'high' ? '⬆️' : p === 'medium' ? '➡️' : '⬇️'}
                    {p}
                  </button>
                ))}
              </div>
            </div>

            {/* Tags */}
            <div className="sidebar-section">
              <h4 className="sidebar-title">
                Tags
                <button className="add-tag-btn" onClick={() => setShowTagPicker(!showTagPicker)}>
                  +
                </button>
              </h4>
              <div className="current-tags">
                {task.tags.map((tag) => (
                  <span
                    key={tag.id}
                    className="tag-chip"
                    style={{ backgroundColor: `${tag.color}30`, color: tag.color }}
                  >
                    {tag.name}
                    <button className="tag-remove" onClick={() => handleToggleTag(tag)}>
                      ×
                    </button>
                  </span>
                ))}
              </div>

              {showTagPicker && (
                <div className="tag-picker">
                  {availableTags
                    .filter((tag) => !task.tags.some((t) => t.id === tag.id))
                    .map((tag) => (
                      <button
                        key={tag.id}
                        className="tag-option"
                        style={{ backgroundColor: `${tag.color}20`, color: tag.color }}
                        onClick={() => handleToggleTag(tag)}
                      >
                        {tag.name}
                      </button>
                    ))}
                </div>
              )}
            </div>

            {/* Created */}
            <div className="sidebar-section">
              <h4 className="sidebar-title">Créée le</h4>
              <p className="sidebar-value">
                {new Date(task.createdAt).toLocaleDateString('fr-FR', {
                  day: 'numeric',
                  month: 'long',
                  year: 'numeric',
                  hour: '2-digit',
                  minute: '2-digit',
                })}
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
