/**
 * CheckboxList - Reusable, customizable checkbox list component
 *
 * Usage examples:
 *
 * Basic:
 * <CheckboxList
 *   items={[{ id: '1', label: 'Option 1' }, { id: '2', label: 'Option 2' }]}
 *   selected={selectedIds}
 *   onChange={setSelectedIds}
 * />
 *
 * With groups:
 * <CheckboxList
 *   items={items}
 *   selected={selected}
 *   onChange={setSelected}
 *   groupBy={(item) => item.category}
 * />
 *
 * Custom render:
 * <CheckboxList
 *   items={items}
 *   selected={selected}
 *   onChange={setSelected}
 *   renderItem={(item, checked) => <MyCustomItem item={item} checked={checked} />}
 * />
 */

import React, { useCallback, useMemo } from 'react';

// Types
export interface CheckboxItem {
  id: string;
  label: string;
  description?: string;
  disabled?: boolean;
  icon?: React.ReactNode;
  badge?: string | number;
  meta?: Record<string, unknown>;
}

export interface CheckboxListProps<T extends CheckboxItem = CheckboxItem> {
  /** Array of items to display */
  items: T[];
  /** Array of selected item IDs */
  selected: string[];
  /** Callback when selection changes */
  onChange: (selected: string[]) => void;
  /** Optional grouping function */
  groupBy?: (item: T) => string;
  /** Custom item renderer */
  renderItem?: (item: T, checked: boolean, toggle: () => void) => React.ReactNode;
  /** Show select all checkbox */
  showSelectAll?: boolean;
  /** Select all label */
  selectAllLabel?: string;
  /** Search/filter placeholder */
  searchPlaceholder?: string;
  /** Enable search filter */
  searchable?: boolean;
  /** Maximum height with scroll */
  maxHeight?: string | number;
  /** Custom class name */
  className?: string;
  /** Variant style */
  variant?: 'default' | 'cards' | 'compact' | 'minimal';
  /** Checkbox color */
  accentColor?: string;
  /** Loading state */
  loading?: boolean;
  /** Empty state message */
  emptyMessage?: string;
  /** Disabled state */
  disabled?: boolean;
  /** Show item count */
  showCount?: boolean;
  /** Allow single selection only (radio behavior) */
  singleSelect?: boolean;
}

// Styles
const styles = {
  container: {
    display: 'flex',
    flexDirection: 'column' as const,
    gap: '0.5rem',
    width: '100%',
  },
  header: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center',
    padding: '0.5rem 0',
    borderBottom: '1px solid #e5e7eb',
    marginBottom: '0.5rem',
  },
  searchInput: {
    width: '100%',
    padding: '0.625rem 0.875rem',
    paddingLeft: '2.5rem',
    border: '1px solid #e5e7eb',
    borderRadius: '8px',
    fontSize: '0.875rem',
    outline: 'none',
    transition: 'all 0.2s',
  },
  searchWrapper: {
    position: 'relative' as const,
    marginBottom: '0.75rem',
  },
  searchIcon: {
    position: 'absolute' as const,
    left: '0.875rem',
    top: '50%',
    transform: 'translateY(-50%)',
    color: '#9ca3af',
    pointerEvents: 'none' as const,
  },
  list: {
    display: 'flex',
    flexDirection: 'column' as const,
    gap: '0.25rem',
    overflowY: 'auto' as const,
  },
  groupHeader: {
    fontSize: '0.75rem',
    fontWeight: 600,
    color: '#6b7280',
    textTransform: 'uppercase' as const,
    letterSpacing: '0.05em',
    padding: '0.75rem 0.5rem 0.25rem',
    borderBottom: '1px solid #f3f4f6',
    marginTop: '0.5rem',
  },
  item: {
    default: {
      display: 'flex',
      alignItems: 'center',
      gap: '0.75rem',
      padding: '0.625rem 0.75rem',
      borderRadius: '8px',
      cursor: 'pointer',
      transition: 'all 0.15s',
      border: '1px solid transparent',
    },
    cards: {
      display: 'flex',
      alignItems: 'center',
      gap: '0.75rem',
      padding: '0.875rem 1rem',
      borderRadius: '12px',
      cursor: 'pointer',
      transition: 'all 0.15s',
      border: '1px solid #e5e7eb',
      background: 'white',
      boxShadow: '0 1px 2px rgba(0,0,0,0.05)',
    },
    compact: {
      display: 'flex',
      alignItems: 'center',
      gap: '0.5rem',
      padding: '0.375rem 0.5rem',
      borderRadius: '4px',
      cursor: 'pointer',
      transition: 'all 0.15s',
      border: '1px solid transparent',
      fontSize: '0.8125rem',
    },
    minimal: {
      display: 'flex',
      alignItems: 'center',
      gap: '0.5rem',
      padding: '0.25rem 0',
      cursor: 'pointer',
      transition: 'all 0.15s',
    },
  },
  checkbox: {
    width: '18px',
    height: '18px',
    borderRadius: '4px',
    border: '2px solid #d1d5db',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    flexShrink: 0,
    transition: 'all 0.15s',
  },
  checkmark: {
    width: '10px',
    height: '10px',
    color: 'white',
  },
  itemContent: {
    flex: 1,
    display: 'flex',
    flexDirection: 'column' as const,
    gap: '0.125rem',
    minWidth: 0,
  },
  itemLabel: {
    fontWeight: 500,
    color: '#1f2937',
    whiteSpace: 'nowrap' as const,
    overflow: 'hidden',
    textOverflow: 'ellipsis',
  },
  itemDescription: {
    fontSize: '0.75rem',
    color: '#6b7280',
    whiteSpace: 'nowrap' as const,
    overflow: 'hidden',
    textOverflow: 'ellipsis',
  },
  badge: {
    fontSize: '0.6875rem',
    fontWeight: 600,
    padding: '0.125rem 0.5rem',
    borderRadius: '9999px',
    backgroundColor: '#f3f4f6',
    color: '#6b7280',
    flexShrink: 0,
  },
  selectAll: {
    display: 'flex',
    alignItems: 'center',
    gap: '0.5rem',
    fontSize: '0.8125rem',
    color: '#6b7280',
    cursor: 'pointer',
    padding: '0.25rem 0',
  },
  count: {
    fontSize: '0.75rem',
    color: '#9ca3af',
    marginLeft: 'auto',
  },
  empty: {
    display: 'flex',
    flexDirection: 'column' as const,
    alignItems: 'center',
    justifyContent: 'center',
    padding: '2rem 1rem',
    color: '#9ca3af',
    textAlign: 'center' as const,
  },
  loading: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    padding: '2rem',
  },
};

