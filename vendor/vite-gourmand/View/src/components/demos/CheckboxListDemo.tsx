/**
 * CheckboxList Demo - Example usage of the CheckboxList component
 * This file shows different ways to use the CheckboxList component
 */

import { CheckboxList, useCheckboxList, type CheckboxItem } from '../DevBoard';

// Example 1: Basic usage
const basicItems: CheckboxItem[] = [
  { id: '1', label: 'Option 1' },
  { id: '2', label: 'Option 2' },
  { id: '3', label: 'Option 3', disabled: true },
];

export function BasicCheckboxDemo() {
  const { selected, setSelected } = useCheckboxList(['1']);

  return (
    <div style={{ maxWidth: 400, padding: 20 }}>
      <h3>Basic Checkbox List</h3>
      <CheckboxList items={basicItems} selected={selected} onChange={setSelected} />
      <p>Selected: {selected.join(', ') || 'None'}</p>
    </div>
  );
}

// Example 2: With search and select all
const manyItems: CheckboxItem[] = [
  { id: '1', label: 'Apple', description: 'Fresh red apple' },
  { id: '2', label: 'Banana', description: 'Yellow banana' },
  { id: '3', label: 'Cherry', description: 'Sweet cherries' },
  { id: '4', label: 'Date', description: 'Dried dates' },
  { id: '5', label: 'Elderberry', description: 'Wild berries' },
];

export function SearchableCheckboxDemo() {
  const { selected, setSelected } = useCheckboxList();

  return (
    <div style={{ maxWidth: 400, padding: 20 }}>
      <h3>Searchable List with Select All</h3>
      <CheckboxList
        items={manyItems}
        selected={selected}
        onChange={setSelected}
        searchable
        showSelectAll
        showCount
        maxHeight={250}
      />
    </div>
  );
}

// Example 3: Cards variant with badges
interface TaskItem extends CheckboxItem {
  priority: 'low' | 'medium' | 'high';
}

const taskItems: TaskItem[] = [
  {
    id: '1',
    label: 'Fix login bug',
    description: 'Users cannot log in',
    badge: 'Urgent',
    priority: 'high',
  },
  {
    id: '2',
    label: 'Update documentation',
    description: 'Add API examples',
    badge: '2h',
    priority: 'low',
  },
  {
    id: '3',
    label: 'Review PR #123',
    description: 'New feature implementation',
    badge: 'Review',
    priority: 'medium',
  },
];

export function CardsVariantDemo() {
  const { selected, setSelected } = useCheckboxList();

  return (
    <div style={{ maxWidth: 450, padding: 20 }}>
      <h3>Cards Variant with Badges</h3>
      <CheckboxList
        items={taskItems}
        selected={selected}
        onChange={setSelected}
        variant="cards"
        accentColor="#8b5cf6"
      />
    </div>
  );
}

// Example 4: Grouped items
interface CategoryItem extends CheckboxItem {
  category: string;
}

const categoryItems: CategoryItem[] = [
  { id: '1', label: 'Burger', category: 'Main' },
  { id: '2', label: 'Pizza', category: 'Main' },
  { id: '3', label: 'Fries', category: 'Sides' },
  { id: '4', label: 'Salad', category: 'Sides' },
  { id: '5', label: 'Coke', category: 'Drinks' },
  { id: '6', label: 'Water', category: 'Drinks' },
];

export function GroupedCheckboxDemo() {
  const { selected, setSelected } = useCheckboxList();

  return (
    <div style={{ maxWidth: 400, padding: 20 }}>
      <h3>Grouped Items</h3>
      <CheckboxList
        items={categoryItems}
        selected={selected}
        onChange={setSelected}
        groupBy={(item) => item.category}
        showSelectAll
        showCount
      />
    </div>
  );
}

// Example 5: Custom render with icons
export function CustomRenderDemo() {
  const { selected, setSelected } = useCheckboxList();

  const items: CheckboxItem[] = [
    { id: '1', label: 'Home', icon: '🏠' },
    { id: '2', label: 'Work', icon: '💼' },
    { id: '3', label: 'Gym', icon: '🏋️' },
  ];

  return (
    <div style={{ maxWidth: 400, padding: 20 }}>
      <h3>Custom Render with Icons</h3>
      <CheckboxList
        items={items}
        selected={selected}
        onChange={setSelected}
        renderItem={(item, checked, toggle) => (
          <button
            type="button"
            key={item.id}
            onClick={toggle}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 12,
              padding: '12px 16px',
              borderRadius: 12,
              cursor: 'pointer',
              background: checked ? '#dbeafe' : '#f9fafb',
              border: checked ? '2px solid #3b82f6' : '2px solid transparent',
              transition: 'all 0.2s',
            }}
          >
            <span style={{ fontSize: 24 }}>{item.icon as string}</span>
            <span style={{ fontWeight: 600 }}>{item.label}</span>
            {checked && <span style={{ marginLeft: 'auto', color: '#3b82f6' }}>✓</span>}
          </button>
        )}
      />
    </div>
  );
}

// Example 6: Single select (radio behavior)
export function SingleSelectDemo() {
  const { selected, setSelected } = useCheckboxList();

  const options: CheckboxItem[] = [
    { id: 'sm', label: 'Small', description: '8oz cup' },
    { id: 'md', label: 'Medium', description: '12oz cup' },
    { id: 'lg', label: 'Large', description: '16oz cup' },
  ];

  return (
    <div style={{ maxWidth: 400, padding: 20 }}>
      <h3>Single Select (Radio Behavior)</h3>
      <CheckboxList
        items={options}
        selected={selected}
        onChange={setSelected}
        singleSelect
        variant="cards"
        accentColor="#10b981"
      />
      <p>Selected size: {selected[0] || 'None'}</p>
    </div>
  );
}

// All demos combined
export function CheckboxListDemoPage() {
  return (
    <div
      style={{
        display: 'grid',
        gridTemplateColumns: 'repeat(auto-fit, minmax(400px, 1fr))',
        gap: 24,
        padding: 24,
      }}
    >
      <BasicCheckboxDemo />
      <SearchableCheckboxDemo />
      <CardsVariantDemo />
      <GroupedCheckboxDemo />
      <CustomRenderDemo />
      <SingleSelectDemo />
    </div>
  );
}

export default CheckboxListDemoPage;
