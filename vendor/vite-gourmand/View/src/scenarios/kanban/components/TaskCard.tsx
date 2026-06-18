/**
 * TaskCard - Individual Kanban task card
 */

import type { KanbanTask } from '../types';
import './TaskCard.css';

interface TaskCardProps {
  task: KanbanTask;
  onDragStart: () => void;
  onClick: () => void;
  onDelete: () => void;
}

export function TaskCard({ task, onDragStart, onClick, onDelete }: TaskCardProps) {
  const completedSubtasks = task.subtasks.filter((st) => st.completed).length;
  const totalSubtasks = task.subtasks.length;
  const progress = totalSubtasks > 0 ? (completedSubtasks / totalSubtasks) * 100 : 0;

  return (
    <div
      className={`kanban-task-card priority-${task.priority}`}
      draggable
      onDragStart={onDragStart}
      onClick={onClick}
    >
      {/* Notification Badge */}
      {task.unreadCount && task.unreadCount > 0 && (
        <div className="task-notification-badge unread">{task.unreadCount}</div>
      )}

      {/* Tags */}
      {task.tags.length > 0 && (
        <div className="task-tags">
          {task.tags.slice(0, 3).map((tag) => (
            <span
              key={tag.id}
              className="task-tag"
              style={{ backgroundColor: `${tag.color}30`, color: tag.color }}
            >
              {tag.name}
            </span>
          ))}
          {task.tags.length > 3 && <span className="task-tag-more">+{task.tags.length - 3}</span>}
        </div>
      )}

      {/* Title */}
      <h4 className="task-title">{task.title}</h4>

      {/* Description preview */}
      {task.description && <p className="task-description">{task.description}</p>}

      {/* Progress bar for subtasks */}
      {totalSubtasks > 0 && (
        <div className="task-progress">
          <div className="task-progress-bar">
            <div className="task-progress-fill" style={{ width: `${progress}%` }} />
          </div>
          <span className="task-progress-text">
            {completedSubtasks}/{totalSubtasks}
          </span>
        </div>
      )}

      {/* Footer */}
      <div className="task-footer">
        <span className={`task-priority priority-${task.priority}`}>
          {task.priority === 'urgent'
            ? '🔥'
            : task.priority === 'high'
              ? '⬆️'
              : task.priority === 'medium'
                ? '➡️'
                : '⬇️'}
          {task.priority}
        </span>
        <button
          className="task-delete-btn"
          onClick={(e) => {
            e.stopPropagation();
            onDelete();
          }}
          aria-label="Supprimer"
        >
          ×
        </button>
      </div>
    </div>
  );
}
