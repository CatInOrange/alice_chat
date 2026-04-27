export const lunariaColors = {
  appBg: "#f6efe8",
  appBgSoft: "#fbf7f3",
  surface: "#fffaf5",
  surfaceAlt: "#fff7f2",
  surfaceMuted: "#fcf4ec",
  card: "#fffaf5",
  cardStrong: "#fffdfb",
  border: "rgba(158, 132, 118, 0.18)",
  borderStrong: "rgba(158, 132, 118, 0.28)",
  text: "#5b463c",
  textMuted: "#8f786b",
  textSubtle: "#b39f95",
  heading: "#49362f",
  primary: "#dc8d79",
  primaryStrong: "#c86f59",
  primarySoft: "#f6d8cf",
  secondary: "#cfddd5",
  secondaryStrong: "#7a9488",
  success: "#7fa58f",
  warning: "#d6a56f",
  danger: "#d5857b",
  info: "#85a8bc",
} as const;

export const lunariaRadii = {
  input: "16px",
  card: "22px",
  panel: "26px",
  pill: "999px",
} as const;

export const lunariaShadows = {
  soft: "0 10px 24px rgba(121, 93, 77, 0.08)",
  panel: "0 24px 64px rgba(121, 93, 77, 0.12)",
  floating: "0 18px 48px rgba(121, 93, 77, 0.16)",
} as const;

export const lunariaBackgroundImage = `
  radial-gradient(circle at top left, rgba(255, 224, 211, 0.78), transparent 30%),
  radial-gradient(circle at bottom right, rgba(210, 226, 217, 0.72), transparent 28%),
  linear-gradient(180deg, #fbf7f3 0%, #f4ece4 100%)
`;

export const lunariaPanelStyles = {
  bg: lunariaColors.surface,
  border: `1px solid ${lunariaColors.border}`,
  borderRadius: lunariaRadii.panel,
  boxShadow: lunariaShadows.panel,
} as const;

export const lunariaCardStyles = {
  bg: lunariaColors.cardStrong,
  border: `1px solid ${lunariaColors.border}`,
  borderRadius: lunariaRadii.card,
  boxShadow: lunariaShadows.soft,
} as const;

export const lunariaMutedCardStyles = {
  bg: lunariaColors.surfaceMuted,
  border: `1px solid ${lunariaColors.border}`,
  borderRadius: lunariaRadii.card,
  boxShadow: lunariaShadows.soft,
} as const;

export const lunariaEyebrowStyles = {
  fontSize: "11px",
  fontWeight: "700",
  letterSpacing: "0.16em",
  textTransform: "uppercase",
  color: lunariaColors.textSubtle,
} as const;

export const lunariaHeadingStyles = {
  color: lunariaColors.heading,
  fontWeight: "700",
  letterSpacing: "-0.02em",
} as const;

export const lunariaTextStyles = {
  color: lunariaColors.text,
} as const;

export const lunariaMutedTextStyles = {
  color: lunariaColors.textMuted,
} as const;

export const lunariaFieldStyles = {
  bg: lunariaColors.cardStrong,
  color: lunariaColors.text,
  border: `1px solid ${lunariaColors.borderStrong}`,
  borderRadius: lunariaRadii.input,
  minH: "48px",
  px: "4",
  _placeholder: { color: lunariaColors.textSubtle },
  _hover: {
    borderColor: lunariaColors.primary,
    bg: lunariaColors.card,
  },
  _focusVisible: {
    borderColor: lunariaColors.primaryStrong,
    boxShadow: `0 0 0 3px rgba(220, 141, 121, 0.18)`,
    bg: lunariaColors.cardStrong,
  },
} as const;

export const lunariaTextareaStyles = {
  ...lunariaFieldStyles,
  py: "3",
} as const;

export const lunariaIconButtonStyles = {
  borderRadius: lunariaRadii.pill,
  bg: lunariaColors.card,
  color: lunariaColors.text,
  border: `1px solid ${lunariaColors.border}`,
  boxShadow: lunariaShadows.soft,
  _hover: {
    bg: lunariaColors.cardStrong,
    borderColor: lunariaColors.primary,
    color: lunariaColors.heading,
  },
  _active: {
    bg: lunariaColors.primarySoft,
  },
} as const;

export const lunariaPrimaryButtonStyles = {
  borderRadius: lunariaRadii.pill,
  bg: lunariaColors.primary,
  color: "white",
  boxShadow: "0 14px 28px rgba(200, 111, 89, 0.22)",
  _hover: {
    bg: lunariaColors.primaryStrong,
  },
  _active: {
    bg: "#b9604d",
  },
} as const;

export const lunariaSecondaryButtonStyles = {
  borderRadius: lunariaRadii.pill,
  bg: lunariaColors.card,
  color: lunariaColors.text,
  border: `1px solid ${lunariaColors.border}`,
  _hover: {
    bg: lunariaColors.cardStrong,
    borderColor: lunariaColors.primary,
  },
} as const;

export const lunariaPillButtonStyles = {
  ...lunariaSecondaryButtonStyles,
  px: "3.5",
  h: "36px",
  fontSize: "sm",
  fontWeight: "600",
} as const;

export const lunariaCompactPillButtonStyles = {
  ...lunariaSecondaryButtonStyles,
  px: "3",
  h: "30px",
  fontSize: "12px",
  fontWeight: "600",
} as const;

export const lunariaNativeFieldStyles = {
  width: "100%",
  marginTop: 8,
  minHeight: 48,
  padding: "0 14px",
  borderRadius: 16,
  border: `1px solid ${lunariaColors.borderStrong}`,
  background: lunariaColors.cardStrong,
  color: lunariaColors.text,
  outline: "none",
} as const;

export const lunariaNativeTextareaStyles = {
  ...lunariaNativeFieldStyles,
  padding: "12px 14px",
  minHeight: 112,
  resize: "vertical" as const,
} as const;

export const lunariaNativeRangeStyles = {
  width: "100%",
  marginTop: 12,
  accentColor: lunariaColors.primary,
} as const;

export function getLunariaIntentStyles(
  intent: "neutral" | "primary" | "success" | "warning" | "danger" | "info" = "neutral",
) {
  if (intent === "primary") {
    return {
      bg: "#f6d8cf",
      color: lunariaColors.primaryStrong,
      borderColor: "rgba(220, 141, 121, 0.3)",
    };
  }

  if (intent === "success") {
    return {
      bg: "#deede4",
      color: "#5d7d69",
      borderColor: "rgba(127, 165, 143, 0.3)",
    };
  }

  if (intent === "warning") {
    return {
      bg: "#f8ebd6",
      color: "#9b6f40",
      borderColor: "rgba(214, 165, 111, 0.32)",
    };
  }

  if (intent === "danger") {
    return {
      bg: "#f8e2df",
      color: "#a75f59",
      borderColor: "rgba(213, 133, 123, 0.32)",
    };
  }

  if (intent === "info") {
    return {
      bg: "#e3eef4",
      color: "#5f7f92",
      borderColor: "rgba(133, 168, 188, 0.32)",
    };
  }

  return {
    bg: "#f7f1eb",
    color: lunariaColors.textMuted,
    borderColor: lunariaColors.border,
  };
}
