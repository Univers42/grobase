// Flat ESLint config for the Grobase marketing site (Astro).
// Run inside Docker only: `npm run lint` (wrapped by scripts/container-only.mjs).
import js from '@eslint/js';
import globals from 'globals';
import tseslint from 'typescript-eslint';
import astro from 'eslint-plugin-astro';

export default tseslint.config(
	{
		ignores: [
			'dist/',
			'.astro/',
			'node_modules/',
			'public/',
			'test-results/',
			'**/*.min.*',
			'package-lock.json',
		],
	},
	js.configs.recommended,
	...tseslint.configs.recommended,
	...astro.configs['flat/recommended'],
	...astro.configs['flat/jsx-a11y-recommended'],
	{
		languageOptions: {
			globals: { ...globals.browser, ...globals.node },
		},
		rules: {
			'no-unused-vars': 'off',
			'@typescript-eslint/no-unused-vars': [
				'warn',
				{ argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
			],
			'no-empty': ['warn', { allowEmptyCatch: true }],
			// role="list" on <ul>/<ol> is kept on purpose: Safari/VoiceOver drops
			// list semantics when list-style:none is set.
			'astro/jsx-a11y/no-redundant-roles': ['error', { ul: ['list'], ol: ['list'] }],
		},
	},
	{
		files: ['**/*.config.{mjs,js,ts}'],
		rules: { '@typescript-eslint/ban-ts-comment': 'off' },
	},
);
