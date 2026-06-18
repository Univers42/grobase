/**
 * Auth Service
 * API calls for authentication operations
 */

import { apiRequest, setTokens, clearTokens } from './api';

export interface AuthUser {
  id: number;
  email: string;
  firstName: string;
  role: string;
}

// Map to frontend user format
export interface AuthUserMapped {
  id: number;
  email: string;
  name: string;
  role: string;
}

export interface AuthResponse {
  user: AuthUserMapped;
  accessToken?: string;
  refreshToken?: string;
}

// API wraps response in { success, data, ... }
interface ApiWrapper<T> {
  success: boolean;
  data: T;
}

interface RawAuthResponse {
  user: AuthUser;
  accessToken?: string;
  refreshToken?: string;
}

export interface RegisterData {
  email: string;
  password: string;
  firstName: string;
  telephoneNumber?: string;
  city?: string;
  gdprConsent: boolean;
  newsletterConsent?: boolean;
}

export interface LoginData {
  email: string;
  password: string;
}

/** Map API user to frontend format */
function mapUser(user: AuthUser): AuthUserMapped {
  return {
    id: user.id,
    email: user.email,
    name: user.firstName,
    role: user.role,
  };
}

/** Register a new user */
export async function register(data: RegisterData): Promise<AuthResponse> {
  const wrapper = await apiRequest<ApiWrapper<RawAuthResponse>>('/api/auth/register', {
    method: 'POST',
    body: data,
  });
  const response = wrapper.data;
  setTokens(response.accessToken, response.refreshToken);
  return { ...response, user: mapUser(response.user) };
}

export async function login(data: LoginData): Promise<AuthResponse> {
  const wrapper = await apiRequest<ApiWrapper<RawAuthResponse>>('/api/auth/login', {
    method: 'POST',
    body: data,
  });
  const response = wrapper.data;
  setTokens(response.accessToken, response.refreshToken);
  return { ...response, user: mapUser(response.user) };
}

/** Google OAuth login */
export async function googleLogin(credential: string): Promise<AuthResponse> {
  const wrapper = await apiRequest<ApiWrapper<RawAuthResponse>>('/api/auth/google/token', {
    method: 'POST',
    body: { credential },
  });
  const response = wrapper.data;
  setTokens(response.accessToken, response.refreshToken);
  return { ...response, user: mapUser(response.user) };
}

/** Request password reset email */
export async function forgotPassword(email: string): Promise<{ message: string }> {
  const wrapper = await apiRequest<ApiWrapper<{ message: string }>>('/api/auth/forgot-password', {
    method: 'POST',
    body: { email },
  });
  return wrapper.data;
}

/** Verify reset token validity */
export async function verifyResetToken(
  token: string,
): Promise<{ valid: boolean; message: string }> {
  const wrapper = await apiRequest<ApiWrapper<{ valid: boolean; message: string }>>(
    '/api/auth/verify-reset-token',
    {
      method: 'POST',
      body: { token },
    },
  );
  return wrapper.data;
}

/** Reset password with token */
export async function resetPassword(token: string, password: string): Promise<{ message: string }> {
  const wrapper = await apiRequest<ApiWrapper<{ message: string }>>('/api/auth/reset-password', {
    method: 'POST',
    body: { token, newPassword: password },
  });
  return wrapper.data;
}

/** Logout user */
export function logout(): void {
  void apiRequest('/api/auth/logout', { method: 'POST' }).catch(() => undefined);
  clearTokens();
}

/** Get Google OAuth client ID from backend */
export async function getGoogleConfig(): Promise<{ clientId: string | null }> {
  try {
    const wrapper =
      await apiRequest<ApiWrapper<{ clientId: string | null }>>('/api/auth/google/config');
    return wrapper.data;
  } catch {
    // If endpoint doesn't exist or fails, return null
    return { clientId: null };
  }
}

/** Get current user profile */
export async function getProfile(): Promise<AuthUserMapped> {
  const wrapper = await apiRequest<ApiWrapper<AuthUser>>('/api/auth/me');
  setTokens();
  return mapUser(wrapper.data);
}
