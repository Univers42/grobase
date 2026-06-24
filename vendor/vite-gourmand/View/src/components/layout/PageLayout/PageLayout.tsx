/**
 * PageLayout - Main content area layout
 * Used for wrapping page content
 */

import './PageLayout.css';

interface PageLayoutProps {
  children: React.ReactNode;
  title?: string;
  actions?: React.ReactNode;
}

export function PageLayout({ children, title, actions }: Readonly<PageLayoutProps>) {
  return (
    <div className="page-layout">
      {(title || actions) && <PageHeader title={title} actions={actions} />}
      <div className="page-content">{children}</div>
    </div>
  );
}

function PageHeader({ title, actions }: Readonly<{ title?: string; actions?: React.ReactNode }>) {
  return (
    <div className="page-header">
      {title && <h2 className="page-title">{title}</h2>}
      {actions && <div className="page-actions">{actions}</div>}
    </div>
  );
}
