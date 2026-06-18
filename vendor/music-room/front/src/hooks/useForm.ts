import { useState, useCallback } from 'react';

interface FormField<T> {
  value: T;
  error: string | null;
  touched: boolean;
}

type FormFields<T> = {
  [K in keyof T]: FormField<T[K]>;
};

type ValidationRules<T> = {
  [K in keyof T]?: (value: T[K], allValues: T) => string | null;
};

/**
 * Hook for managing form state with validation
 */
export function useForm<T extends Record<string, unknown>>(
  initialValues: T,
  validationRules?: ValidationRules<T>,
) {
  const createInitialFields = (): FormFields<T> => {
    const fields = {} as FormFields<T>;
    for (const key in initialValues) {
      fields[key] = {
        value: initialValues[key],
        error: null,
        touched: false,
      } as FormField<T[typeof key]>;
    }
    return fields;
  };

  const [fields, setFields] = useState<FormFields<T>>(createInitialFields);
  const [isSubmitting, setIsSubmitting] = useState(false);

  const getValues = useCallback((): T => {
    const values = {} as T;
    for (const key in fields) {
      values[key] = fields[key].value;
    }
    return values;
  }, [fields]);

  const setValue = useCallback(
    <K extends keyof T>(field: K, value: T[K]) => {
      setFields((prev) => ({
        ...prev,
        [field]: {
          ...prev[field],
          value,
          touched: true,
          error: validationRules?.[field]
            ? validationRules[field]!(value, getValues())
            : null,
        },
      }));
    },
    [validationRules, getValues],
  );

  const setError = useCallback(<K extends keyof T>(field: K, error: string | null) => {
    setFields((prev) => ({
      ...prev,
      [field]: { ...prev[field], error },
    }));
  }, []);

  const setTouched = useCallback(<K extends keyof T>(field: K) => {
    setFields((prev) => ({
      ...prev,
      [field]: { ...prev[field], touched: true },
    }));
  }, []);

  const validateAll = useCallback((): boolean => {
    if (!validationRules) return true;

    const values = getValues();
    let isValid = true;
    const newFields = { ...fields };

    for (const key in validationRules) {
      const rule = validationRules[key];
      if (rule) {
        const error = rule(values[key], values);
        (newFields[key] as FormField<T[typeof key]>).error = error;
        (newFields[key] as FormField<T[typeof key]>).touched = true;
        if (error) isValid = false;
      }
    }

    setFields(newFields);
    return isValid;
  }, [fields, validationRules, getValues]);

  const reset = useCallback(() => {
    setFields(createInitialFields());
    setIsSubmitting(false);
  }, []);

  const handleSubmit = useCallback(
    async (onSubmit: (values: T) => Promise<void> | void) => {
      if (!validateAll()) return;

      setIsSubmitting(true);
      try {
        await onSubmit(getValues());
      } finally {
        setIsSubmitting(false);
      }
    },
    [validateAll, getValues],
  );

  const hasErrors = Object.values(fields).some(
    (field) => (field as FormField<unknown>).error !== null,
  );

  const isDirty = Object.keys(fields).some(
    (key) =>
      (fields[key as keyof T] as FormField<unknown>).value !==
      initialValues[key as keyof T],
  );

  return {
    fields,
    values: getValues(),
    setValue,
    setError,
    setTouched,
    validateAll,
    reset,
    handleSubmit,
    isSubmitting,
    hasErrors,
    isDirty,
  };
}
