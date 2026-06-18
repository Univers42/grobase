/**
 * Input Types - Shared type definitions for all input variants
 */

export type InputSize = 'sm' | 'md' | 'lg';

export interface InputBaseProps {
  id: string;
  name: string;
  label?: string;
  placeholder?: string;
  disabled?: boolean;
  required?: boolean;
  error?: string;
  size?: InputSize;
}