// Checkmark Icon
const CheckIcon = () => (
  <svg viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
    <path d="M2 6l3 3 5-6" />
  </svg>
);

// Search Icon
const SearchIcon = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
    <circle cx="11" cy="11" r="8" />
    <path d="M21 21l-4.35-4.35" />
  </svg>
);

// Loading Spinner
const Spinner = () => (
  <svg
    width="24"
    height="24"
    viewBox="0 0 24 24"
    fill="none"
    style={{ animation: 'spin 1s linear infinite' }}
  >
    <circle cx="12" cy="12" r="10" stroke="#e5e7eb" strokeWidth="3" />
    <path d="M12 2a10 10 0 0 1 10 10" stroke="#3b82f6" strokeWidth="3" strokeLinecap="round" />
    <style>{`@keyframes spin { to { transform: rotate(360deg); } }`}</style>
  </svg>
);

export function CheckboxList<T extends CheckboxItem = CheckboxItem>({
  items,
  selected,
  onChange,
  groupBy,
  renderItem,
  showSelectAll = false,
  selectAllLabel = 'Tout sélectionner',
  searchPlaceholder = 'Rechercher...',
  searchable = false,
  maxHeight,
  className = '',
  variant = 'default',
  accentColor = '#3b82f6',
  loading = false,
  emptyMessage = 'Aucun élément',
  disabled = false,
  showCount = false,
  singleSelect = false,
}: Readonly<CheckboxListProps<T>>) {
  const [searchTerm, setSearchTerm] = React.useState('');

  // Filter items based on search
  const filteredItems = useMemo(() => {
    if (!searchTerm) return items;
    const lower = searchTerm.toLowerCase();
    return items.filter(
      (item) =>
        item.label.toLowerCase().includes(lower) || item.description?.toLowerCase().includes(lower),
    );
  }, [items, searchTerm]);

  // Group items if groupBy is provided
  const groupedItems = useMemo(() => {
    if (!groupBy) return { '': filteredItems };
    return filteredItems.reduce<Record<string, T[]>>((acc, item) => {
      const group = groupBy(item);
      if (!acc[group]) acc[group] = [];
      acc[group].push(item);
      return acc;
    }, {});
  }, [filteredItems, groupBy]);

  // Toggle single item
  const toggleItem = useCallback(
    (id: string) => {
      if (disabled) return;
      if (singleSelect) {
        onChange([id]);
      } else {
        onChange(selected.includes(id) ? selected.filter((s) => s !== id) : [...selected, id]);
      }
    },
    [disabled, singleSelect, onChange, selected],
  );

  // Select all / deselect all
  const toggleAll = useCallback(() => {
    if (disabled) return;
    const allIds = filteredItems.filter((i) => !i.disabled).map((i) => i.id);
    const allSelected = allIds.every((id) => selected.includes(id));
    onChange(allSelected ? [] : allIds);
  }, [disabled, filteredItems, selected, onChange]);

  // Check if all items are selected
  const allSelected = useMemo(() => {
    const enabledItems = filteredItems.filter((i) => !i.disabled);
    return enabledItems.length > 0 && enabledItems.every((i) => selected.includes(i.id));
  }, [filteredItems, selected]);

  const someSelected = useMemo(() => {
    return selected.length > 0 && !allSelected;
  }, [selected, allSelected]);
  const showEmptyList = filteredItems.length === 0;
  const showGroupedList = showEmptyList === false && Boolean(groupBy);
  const showFlatList = showEmptyList === false && Boolean(groupBy) === false;

  // Render a single checkbox item
  const renderCheckboxItem = (item: T) => {
    const checked = selected.includes(item.id);
    const isDisabled = disabled || item.disabled;

    if (renderItem) {
      return renderItem(item, checked, () => toggleItem(item.id));
    }

    const itemStyle = {
      ...styles.item[variant],
      ...(checked &&
        variant !== 'minimal' && {
          backgroundColor: accentColor + '10',
          borderColor: accentColor + '40',
        }),
      ...(isDisabled && { opacity: 0.5, cursor: 'not-allowed' }),
    };

    const checkboxStyle = {
      ...styles.checkbox,
      ...(checked && {
        backgroundColor: accentColor,
        borderColor: accentColor,
      }),
    };

    return (
      <label key={item.id} style={itemStyle}>
        <input
          type={singleSelect ? 'radio' : 'checkbox'}
          checked={checked}
          disabled={isDisabled}
          onChange={() => toggleItem(item.id)}
          style={{ position: 'absolute', opacity: 0, pointerEvents: 'none' }}
        />
        <span style={checkboxStyle} aria-hidden="true">
          {checked && (
            <div style={styles.checkmark}>
              <CheckIcon />
            </div>
          )}
        </span>

        {item.icon && <div style={{ flexShrink: 0 }}>{item.icon}</div>}

        <div style={styles.itemContent}>
          <span style={styles.itemLabel}>{item.label}</span>
          {item.description && <span style={styles.itemDescription}>{item.description}</span>}
        </div>

        {item.badge !== undefined && <span style={styles.badge}>{item.badge}</span>}
      </label>
    );
  };

  // Loading state
  if (loading) {
    return (
      <div style={styles.loading}>
        <Spinner />
      </div>
    );
  }

  return (
    <div style={styles.container} className={className}>
      {/* Search */}
      {searchable && (
        <div style={styles.searchWrapper}>
          <div style={styles.searchIcon}>
            <SearchIcon />
          </div>
          <input
            type="text"
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
            placeholder={searchPlaceholder}
            style={styles.searchInput}
            disabled={disabled}
          />
        </div>
      )}

      {/* Header with select all */}
      {(showSelectAll || showCount) && !singleSelect && (
        <div style={styles.header}>
          {showSelectAll && (
            <label
              style={{
                ...styles.selectAll,
                ...(disabled && { cursor: 'not-allowed', opacity: 0.5 }),
              }}
            >
              <input
                type="checkbox"
                checked={allSelected}
                disabled={disabled}
                onChange={toggleAll}
                style={{ position: 'absolute', opacity: 0, pointerEvents: 'none' }}
              />
              <span
                style={{
                  ...styles.checkbox,
                  width: '16px',
                  height: '16px',
                  ...(allSelected && { backgroundColor: accentColor, borderColor: accentColor }),
                  ...(someSelected && {
                    backgroundColor: accentColor + '60',
                    borderColor: accentColor,
                  }),
                }}
                aria-hidden="true"
              >
                {(allSelected || someSelected) && (
                  <div style={{ ...styles.checkmark, width: '8px', height: '8px' }}>
                    {allSelected ? (
                      <CheckIcon />
                    ) : (
                      <span style={{ color: 'white', fontSize: '10px' }}>−</span>
                    )}
                  </div>
                )}
              </span>
              <span>{selectAllLabel}</span>
            </label>
          )}
          {showCount && (
            <span style={styles.count}>
              {selected.length} / {items.length} sélectionné{selected.length > 1 ? 's' : ''}
            </span>
          )}
        </div>
      )}

      {/* Items list */}
      <div style={{ ...styles.list, ...(maxHeight && { maxHeight, overflowY: 'auto' }) }}>
        {showEmptyList && (
          <div style={styles.empty}>
            <span style={{ fontSize: '2rem', marginBottom: '0.5rem' }}>📭</span>
            <span>{emptyMessage}</span>
          </div>
        )}
        {showGroupedList &&
          Object.entries(groupedItems).map(([group, groupItems]) => (
            <React.Fragment key={group}>
              {group && <div style={styles.groupHeader}>{group}</div>}
              {groupItems.map(renderCheckboxItem)}
            </React.Fragment>
          ))}
        {showFlatList && filteredItems.map(renderCheckboxItem)}
      </div>
    </div>
  );
}

// Export a hook for managing checkbox state
// eslint-disable-next-line react-refresh/only-export-components
export function useCheckboxList(initialSelected: string[] = []) {
  const [selected, setSelected] = React.useState<string[]>(initialSelected);

  const toggle = useCallback((id: string) => {
    setSelected((prev) => (prev.includes(id) ? prev.filter((s) => s !== id) : [...prev, id]));
  }, []);

  const selectAll = useCallback((ids: string[]) => {
    setSelected(ids);
  }, []);

  const clear = useCallback(() => {
    setSelected([]);
  }, []);

  const isSelected = useCallback((id: string) => selected.includes(id), [selected]);

  return { selected, setSelected, toggle, selectAll, clear, isSelected };
}

export default CheckboxList;
