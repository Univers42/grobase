/**
 * useAuth - Auth form state management
 */

import { useState, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import * as authService from '../../services/auth';
import { useToast } from '../../contexts/ToastContext';
import type { AuthMode, FormState, FormErrors } from './types';
import { initialFormState } from './types';

export function useAuth() {
  const navigate = useNavigate();
  const { addToast } = useToast();
  const [mode, setMode] = useState<AuthMode>('login');
  const [form, setForm] = useState<FormState>(initialFormState);
  const [errors, setErrors] = useState<FormErrors>({});
  const [loading, setLoading] = useState(false);
  const [success, setSuccess] = useState<string | null>(null);

  const updateField = useCallback(<K extends keyof FormState>(field: K, value: FormState[K]) => {
    setForm((prev) => ({ ...prev, [field]: value }));
    setErrors((prev) => ({ ...prev, [field]: undefined, general: undefined }));
  }, []);

  const validate = useCallback((): boolean => {
    const newErrors: FormErrors = {};

    if (!form.email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(form.email)) {
      newErrors.email = 'Email invalide';
    }

    if (mode !== 'forgot') {
      if (!form.password || form.password.length < 8) {
        newErrors.password = 'Minimum 8 caractères';
      }
    }

    if (mode === 'register') {
      if (!form.name || form.name.length < 2) {
        newErrors.name = 'Nom requis (min 2 caractères)';
      }
      if (form.password !== form.confirmPassword) {
        newErrors.confirmPassword = 'Les mots de passe ne correspondent pas';
      }
      if (!form.gdprConsent) {
        newErrors.gdprConsent = 'Consentement RGPD requis';
      }
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  }, [form, mode]);

  const handleSubmit = useCallback(async () => {
    if (!validate()) return;

    setLoading(true);
    setErrors({});
    setSuccess(null);

    try {
      switch (mode) {
        case 'login':
          await authService.login({ email: form.email, password: form.password });
          addToast('Connexion réussie ! Bienvenue.', 'success');
          navigate('/');
          break;
        case 'register':
          await authService.register({
            email: form.email,
            password: form.password,
            firstName: form.name,
            telephoneNumber: form.phone || undefined,
            gdprConsent: form.gdprConsent,
          });
          addToast('Inscription réussie ! Bienvenue sur Vite Gourmand.', 'success');
          navigate('/');
          break;
        case 'forgot':
          await authService.forgotPassword(form.email);
          setSuccess('Email de réinitialisation envoyé !');
          addToast('Un email de réinitialisation a été envoyé à votre adresse.', 'success', 7000);
          break;
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Une erreur est survenue';
      setErrors({ general: msg });
      addToast(msg, 'error');
    } finally {
      setLoading(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [form, mode, navigate, validate]);

  const handleGoogleLogin = useCallback(
    async (credential: string) => {
      setLoading(true);
      try {
        await authService.googleLogin(credential);
        navigate('/');
      } catch (err) {
        setErrors({ general: err instanceof Error ? err.message : 'Échec Google OAuth' });
      } finally {
        setLoading(false);
      }
    },
    [navigate],
  );

  const switchMode = useCallback((newMode: AuthMode) => {
    setMode(newMode);
    setForm(initialFormState);
    setErrors({});
    setSuccess(null);
  }, []);

  return {
    mode,
    form,
    errors,
    loading,
    success,
    updateField,
    handleSubmit,
    handleGoogleLogin,
    switchMode,
  };
}
