import { ChakraProvider, defaultSystem } from "@chakra-ui/react";
import { CharacterConfigProvider } from "@/context/character-config-context";
import { Live2DConfigProvider } from "@/context/live2d-config-context";
import { ModeProvider } from "@/context/mode-context";
import { CameraProvider } from "@/context/camera-context";
import { ScreenCaptureProvider } from "@/context/screen-capture-context";
import { Toaster } from "@/shared/ui/toaster";
import { RendererCommandProvider } from "@/app/providers/command-provider";

export function AppProviders({ children }: { children: React.ReactNode }) {
  return (
    <ChakraProvider value={defaultSystem}>
      <ModeProvider>
        <CameraProvider>
          <ScreenCaptureProvider>
            <CharacterConfigProvider>
              <Live2DConfigProvider>
                <RendererCommandProvider>
                  <Toaster />
                  {children}
                </RendererCommandProvider>
              </Live2DConfigProvider>
            </CharacterConfigProvider>
          </ScreenCaptureProvider>
        </CameraProvider>
      </ModeProvider>
    </ChakraProvider>
  );
}
