import React from 'react';
import { FoodCard } from '../components/ui/foodcard';

// Example placeholder data
const menus = [
  {
    name: 'Menu Gastronomique',
    description: 'Un menu raffiné pour les gourmets.',
    price: 49.99,
    imageUrl: undefined,
  },
  {
    name: 'Menu Vegan',
    description: '100% végétal, sain et savoureux.',
    price: 39.99,
    imageUrl: undefined,
  },
  {
    name: 'Menu Brunch',
    description: 'Parfait pour un dimanche en famille.',
    price: 29.99,
    imageUrl: undefined,
  },
];

export const FoodCardScenario: React.FC = () => {
  return (
    <div
      style={{
        display: 'grid',
        gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))',
        gap: '1rem',
        padding: '1rem',
        maxWidth: 600,
        margin: '0 auto',
      }}
    >
      {menus.map((menu) => (
        <FoodCard key={menu.name} {...menu} />
      ))}
    </div>
  );
};

export default FoodCardScenario;
