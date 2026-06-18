/**
 * Auth Form Types
 */

export type AuthMode = 'login' | 'register' | 'forgot' | 'reset';

export interface FormState {
  email: string;
  password: string;
  confirmPassword: string;
  name: string;
  phone: string;
  gdprConsent: boolean;
}

export interface FormErrors {
  email?: string;
  password?: string;
  confirmPassword?: string;
  name?: string;
  phone?: string;
  gdprConsent?: string;
  general?: string;
}

export const initialFormState: FormState = {
  email: '',
  password: '',
  confirmPassword: '',
  name: '',
  phone: '',
  gdprConsent: false,
};
