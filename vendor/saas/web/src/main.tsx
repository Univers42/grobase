// main.tsx — the app entry. Mounts the router under the two providers: BaasProvider
// (constructs + injects the client once) and ToastProvider (the notification queue).

import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { RouterProvider } from 'react-router-dom';
import { BaasProvider } from './providers/BaasProvider';
import { ToastProvider } from './providers/ToastProvider';
import { router } from './routes';
import './styles/app.css';

const root = document.getElementById('root');
if (!root) throw new Error('Nimbus: #root element missing from index.html');

createRoot(root).render(
  <StrictMode>
    <BaasProvider>
      <ToastProvider>
        <RouterProvider router={router} />
      </ToastProvider>
    </BaasProvider>
  </StrictMode>,
);
