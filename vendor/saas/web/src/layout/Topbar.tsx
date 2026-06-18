// Topbar.tsx — the dashboard top bar: a search field and a user menu (Radix
// DropdownMenu) with sign-out. The user identity comes from useAuth via context.

import { useNavigate } from 'react-router-dom';
import * as Dropdown from '@radix-ui/react-dropdown-menu';
import { useAuth } from '../providers/useAuth';
import { useToast } from '../providers/useToast';
import { Icon } from '../ds/Icon';
import { Avatar } from '../ds/Avatar';

/** Topbar renders the search input and the account dropdown. */
export function Topbar() {
  const { user, signOut } = useAuth();
  const toast = useToast();
  const navigate = useNavigate();
  const name = user?.username || user?.email || 'Account';

  const onSignOut = async () => {
    await signOut();
    toast.success('Signed out');
    navigate('/login');
  };

  return (
    <header className="glass flex h-14 items-center gap-3 rounded-2xl px-3">
      <label className="flex h-9 flex-1 items-center gap-2 rounded-xl border border-line bg-surface-2/60 px-3 text-sm text-muted focus-within:border-accent/50">
        <Icon name="search" size={16} />
        <input type="search" placeholder="Search…" className="h-full w-full bg-transparent text-ink outline-none placeholder:text-muted/60" aria-label="Search" />
      </label>
      <button type="button" className="grid size-9 place-items-center rounded-xl text-muted hover:bg-white/5 hover:text-ink" aria-label="Notifications">
        <Icon name="bell" size={18} />
      </button>
      <Dropdown.Root>
        <Dropdown.Trigger className="flex items-center gap-2 rounded-xl py-1 pl-1 pr-2 hover:bg-white/5" aria-label="Account menu">
          <Avatar name={name} size={30} />
          <Icon name="chevronDown" size={14} className="text-muted" />
        </Dropdown.Trigger>
        <Dropdown.Portal>
          <Dropdown.Content align="end" sideOffset={8} className="glass z-50 min-w-52 rounded-xl p-1.5 text-sm">
            <div className="px-2.5 py-2 text-xs text-muted">
              Signed in as
              <p className="truncate font-medium text-ink">{name}</p>
            </div>
            <Dropdown.Separator className="my-1 h-px bg-line" />
            <Dropdown.Item onSelect={onSignOut} className="flex cursor-pointer items-center gap-2 rounded-lg px-2.5 py-2 text-danger outline-none data-[highlighted]:bg-danger/10">
              <Icon name="logout" size={16} />
              Sign out
            </Dropdown.Item>
          </Dropdown.Content>
        </Dropdown.Portal>
      </Dropdown.Root>
    </header>
  );
}
