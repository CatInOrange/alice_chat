import { type ReactNode } from "react";
import { Box, Button, Flex, HStack, Stack, Text } from "@chakra-ui/react";
import { useTranslation } from "react-i18next";
import { useShallow } from "zustand/react/shallow";
import { getQuickActionLabel, useAppStore } from "@/domains/renderer-store";
import { useModelCommands } from "@/app/providers/command-provider";
import {
  lunariaCompactPillButtonStyles,
  lunariaColors,
  lunariaEyebrowStyles,
  lunariaMutedCardStyles,
  lunariaSecondaryButtonStyles,
} from "@/theme/lunaria-theme";

function ActionSection({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  return (
    <Stack gap="2">
      <Text {...lunariaEyebrowStyles}>
        {title}
      </Text>
      {children}
    </Stack>
  );
}

function Pills({ children }: { children: ReactNode }) {
  return (
    <Flex wrap="wrap" gap="2">
      {children}
    </Flex>
  );
}

export function WindowStageActionBar() {
  const { executeQuickAction } = useModelCommands();
  const { t } = useTranslation();
  const {
    quickActions,
    motions,
    expressions,
    persistentToggles,
    persistentToggleState,
    stageActionPanelOpen,
    setStageActionPanelOpen,
    togglePersistentToggle,
  } = useAppStore(useShallow((state) => ({
    quickActions: state.quickActions,
    motions: state.motions,
    expressions: state.expressions,
    persistentToggles: state.persistentToggles,
    persistentToggleState: state.persistentToggleState,
    stageActionPanelOpen: state.stageActionPanelOpen,
    setStageActionPanelOpen: state.setStageActionPanelOpen,
    togglePersistentToggle: state.togglePersistentToggle,
  })));

  if (
    quickActions.length === 0
    && motions.length === 0
    && expressions.length === 0
    && Object.keys(persistentToggles).length === 0
  ) {
    return null;
  }

  return (
    <Stack
      gap="3"
      px="4"
      py="3"
      {...lunariaMutedCardStyles}
    >
      {quickActions.length > 0 && (
        <ActionSection title={t("stageActions.quickActions")}>
          <Pills>
            {quickActions.map((action, index) => (
              <Button
                key={`${String(action.id || action.label || action.type)}_${index}`}
                size="sm"
                {...lunariaCompactPillButtonStyles}
                onClick={() => void executeQuickAction(action)}
              >
                {getQuickActionLabel(action)}
              </Button>
            ))}
          </Pills>
        </ActionSection>
      )}

      <HStack justify="space-between">
        <Text fontSize="sm" color={lunariaColors.textMuted}>
          {t("stageActions.title")}
        </Text>
        <Button
          size="xs"
          {...lunariaSecondaryButtonStyles}
          onClick={() => setStageActionPanelOpen(!stageActionPanelOpen)}
        >
          {stageActionPanelOpen ? t("common.collapse") : t("common.expand")}
        </Button>
      </HStack>

      {stageActionPanelOpen && (
        <Stack gap="3">
          {Object.keys(persistentToggles).length > 0 && (
            <ActionSection title={t("stageActions.persistent")}>
              <Pills>
                {Object.entries(persistentToggles).map(([id, config]) => (
                  <Button
                    key={id}
                    size="sm"
                    {...lunariaCompactPillButtonStyles}
                    bg={persistentToggleState[id] ? lunariaColors.primarySoft : lunariaSecondaryButtonStyles.bg}
                    color={persistentToggleState[id] ? lunariaColors.primaryStrong : lunariaColors.text}
                    onClick={() => togglePersistentToggle(id)}
                  >
                    {persistentToggleState[id]
                      ? (config.onLabel || id)
                      : (config.offLabel || config.key || id)}
                  </Button>
                ))}
              </Pills>
            </ActionSection>
          )}

          {motions.length > 0 && (
            <ActionSection title={t("stageActions.motions")}>
              <Pills>
                {motions.map((motion) => (
                  <Button
                    key={`${motion.group}-${motion.index}-${motion.file}`}
                    size="sm"
                    {...lunariaCompactPillButtonStyles}
                    onClick={() => void executeQuickAction({
                      type: "motion",
                      group: motion.group,
                      index: motion.index,
                      label: motion.label || motion.name,
                    })}
                  >
                    {motion.label || `${motion.group}:${motion.index}`}
                  </Button>
                ))}
              </Pills>
            </ActionSection>
          )}

          {expressions.length > 0 && (
            <ActionSection title={t("stageActions.expressions")}>
              <Pills>
                {expressions.map((expression) => (
                  <Button
                    key={`${expression.name}-${expression.index}`}
                    size="sm"
                    {...lunariaCompactPillButtonStyles}
                    onClick={() => void executeQuickAction({
                      type: "expression",
                      name: expression.name,
                      label: expression.name,
                    })}
                  >
                    {expression.name}
                  </Button>
                ))}
              </Pills>
            </ActionSection>
          )}
        </Stack>
      )}
    </Stack>
  );
}

export function PetActionSheet({
  onBack,
}: {
  onBack: () => void;
}) {
  const { executeQuickAction } = useModelCommands();
  const { t } = useTranslation();
  const {
    quickActions,
    motions,
    expressions,
    persistentToggles,
    persistentToggleState,
    togglePersistentToggle,
  } = useAppStore(useShallow((state) => ({
    quickActions: state.quickActions,
    motions: state.motions,
    expressions: state.expressions,
    persistentToggles: state.persistentToggles,
    persistentToggleState: state.persistentToggleState,
    togglePersistentToggle: state.togglePersistentToggle,
  })));

  return (
    <Box
      mt="3"
      p="3"
      {...lunariaMutedCardStyles}
    >
      <HStack justify="space-between" mb="3">
        <Text fontSize="sm" color={lunariaColors.text}>
          {t("stageActions.title")}
        </Text>
        <Button
          size="xs"
          {...lunariaSecondaryButtonStyles}
          onClick={onBack}
        >
          {t("common.back")}
        </Button>
      </HStack>

      <Stack gap="4">
        {quickActions.length > 0 && (
          <ActionSection title={t("stageActions.quickActions")}>
            <Pills>
              {quickActions.map((action, index) => (
                <Button
                  key={`${String(action.id || action.label || action.type)}_${index}`}
                  size="sm"
                  {...lunariaCompactPillButtonStyles}
                  onClick={() => void executeQuickAction(action)}
                >
                  {getQuickActionLabel(action)}
                </Button>
              ))}
            </Pills>
          </ActionSection>
        )}

        {Object.keys(persistentToggles).length > 0 && (
          <ActionSection title={t("stageActions.persistent")}>
            <Pills>
              {Object.entries(persistentToggles).map(([id, config]) => (
                <Button
                  key={id}
                  size="sm"
                  {...lunariaCompactPillButtonStyles}
                  bg={persistentToggleState[id] ? lunariaColors.primarySoft : lunariaSecondaryButtonStyles.bg}
                  color={persistentToggleState[id] ? lunariaColors.primaryStrong : lunariaColors.text}
                  onClick={() => togglePersistentToggle(id)}
                >
                  {persistentToggleState[id]
                    ? (config.onLabel || id)
                    : (config.offLabel || config.key || id)}
                </Button>
              ))}
            </Pills>
          </ActionSection>
        )}

        {motions.length > 0 && (
          <ActionSection title={t("stageActions.motions")}>
            <Pills>
              {motions.map((motion) => (
                <Button
                  key={`${motion.group}-${motion.index}-${motion.file}`}
                  size="sm"
                  {...lunariaCompactPillButtonStyles}
                  onClick={() => void executeQuickAction({
                    type: "motion",
                    group: motion.group,
                    index: motion.index,
                    label: motion.label || motion.name,
                  })}
                >
                  {motion.label || `${motion.group}:${motion.index}`}
                </Button>
              ))}
            </Pills>
          </ActionSection>
        )}

        {expressions.length > 0 && (
          <ActionSection title={t("stageActions.expressions")}>
            <Pills>
              {expressions.map((expression) => (
                <Button
                  key={`${expression.name}-${expression.index}`}
                  size="sm"
                  {...lunariaCompactPillButtonStyles}
                  onClick={() => void executeQuickAction({
                    type: "expression",
                    name: expression.name,
                    label: expression.name,
                  })}
                >
                  {expression.name}
                </Button>
              ))}
            </Pills>
          </ActionSection>
        )}
      </Stack>
    </Box>
  );
}
