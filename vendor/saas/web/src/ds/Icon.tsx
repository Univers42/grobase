// Icon.tsx — thin re-export of lucide icons by name with a consistent default size
// and stroke, so call sites stay terse and the icon set is centralized.

import {
  LayoutDashboard, Users, Inbox, BarChart3, FileText, Search, LogOut, ChevronDown,
  ChevronRight, ChevronLeft, ArrowUp, ArrowDown, ArrowRight, Check, X, Loader2, Bell,
  Settings, Plus, Sparkles, ShieldCheck, Zap, Database, Menu, AlertCircle, CircleCheck,
  Info, TrendingUp,
} from 'lucide-react';
import type { LucideIcon } from 'lucide-react';

/** icons is the name → component registry the UI references. */
export const icons = {
  dashboard: LayoutDashboard, users: Users, inbox: Inbox, revenue: BarChart3, content: FileText,
  search: Search, logout: LogOut, chevronDown: ChevronDown, chevronRight: ChevronRight,
  chevronLeft: ChevronLeft, up: ArrowUp, down: ArrowDown, arrowRight: ArrowRight, check: Check,
  close: X, spinner: Loader2, bell: Bell, settings: Settings, plus: Plus, sparkles: Sparkles,
  shield: ShieldCheck, zap: Zap, database: Database, menu: Menu, alert: AlertCircle,
  ok: CircleCheck, info: Info, trend: TrendingUp,
} satisfies Record<string, LucideIcon>;

/** IconName is a valid key of the icon registry. */
export type IconName = keyof typeof icons;

/** IconProps selects an icon by name with optional size/class overrides. */
export type IconProps = { name: IconName; size?: number; className?: string; 'aria-hidden'?: boolean };

/** Icon renders a registered lucide glyph, hidden from a11y by default. */
export function Icon({ name, size = 18, className, ...rest }: IconProps) {
  const Glyph = icons[name];
  return <Glyph size={size} strokeWidth={1.8} className={className} aria-hidden {...rest} />;
}
