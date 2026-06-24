/**
 * useKanban - State management hook for Kanban
 */

import { useState, useCallback } from 'react';
import type { KanbanColumn, KanbanTask, KanbanTag, KanbanSubtask } from './types';
import { DEFAULT_COLUMNS, DEFAULT_TAGS } from './types';

// Initial sample tasks
const initialTasks: KanbanTask[] = [
  {
    id: 'task-1',
    title: 'Commande #1042 - Menu Dégustation',
    description: 'Menu dégustation pour 4 personnes avec accord mets et vins',
    priority: 'high',
    tags: [DEFAULT_TAGS[1], DEFAULT_TAGS[3]], // VIP, Sur place
    subtasks: [
      { id: 'st-1', title: 'Préparer les entrées', completed: true },
      { id: 'st-2', title: 'Service des vins', completed: false },
      { id: 'st-3', title: 'Plat principal', completed: false },
      { id: 'st-4', title: 'Desserts', completed: false },
    ],
    createdAt: new Date().toISOString(),
    messages: [],
    unreadCount: 0,
  },
  {
    id: 'task-2',
    title: 'Commande #1043 - Plateau fruits de mer',
    description: 'Plateau royal fruits de mer pour 2, sans crustacés',
    priority: 'urgent',
    tags: [DEFAULT_TAGS[0], DEFAULT_TAGS[5]], // Urgent, Allergie
    subtasks: [
      { id: 'st-5', title: 'Vérifier allergies', completed: true },
      { id: 'st-6', title: 'Préparation plateau', completed: false },
    ],
    createdAt: new Date().toISOString(),
    messages: [
      {
        id: 'msg-1',
        senderId: 'client-1',
        senderName: 'Jean Dupont',
        senderRole: 'client',
        content: 'Pouvez-vous ajouter du citron supplémentaire ?',
        timestamp: new Date().toISOString(),
        read: false,
      },
    ],
    unreadCount: 1,
  },
  {
    id: 'task-3',
    title: 'Commande #1044 - Livraison 12h30',
    description: 'Entrecôte sauce bordelaise + frites maison',
    priority: 'medium',
    tags: [DEFAULT_TAGS[2]], // Livraison
    subtasks: [
      { id: 'st-7', title: 'Cuisson viande', completed: false },
      { id: 'st-8', title: 'Emballage chaud', completed: false },
    ],
    createdAt: new Date().toISOString(),
    messages: [],
    unreadCount: 0,
  },
];

// Initialize columns with tasks
const initializeColumns = (): KanbanColumn[] => {
  const cols = [...DEFAULT_COLUMNS];
  cols[0].tasks = [initialTasks[0], initialTasks[1]];
  cols[1].tasks = [initialTasks[2]];
  return cols;
};

