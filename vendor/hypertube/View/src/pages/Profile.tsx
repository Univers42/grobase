import { useEffect, useState, type FormEvent } from 'react';
import { useParams } from 'react-router-dom';
import { useAuth } from '../auth/AuthContext.tsx';
import { useI18n } from '../i18n/I18nContext.tsx';
import { getProfile, saveProfile } from '../baas/content.ts';
import { updateEmail } from '../baas/auth.ts';
import type { Profile as ProfileType } from '../baas/types.ts';

/** Profile views any user (never their email) and lets the owner edit own info. */
export function Profile() {
  const { userId = '' } = useParams();
  const { cfg, session } = useAuth();
  const { t } = useI18n();
  const isSelf = session?.userId === userId;
  const [profile, setProfile] = useState<ProfileType | null>(null);
  const [avatar, setAvatar] = useState('');
  const [email, setEmail] = useState('');

  useEffect(() => {
    getProfile(cfg, userId).then((p) => {
      setProfile(p);
      setAvatar(p?.avatar ?? '');
    });
  }, [cfg, userId]);

  const onSave = async (e: FormEvent) => {
    e.preventDefault();
    if (!isSelf) return;
    if (email.trim()) await updateEmail(cfg, email.trim()).catch(() => undefined);
    await saveProfile(cfg, { user_id: userId, avatar });
    setProfile((p) => (p ? { ...p, avatar } : p));
  };

  if (!profile) return <p className="empty">{t('common.error')}</p>;

  return (
    <section className="profile">
      <h1>{t('profile.title')}</h1>
      {profile.avatar && <img className="profile-avatar" src={profile.avatar} alt={profile.username} />}
      <dl className="profile-info">
        <dt>{t('auth.username')}</dt><dd>{profile.username}</dd>
        <dt>{t('auth.firstName')}</dt><dd>{profile.first_name}</dd>
        <dt>{t('auth.lastName')}</dt><dd>{profile.last_name}</dd>
      </dl>
      {isSelf && (
        <form onSubmit={onSave} className="profile-edit">
          <label>{t('auth.email')}<input type="email" value={email} onChange={(e) => setEmail(e.target.value)} /></label>
          <label>{t('profile.avatar')}<input type="url" value={avatar} onChange={(e) => setAvatar(e.target.value)} /></label>
          <button type="submit">{t('profile.save')}</button>
        </form>
      )}
    </section>
  );
}
