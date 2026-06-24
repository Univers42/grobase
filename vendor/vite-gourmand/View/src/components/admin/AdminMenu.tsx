/**
 * AdminMenu - Menu management for admin role
 */

import { DatabaseViewer } from '../database';
import './AdminWidgets.css';

export function AdminMenu() {
  return (
    <div className="admin-widget admin-widget--database">
      <DatabaseViewer initialTable="Menu" />
    </div>
  );
}
