/**
 * API error interceptor for the frontend.
 * Handles common HTTP errors and token refresh logic.
 */
import { AxiosError, AxiosInstance, InternalAxiosRequestConfig } from 'axios';

interface TokenPair {
  accessToken: string;
  refreshToken: string;
}

let isRefreshing = false;
let failedQueue: Array<{
  resolve: (token: string) => void;
  reject: (error: Error) => void;
}> = [];

const processQueue = (error: Error | null, token: string | null = null) => {
  failedQueue.forEach((prom) => {
    if (error) {
      prom.reject(error);
    } else if (token) {
      prom.resolve(token);
    }
  });
  failedQueue = [];
};

export function setupInterceptors(
  api: AxiosInstance,
  getTokens: () => TokenPair | null,
  setTokens: (tokens: TokenPair) => void,
  clearTokens: () => void,
  refreshEndpoint: string = '/auth/refresh',
) {
  // Request interceptor: attach access token
  api.interceptors.request.use(
    (config: InternalAxiosRequestConfig) => {
      const tokens = getTokens();
      if (tokens?.accessToken) {
        config.headers.Authorization = `Bearer ${tokens.accessToken}`;
      }
      return config;
    },
    (error) => Promise.reject(error),
  );

  // Response interceptor: handle 401 with token refresh
  api.interceptors.response.use(
    (response) => response,
    async (error: AxiosError) => {
      const originalRequest = error.config as InternalAxiosRequestConfig & {
        _retry?: boolean;
      };

      // Don't retry if it's the refresh endpoint itself
      if (originalRequest?.url === refreshEndpoint) {
        clearTokens();
        return Promise.reject(error);
      }

      // Handle 401 with token refresh
      if (error.response?.status === 401 && !originalRequest?._retry) {
        if (isRefreshing) {
          return new Promise<string>((resolve, reject) => {
            failedQueue.push({ resolve, reject });
          }).then((token) => {
            if (originalRequest) {
              originalRequest.headers.Authorization = `Bearer ${token}`;
              return api(originalRequest);
            }
          });
        }

        originalRequest._retry = true;
        isRefreshing = true;

        const tokens = getTokens();
        if (!tokens?.refreshToken) {
          clearTokens();
          return Promise.reject(error);
        }

        try {
          const { data } = await api.post<TokenPair>(refreshEndpoint, {
            refreshToken: tokens.refreshToken,
          });

          setTokens(data);
          processQueue(null, data.accessToken);

          if (originalRequest) {
            originalRequest.headers.Authorization = `Bearer ${data.accessToken}`;
            return api(originalRequest);
          }
        } catch (refreshError) {
          processQueue(refreshError as Error, null);
          clearTokens();
          return Promise.reject(refreshError);
        } finally {
          isRefreshing = false;
        }
      }

      // Handle other errors
      if (error.response?.status === 403) {
        console.warn('Access forbidden:', originalRequest?.url);
      }

      if (error.response?.status === 429) {
        console.warn('Rate limited:', originalRequest?.url);
      }

      return Promise.reject(error);
    },
  );
}
