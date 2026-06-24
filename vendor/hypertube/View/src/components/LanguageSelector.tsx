import { useI18n } from '../i18n/I18nContext.tsx';
import { LANGUAGES, LANGUAGE_LABELS, type Lang } from '../i18n/dictionary.ts';

/** LanguageSelector renders a preferred-language dropdown bound to the i18n ctx. */
export function LanguageSelector() {
  const { lang, setLang, t } = useI18n();
  return (
    <label className="lang-select">
      <span className="visually-hidden">{t('nav.language')}</span>
      <select aria-label={t('nav.language')} value={lang} onChange={(e) => setLang(e.target.value as Lang)}>
        {LANGUAGES.map((l) => (
          <option key={l} value={l}>
            {LANGUAGE_LABELS[l]}
          </option>
        ))}
      </select>
    </label>
  );
}
