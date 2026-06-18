/**
 * KanbanScenario - Professional Kanban for Restaurant
 * Full-featured Kanban board with drag-drop, columns, tags
 */

import { useState } from 'react';
import { useKanban } from './useKanban';
import { KanbanColumn, TaskDetailModal, AddTaskModal, AddColumnPlaceholder } from './components';
import { GradientBackground } from '../../components/DevBoard';
import type { KanbanTask } from './types';
import './KanbanScenario.css';

export function KanbanScenario() {
  const {
    columns,
    tags,
    selectedTask,
    editingColumnId,
    addColumn,
    updateColumn,
    deleteColumn,
    setEditingColumnId,
    addTask,
    updateTask,
    deleteTask,
    setSelectedTask,
    toggleSubtask,
    addSubtask,
    handleDragStart,
    handleDrop,
    markMessagesAsRead,
  } = useKanban();

  const [addingToColumn, setAddingToColumn] = useState<string | null>(null);

  const handleDragOver = (e: React.DragEvent) => {
    e.preventDefault();
  };

  const handleAddTask = (columnId: string, task: Omit<KanbanTask, 'id' | 'createdAt'>) => {
    addTask(columnId, task);
    setAddingToColumn(null);
  };

  return (
    <div className="kanban-scenario">
      <GradientBackground />
      {/* Header */}
      <header className="kanban-header">
        <a href="/" className="back-link">
          ← Retour au Dashboard
        </a>
        <div className="header-content">
          <h1>🍷 Gestion des Commandes</h1>
          <p className="header-description">
            Kanban professionnel pour le suivi des commandes du restaurant
          </p>
        </div>
        <div className="header-stats">
          <div className="stat-item">
            <span className="stat-value">
              {columns.reduce((acc, col) => acc + col.tasks.length, 0)}
            </span>
            <span className="stat-label">Commandes</span>
          </div>
          <div className="stat-item">
            <span className="stat-value">{columns.length}</span>
            <span className="stat-label">Colonnes</span>
          </div>
          <div className="stat-item">
            <span className="stat-value">{tags.length}</span>
            <span className="stat-label">Tags</span>
          </div>
        </div>
      </header>

      {/* Kanban Board */}
      <div className="kanban-board-wrapper">
        <div className="kanban-board">
          {columns.map((column) => (
            <KanbanColumn
              key={column.id}
              column={column}
              tags={tags}
              isEditing={editingColumnId === column.id}
              onEditStart={() => setEditingColumnId(column.id)}
              onEditSave={(title, color) => updateColumn(column.id, { title, color })}
              onEditCancel={() => setEditingColumnId(null)}
              onDelete={() => deleteColumn(column.id)}
              onTaskClick={setSelectedTask}
              onTaskDelete={(taskId) => deleteTask(taskId, column.id)}
              onDragStart={(task) => handleDragStart(task, column.id)}
              onDragOver={handleDragOver}
              onDrop={() => handleDrop(column.id)}
              onAddTask={() => setAddingToColumn(column.id)}
            />
          ))}

          {/* Add Column Placeholder */}
          <AddColumnPlaceholder onAdd={addColumn} />
        </div>
      </div>

      {/* Legend */}
      <footer className="kanban-footer">
        <div className="legend">
          <h4>Légende des priorités:</h4>
          <div className="legend-items">
            <span className="legend-item priority-urgent">🔥 Urgent</span>
            <span className="legend-item priority-high">⬆️ Haute</span>
            <span className="legend-item priority-medium">➡️ Moyenne</span>
            <span className="legend-item priority-low">⬇️ Basse</span>
          </div>
        </div>
        <div className="legend">
          <h4>Tags disponibles:</h4>
          <div className="legend-items">
            {tags.map((tag) => (
              <span
                key={tag.id}
                className="legend-tag"
                style={{ backgroundColor: `${tag.color}25`, color: tag.color }}
              >
                {tag.name}
              </span>
            ))}
          </div>
        </div>
      </footer>

      {/* Task Detail Modal */}
      {selectedTask && (
        <TaskDetailModal
          task={selectedTask}
          availableTags={tags}
          onClose={() => setSelectedTask(null)}
          onUpdate={(updates) => updateTask(selectedTask.id, updates)}
          onToggleSubtask={(subtaskId) => toggleSubtask(selectedTask.id, subtaskId)}
          onAddSubtask={(title) => addSubtask(selectedTask.id, title)}
          onMarkMessagesRead={() => markMessagesAsRead(selectedTask.id)}
        />
      )}

      {/* Add Task Modal */}
      {addingToColumn && (
        <AddTaskModal
          availableTags={tags}
          onClose={() => setAddingToColumn(null)}
          onAdd={(task) => handleAddTask(addingToColumn, task)}
        />
      )}
    </div>
  );
}
