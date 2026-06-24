/**
 * Kanban Types
 * Professional Kanban system for restaurant order management
 */

export interface KanbanTag {
  id: string;
  name: string;
  color: string;
}

export interface KanbanSubtask {
  id: string;
  title: string;
  completed: boolean;
}

export interface KanbanTask {
  id: string;
  title: string;
  description?: string;
  priority: 'low' | 'medium' | 'high' | 'urgent';
  tags: KanbanTag[];
  subtasks: KanbanSubtask[];
  assignee?: string;
  dueDate?: string;
  createdAt: string;
  messages?: TaskMessage[];
  unreadCount?: number;
}

export interface TaskMessage {
  id: string;
  senderId: string;
  senderName: string;
  senderRole: 'client' | 'professional';
  content: string;
  timestamp: string;
  read: boolean;
}

export interface KanbanColumn {
  id: string;
  title: string;
  color?: string;
  tasks: KanbanTask[];
  limit?: number; // WIP limit
}

export interface KanbanState {
  columns: KanbanColumn[];
  tags: KanbanTag[];
  editingColumnId: string | null;
  selectedTask: KanbanTask | null;
  isAddingColumn: boolean;
}

// Default tags for restaurant
export const DEFAULT_TAGS: KanbanTag[] = [
  { id: 'tag-1', name: 'Urgent', color: '#a91e2c' },
  { id: 'tag-2', name: 'VIP', color: '#c9a227' },
  { id: 'tag-3', name: 'Livraison', color: '#3b82f6' },
  { id: 'tag-4', name: 'Sur place', color: '#6b8e23' },
  { id: 'tag-5', name: 'À emporter', color: '#8b5cf6' },
  { id: 'tag-6', name: 'Allergie', color: '#f97316' },
];

// Default columns for restaurant orders
export const DEFAULT_COLUMNS: KanbanColumn[] = [
  {
    id: 'received',
    title: '📥 Reçue',
    color: '#6b8e23',
    tasks: [],
  },
  {
    id: 'preparing',
    title: '👨‍🍳 En préparation',
    color: '#c9a227',
    tasks: [],
  },
  {
    id: 'ready',
    title: '✅ Prête',
    color: '#3b82f6',
    tasks: [],
  },
  {
    id: 'delivered',
    title: '🚚 Livrée',
    color: '#722f37',
    tasks: [],
  },
];
