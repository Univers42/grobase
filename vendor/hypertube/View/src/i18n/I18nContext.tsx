import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from 'react';
import { DICTIONARIES, LANGUAGES, type Lang, type MessageKey } from './dictionary.ts';

const STORAGE_KEY = 'hypertube.lang';

type I18nValue = {
  lang: Lang;
  setLang: (l: Lang) => void;
  t: (key: MessageKey) => string;
};

const I18nContext = createContext<I18nValue | null>(null);

/** initialLang reads the stored preference, defaulting to English. */
function initialLang(): Lang {
  const stored = typeof localStorage !== 'undefined' ? localStorage.getItem(STORAGE_KEY) : null;
  return (LANGUAGES as readonly string[]).includes(stored ?? '') ? (stored as Lang) : 'en';
}

/** I18nProvider supplies the current language and the t() translator. */
export function I18nProvider({ children }: { children: ReactNode }) {
  const [lang, setLangState] = useState<Lang>(initialLang);
  const setLang = useCallback((l: Lang) => {
    setLangState(l);
    localStorage.setItem(STORAGE_KEY, l);
    document.documentElement.lang = l;
  }, []);
  const t = useCallback((key: MessageKey) => DICTIONARIES[lang][key] ?? key, [lang]);
  const value = useMemo(() => ({ lang, setLang, t }), [lang, setLang, t]);
  return <I18nContext value={value}>{children}</I18nContext>;
}

/** useI18n returns the translator context, throwing outside the provider. */
export function useI18n(): I18nValue {
  const ctx = useContext(I18nContext);
  if (!ctx) throw new Error('useI18n must be used within I18nProvider');
  return ctx;
}
