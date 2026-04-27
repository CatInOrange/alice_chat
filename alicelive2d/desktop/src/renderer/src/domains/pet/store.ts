import { create } from "zustand";
import { createJSONStorage, persist } from "zustand/middleware";
import { PetPlusView, PetSurface } from "@/domains/types";

interface PetState {
  petSurface: PetSurface;
  petPlusView: PetPlusView;
  petExpanded: boolean;
  petAutoHideSeconds: number;
  petAnchor: { x: number; y: number };
  petAnchorLocked: boolean;
  setPetSurface: (value: PetSurface) => void;
  setPetPlusView: (value: PetPlusView) => void;
  setPetExpanded: (value: boolean) => void;
  setPetAutoHideSeconds: (value: number) => void;
  setPetAnchor: (value: { x: number; y: number }) => void;
  setPetAnchorLocked: (value: boolean) => void;
  resetPetPanels: () => void;
}

export const usePetStore = create<PetState>()(
  persist(
    (set) => ({
      petSurface: "chat",
      petPlusView: "root",
      petExpanded: false,
      petAutoHideSeconds: 10,
      petAnchor: { x: 0, y: 0 },
      petAnchorLocked: false,
      setPetSurface: (value) => set({ petSurface: value }),
      setPetPlusView: (value) => set({ petPlusView: value }),
      setPetExpanded: (value) => set({ petExpanded: value }),
      setPetAutoHideSeconds: (value) => set({
        petAutoHideSeconds: Math.max(0, Math.min(120, Math.round(value || 0))),
      }),
      setPetAnchor: (value) => set({ petAnchor: value }),
      setPetAnchorLocked: (value) => set({ petAnchorLocked: value }),
      resetPetPanels: () => set({ petSurface: "chat", petPlusView: "root" }),
    }),
    {
      name: "lunaria-pet-store-v1",
      storage: createJSONStorage(() => localStorage),
      partialize: (state) => ({
        petExpanded: state.petExpanded,
        petAutoHideSeconds: state.petAutoHideSeconds,
      }),
    },
  ),
);
