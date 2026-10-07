import js from '@eslint/js';
import globals from 'globals';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  { ignores: ['dist', 'release', 'node_modules', 'bin'] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ['src/**/*.{ts,tsx}', 'tests/**/*.ts'],
    languageOptions: {
      ecmaVersion: 2022,
      globals: { ...globals.browser, ...globals.node },
    },
    rules: {
      '@typescript-eslint/no-explicit-any': 'off',
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
      '@typescript-eslint/naming-convention': [
        'error',
        { selector: 'function', format: ['camelCase'] },
        { selector: 'method', format: ['camelCase'] },
      ],
    },
  },
  {
    files: ['build/**/*.js', 'tests/*.js'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: { ...globals.node, ...globals.browser },
    },
    rules: {
      'no-undef': 'off',
      'no-unused-vars': 'off',
      '@typescript-eslint/naming-convention': [
        'error',
        { selector: 'function', format: ['camelCase'] },
        { selector: 'method', format: ['camelCase'] },
      ],
    },
  },
);
