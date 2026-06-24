import js from '@eslint/js';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  { ignores: ['dist', 'node_modules', 'public', 'serve.mjs', 'build-css.sh'] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ['src/**/*.{ts,tsx}'],
    languageOptions: { ecmaVersion: 2022, sourceType: 'module' },
    rules: {
      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/consistent-type-imports': 'warn',
      'no-restricted-syntax': [
        'error',
        { selector: 'TSEnumDeclaration', message: 'No enums — use a const object with `as const`.' },
        { selector: 'ExportDefaultDeclaration', message: 'Named exports only — no default exports.' },
      ],
    },
  },
  {
    files: ['vite.config.ts', 'playwright.config.ts'],
    languageOptions: { ecmaVersion: 2022, sourceType: 'module', globals: { process: 'readonly' } },
  },
);
