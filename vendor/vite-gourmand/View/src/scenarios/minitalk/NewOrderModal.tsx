/**
 * New Order Modal - Popup form for creating a new order
 */

import React, { useState } from 'react';
import type { NewOrderForm, OrderItem } from './types';

interface NewOrderModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSubmit: (form: NewOrderForm) => void;
}

const MENU_ITEMS: { name: string; price: number }[] = [
  { name: 'Burger Classic', price: 12.5 },
  { name: 'Burger Végétarien', price: 11.9 },
  { name: 'Pizza Margherita', price: 14.0 },
  { name: 'Pizza 4 Fromages', price: 16.5 },
  { name: 'Salade César', price: 10.5 },
  { name: 'Pâtes Carbonara', price: 13.0 },
  { name: 'Tiramisu', price: 6.5 },
  { name: 'Coca-Cola', price: 3.5 },
  { name: 'Eau minérale', price: 2.5 },
];

export function NewOrderModal({ isOpen, onClose, onSubmit }: NewOrderModalProps) {
  const [customerName, setCustomerName] = useState('');
  const [type, setType] = useState<'dine_in' | 'takeaway' | 'delivery'>('dine_in');
  const [items, setItems] = useState<OrderItem[]>([]);
  const [notes, setNotes] = useState('');

  const handleAddItem = (menuItem: { name: string; price: number }) => {
    const existing = items.find((i) => i.name === menuItem.name);
    if (existing) {
      setItems(
        items.map((i) => (i.name === menuItem.name ? { ...i, quantity: i.quantity + 1 } : i)),
      );
    } else {
      setItems([...items, { name: menuItem.name, quantity: 1, price: menuItem.price }]);
    }
  };

  const handleRemoveItem = (name: string) => {
    const existing = items.find((i) => i.name === name);
    if (existing && existing.quantity > 1) {
      setItems(items.map((i) => (i.name === name ? { ...i, quantity: i.quantity - 1 } : i)));
    } else {
      setItems(items.filter((i) => i.name !== name));
    }
  };

  const total = items.reduce((sum, item) => sum + item.price * item.quantity, 0);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!customerName.trim() || items.length === 0) return;

    onSubmit({ customerName: customerName.trim(), type, items, notes: notes.trim() || undefined });

    // Reset form
    setCustomerName('');
    setType('dine_in');
    setItems([]);
    setNotes('');
    onClose();
  };

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-sm">
      <div className="bg-white rounded-xl shadow-2xl w-full max-w-lg mx-4 max-h-[90vh] overflow-hidden">
        {/* Header */}
        <div className="bg-gradient-to-r from-orange-500 to-red-500 px-6 py-4 flex items-center justify-between">
          <h2 className="text-xl font-bold text-white flex items-center gap-2">
            <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M12 6v6m0 0v6m0-6h6m-6 0H6"
              />
            </svg>
            Nouvelle Commande
          </h2>
          <button onClick={onClose} className="text-white/80 hover:text-white transition-colors">
            <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </button>
        </div>

        <form onSubmit={handleSubmit} className="overflow-y-auto max-h-[calc(90vh-8rem)]">
          <div className="p-6 space-y-5">
            {/* Customer Name */}
            <div>
              <label className="block text-sm font-semibold text-gray-700 mb-2">
                Nom du client *
              </label>
              <input
                type="text"
                value={customerName}
                onChange={(e) => setCustomerName(e.target.value)}
                placeholder="Ex: Marie Dupont"
                className="w-full px-4 py-3 border border-gray-200 rounded-lg focus:ring-2 focus:ring-orange-500 focus:border-transparent transition-all"
                required
              />
            </div>

            {/* Order Type */}
            <div>
              <label className="block text-sm font-semibold text-gray-700 mb-2">
                Type de commande
              </label>
              <div className="grid grid-cols-3 gap-2">
                {[
                  { value: 'dine_in', label: 'Sur place', icon: '🍽️' },
                  { value: 'takeaway', label: 'À emporter', icon: '📦' },
                  { value: 'delivery', label: 'Livraison', icon: '🚗' },
                ].map((option) => (
                  <button
                    key={option.value}
                    type="button"
                    onClick={() => setType(option.value as typeof type)}
                    className={`py-3 px-2 rounded-lg border-2 transition-all flex flex-col items-center gap-1 ${
                      type === option.value
                        ? 'border-orange-500 bg-orange-50 text-orange-700'
                        : 'border-gray-200 hover:border-gray-300 text-gray-600'
                    }`}
                  >
                    <span className="text-xl">{option.icon}</span>
                    <span className="text-xs font-medium">{option.label}</span>
                  </button>
                ))}
              </div>
            </div>

            {/* Menu Items */}
            <div>
              <label className="block text-sm font-semibold text-gray-700 mb-2">Articles *</label>
              <div className="grid grid-cols-3 gap-2 mb-3">
                {MENU_ITEMS.map((item) => (
                  <button
                    key={item.name}
                    type="button"
                    onClick={() => handleAddItem(item)}
                    className="p-2 text-xs rounded-lg border border-gray-200 hover:border-orange-300 hover:bg-orange-50 transition-all text-left"
                  >
                    <div className="font-medium text-gray-800 truncate">{item.name}</div>
                    <div className="text-orange-600 font-semibold">{item.price.toFixed(2)}€</div>
                  </button>
                ))}
              </div>

              {/* Selected Items */}
              {items.length > 0 && (
                <div className="bg-gray-50 rounded-lg p-3 space-y-2">
                  {items.map((item) => (
                    <div key={item.name} className="flex items-center justify-between text-sm">
                      <span className="text-gray-700">
                        <span className="font-medium">{item.quantity}x</span> {item.name}
                      </span>
                      <div className="flex items-center gap-2">
                        <span className="text-orange-600 font-semibold">
                          {(item.price * item.quantity).toFixed(2)}€
                        </span>
                        <button
                          type="button"
                          onClick={() => handleRemoveItem(item.name)}
                          className="text-red-500 hover:text-red-700 transition-colors"
                        >
                          <svg
                            className="w-4 h-4"
                            fill="none"
                            stroke="currentColor"
                            viewBox="0 0 24 24"
                          >
                            <path
                              strokeLinecap="round"
                              strokeLinejoin="round"
                              strokeWidth={2}
                              d="M20 12H4"
                            />
                          </svg>
                        </button>
                      </div>
                    </div>
                  ))}
                  <div className="border-t border-gray-200 pt-2 mt-2 flex justify-between font-bold">
                    <span>Total</span>
                    <span className="text-orange-600">{total.toFixed(2)}€</span>
                  </div>
                </div>
              )}
              {items.length === 0 && (
                <div className="text-center py-4 text-gray-400 text-sm border-2 border-dashed border-gray-200 rounded-lg">
                  👆 Cliquez sur un article ci-dessus pour l'ajouter
                </div>
              )}
            </div>

            {/* Notes */}
            <div>
              <label className="block text-sm font-semibold text-gray-700 mb-2">
                Notes (optionnel)
              </label>
              <textarea
                value={notes}
                onChange={(e) => setNotes(e.target.value)}
                placeholder="Allergies, préférences, instructions spéciales..."
                rows={2}
                className="w-full px-4 py-3 border border-gray-200 rounded-lg focus:ring-2 focus:ring-orange-500 focus:border-transparent transition-all resize-none"
              />
            </div>
          </div>

          {/* Footer with validation hint */}
          <div className="bg-gray-50 px-6 py-4">
            {(!customerName.trim() || items.length === 0) && (
              <p className="text-xs text-orange-600 mb-3 text-center">
                {!customerName.trim() && items.length === 0
                  ? '⚠️ Entrez votre nom et sélectionnez au moins un article'
                  : !customerName.trim()
                    ? '⚠️ Entrez votre nom'
                    : '⚠️ Sélectionnez au moins un article'}
              </p>
            )}
            <div className="flex gap-3">
              <button
                type="button"
                onClick={onClose}
                className="flex-1 py-3 px-4 border border-gray-300 rounded-lg text-gray-700 font-medium hover:bg-gray-100 transition-colors"
              >
                Annuler
              </button>
              <button
                type="submit"
                disabled={!customerName.trim() || items.length === 0}
                className="flex-1 py-3 px-4 bg-gradient-to-r from-orange-500 to-red-500 rounded-lg text-white font-medium hover:from-orange-600 hover:to-red-600 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
              >
                🍽️ Créer la commande
              </button>
            </div>
          </div>
        </form>
      </div>
    </div>
  );
}
