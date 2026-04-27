const js = require('@eslint/js');
const globals = require('globals');
const tsParser = require('@typescript-eslint/parser');
const tsPlugin = require('@typescript-eslint/eslint-plugin');
const reactPlugin = require('eslint-plugin-react');

const sourceFiles = ['**/*.{js,jsx,cjs,mjs,ts,tsx,cts,mts}'];
const sanitizeGlobals = (entries) =>
  Object.fromEntries(Object.entries(entries).map(([name, value]) => [name.trim(), value]));

module.exports = [
  {
    ignores: [
      'node_modules/**',
      'out/**',
      'dist/**',
      'release/**',
      'coverage/**',
      'src/renderer/public/**',
      'src/renderer/WebSDK/**',
      'src/renderer/MotionSync/**',
    ],
  },
  {
    ...js.configs.recommended,
    files: sourceFiles,
    languageOptions: {
      ...js.configs.recommended.languageOptions,
      parser: tsParser,
      ecmaVersion: 'latest',
      sourceType: 'module',
      parserOptions: {
        ecmaFeatures: {
          jsx: true,
        },
      },
      globals: {
        ...sanitizeGlobals(globals.builtin),
      },
    },
    plugins: {
      '@typescript-eslint': tsPlugin,
      react: reactPlugin,
    },
    settings: {
      react: {
        version: 'detect',
      },
    },
    rules: {
      ...js.configs.recommended.rules,
      ...tsPlugin.configs.recommended.rules,
      ...reactPlugin.configs.recommended.rules,
      'no-console': 'off',
      'no-constant-condition': ['error', { checkLoops: false }],
      'no-empty': ['error', { allowEmptyCatch: true }],
      'no-undef': 'off',
      'no-unused-vars': 'off',
      'max-len': 'off',
      quotes: 'off',
      'operator-linebreak': 'off',
      'consistent-return': 'off',
      '@typescript-eslint/no-explicit-any': 'off',
      '@typescript-eslint/no-var-requires': 'off',
      '@typescript-eslint/no-unused-vars': 'off',
      'react/display-name': 'off',
      'react/jsx-filename-extension': ['warn', { extensions: ['.tsx', '.jsx'] }],
      'react/jsx-props-no-spreading': 'off',
      'react/prop-types': 'off',
      'react/react-in-jsx-scope': 'off',
      'react/require-default-props': 'off',
    },
  },
  {
    files: ['src/renderer/**/*.{js,jsx,cjs,mjs,ts,tsx,cts,mts}'],
    languageOptions: {
      globals: {
        ...sanitizeGlobals(globals.browser),
        ...sanitizeGlobals(globals.node),
      },
    },
  },
  {
    files: [
      'src/main/**/*.{js,cjs,mjs,ts,cts,mts}',
      'src/preload/**/*.{js,cjs,mjs,ts,cts,mts}',
      '*.{js,cjs,mjs,ts,cts,mts}',
    ],
    languageOptions: {
      globals: {
        ...sanitizeGlobals(globals.node),
      },
    },
  },
];
