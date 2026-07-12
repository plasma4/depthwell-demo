import js from "@eslint/js";
import globals from "globals";
import tseslint from "typescript-eslint";
import pluginVue from "eslint-plugin-vue";
import { defineConfig } from "eslint/config";

export default defineConfig([
    js.configs.recommended,
    ...tseslint.configs.recommended,
    ...pluginVue.configs["flat/essential"],

    {
        files: ["**/*.{js,mjs,cjs,ts,mts,cts,vue}"],
        languageOptions: {
            globals: globals.browser,
            parserOptions: {
                parser: tseslint.parser, // Handles TS inside Vue files
            },
        },
    },
]);
