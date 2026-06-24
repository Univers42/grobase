// AppShell.tsx — the authenticated dashboard frame: a fixed glass sidebar, a top
// bar, and the routed content in the #main landmark. Suspense covers lazy pages.

import { Suspense } from 'react';
import { Outlet } from 'react-router-dom';
import { SkipLink } from './SkipLink';
import { Sidebar } from './Sidebar';
import { Topbar } from './Topbar';
import { Spinner } from '../ds/Spinner';

/** AppShell lays out the sidebar + topbar + routed content grid. */
export function AppShell() {
  return (
    <div className="min-h-screen p-3 md:p-4">
      <SkipLink />
      <div className="mx-auto grid max-w-[1400px] gap-3 md:grid-cols-[16rem_1fr] md:gap-4">
        <div className="md:sticky md:top-4 md:h-[calc(100vh-2rem)]">
          <Sidebar />
        </div>
        <div className="flex min-w-0 flex-col gap-3 md:gap-4">
          <Topbar />
          <main id="main" tabIndex={-1} className="min-w-0 flex-1 outline-none">
            <Suspense fallback={<div className="grid place-items-center py-32"><Spinner size={28} /></div>}>
              <Outlet />
            </Suspense>
          </main>
        </div>
      </div>
    </div>
  );
}
