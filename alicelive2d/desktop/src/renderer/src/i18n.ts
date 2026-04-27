import i18n from "i18next";
import { initReactI18next } from "react-i18next";
import LanguageDetector from "i18next-browser-languagedetector";
import { normalizeSupportedLanguage } from "@/runtime/settings-panel-utils.ts";

// Import translation resources
import enTranslation from "./locales/en/translation.json";
import zhTranslation from "./locales/zh/translation.json";

// Configure i18next instance
i18n
  // Detect user language
  .use(LanguageDetector)
  // Pass the i18n instance to react-i18next
  .use(initReactI18next)
  // Initialize i18next
  .init({
    // Default language when detection fails
    fallbackLng: "en",
    supportedLngs: ["en", "zh"],
    nonExplicitSupportedLngs: true,
    load: "languageOnly",
    cleanCode: true,
    // Debug mode for development
    debug: process.env.NODE_ENV === "development",
    // Namespaces configuration
    defaultNS: "translation",
    ns: ["translation"],
    // Resources containing translations
    resources: {
      en: {
        translation: enTranslation,
      },
      zh: {
        translation: zhTranslation,
      },
    },
    // Language detection options
    detection: {
      // Order and from where user language should be detected
      order: ["localStorage", "navigator"],
      // Cache user language detection
      caches: ["localStorage"],
      convertDetectedLanguage: (lng) => normalizeSupportedLanguage(lng),
      // HTML attribute with which to set language
      htmlTag: document.documentElement,
    },
    // Escaping special characters
    interpolation: {
      escapeValue: false, // React already safes from XSS
    },
    // React config
    react: {
      useSuspense: true,
    },
  });

// Save language change to localStorage
i18n.on("languageChanged", (lng) => {
  const normalizedLanguage = normalizeSupportedLanguage(lng);
  localStorage.setItem("i18nextLng", normalizedLanguage);
  // Update HTML document lang attribute
  document.documentElement.lang = normalizedLanguage;
});

export default i18n;
