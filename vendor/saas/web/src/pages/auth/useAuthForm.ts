// useAuthForm.ts — shared submit/error/loading state for the auth forms. Wraps an
// async action with config-guarded error reporting so each page stays small.

import { useState } from 'react';
import { assertConfigured } from '../../lib/config';
import { useBaas } from '../../providers/useBaas';

/** AuthFormState exposes the submit wrapper plus error/loading state. */
export type AuthFormState = {
  error: string | null;
  loading: boolean;
  submit: (action: () => Promise<void>) => Promise<void>;
};

/** useAuthForm returns a submit() that runs an action with config + error guards. */
export function useAuthForm(): AuthFormState {
  const { config } = useBaas();
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const submit = async (action: () => Promise<void>) => {
    setError(null);
    setLoading(true);
    try {
      assertConfigured(config);
      await action();
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Something went wrong');
    } finally {
      setLoading(false);
    }
  };

  return { error, loading, submit };
}