export function useKanban() {
  const [columns, setColumns] = useState<KanbanColumn[]>(initializeColumns);
  const [tags, setTags] = useState<KanbanTag[]>(DEFAULT_TAGS);
  const [selectedTask, setSelectedTask] = useState<KanbanTask | null>(null);
  const [editingColumnId, setEditingColumnId] = useState<string | null>(null);
  const [isAddingColumn, setIsAddingColumn] = useState(false);
  const [draggedTask, setDraggedTask] = useState<{ task: KanbanTask; fromColumn: string } | null>(
    null,
  );

  // Column operations
  const addColumn = useCallback((title: string, color?: string) => {
    const newColumn: KanbanColumn = {
      id: `col-${Date.now()}`,
      title,
      color: color || '#722f37',
      tasks: [],
    };
    setColumns((prev) => [...prev, newColumn]);
    setIsAddingColumn(false);
  }, []);

  const updateColumn = useCallback((columnId: string, updates: Partial<KanbanColumn>) => {
    setColumns((prev) => prev.map((col) => (col.id === columnId ? { ...col, ...updates } : col)));
    setEditingColumnId(null);
  }, []);

  const deleteColumn = useCallback((columnId: string) => {
    setColumns((prev) => prev.filter((col) => col.id !== columnId));
  }, []);

  // Task operations
  const addTask = useCallback((columnId: string, task: Omit<KanbanTask, 'id' | 'createdAt'>) => {
    const newTask: KanbanTask = {
      ...task,
      id: `task-${Date.now()}`,
      createdAt: new Date().toISOString(),
    };
    setColumns((prev) =>
      prev.map((col) => (col.id === columnId ? { ...col, tasks: [...col.tasks, newTask] } : col)),
    );
  }, []);

  const updateTask = useCallback(
    (taskId: string, updates: Partial<KanbanTask>) => {
      setColumns((prev) =>
        prev.map((col) => ({
          ...col,
          tasks: col.tasks.map((task) => (task.id === taskId ? { ...task, ...updates } : task)),
        })),
      );

      // Update selected task if it's the one being edited
      if (selectedTask?.id === taskId) {
        setSelectedTask((prev) => (prev ? { ...prev, ...updates } : null));
      }
    },
    [selectedTask],
  );

  const deleteTask = useCallback(
    (taskId: string, columnId: string) => {
      setColumns((prev) =>
        prev.map((col) =>
          col.id === columnId ? { ...col, tasks: col.tasks.filter((t) => t.id !== taskId) } : col,
        ),
      );
      if (selectedTask?.id === taskId) {
        setSelectedTask(null);
      }
    },
    [selectedTask],
  );

  // Subtask operations
  const toggleSubtask = useCallback(
    (taskId: string, subtaskId: string) => {
      setColumns((prev) =>
        prev.map((col) => ({
          ...col,
          tasks: col.tasks.map((task) =>
            task.id === taskId
              ? {
                  ...task,
                  subtasks: task.subtasks.map((st) =>
                    st.id === subtaskId ? { ...st, completed: !st.completed } : st,
                  ),
                }
              : task,
          ),
        })),
      );

      // Update selected task subtasks
      if (selectedTask?.id === taskId) {
        setSelectedTask((prev) =>
          prev
            ? {
                ...prev,
                subtasks: prev.subtasks.map((st) =>
                  st.id === subtaskId ? { ...st, completed: !st.completed } : st,
                ),
              }
            : null,
        );
      }
    },
    [selectedTask],
  );

  const addSubtask = useCallback(
    (taskId: string, title: string) => {
      const newSubtask: KanbanSubtask = {
        id: `st-${Date.now()}`,
        title,
        completed: false,
      };
      updateTask(taskId, {
        subtasks: [...(selectedTask?.subtasks || []), newSubtask],
      });
    },
    [updateTask, selectedTask],
  );

  // Tag operations
  const addTag = useCallback((name: string, color: string) => {
    const newTag: KanbanTag = {
      id: `tag-${Date.now()}`,
      name,
      color,
    };
    setTags((prev) => [...prev, newTag]);
    return newTag;
  }, []);

  const deleteTag = useCallback((tagId: string) => {
    setTags((prev) => prev.filter((t) => t.id !== tagId));
    // Remove tag from all tasks
    setColumns((prev) =>
      prev.map((col) => ({
        ...col,
        tasks: col.tasks.map((task) => ({
          ...task,
          tags: task.tags.filter((t) => t.id !== tagId),
        })),
      })),
    );
  }, []);

  // Drag & Drop
  const handleDragStart = useCallback((task: KanbanTask, columnId: string) => {
    setDraggedTask({ task, fromColumn: columnId });
  }, []);

  const handleDrop = useCallback(
    (targetColumnId: string) => {
      if (!draggedTask) return;

      setColumns((prev) =>
        prev.map((col) => {
          if (col.id === draggedTask.fromColumn) {
            return { ...col, tasks: col.tasks.filter((t) => t.id !== draggedTask.task.id) };
          }
          if (col.id === targetColumnId) {
            return { ...col, tasks: [...col.tasks, draggedTask.task] };
          }
          return col;
        }),
      );

      setDraggedTask(null);
    },
    [draggedTask],
  );

  // Message operations
  const markMessagesAsRead = useCallback((taskId: string) => {
    setColumns((prev) =>
      prev.map((col) => ({
        ...col,
        tasks: col.tasks.map((task) =>
          task.id === taskId
            ? {
                ...task,
                unreadCount: 0,
                messages: task.messages?.map((m) => ({ ...m, read: true })),
              }
            : task,
        ),
      })),
    );
  }, []);

  return {
    // State
    columns,
    tags,
    selectedTask,
    editingColumnId,
    isAddingColumn,
    draggedTask,

    // Column operations
    addColumn,
    updateColumn,
    deleteColumn,
    setEditingColumnId,
    setIsAddingColumn,

    // Task operations
    addTask,
    updateTask,
    deleteTask,
    setSelectedTask,

    // Subtask operations
    toggleSubtask,
    addSubtask,

    // Tag operations
    addTag,
    deleteTag,

    // Drag & Drop
    handleDragStart,
    handleDrop,

    // Messages
    markMessagesAsRead,
  };
}
