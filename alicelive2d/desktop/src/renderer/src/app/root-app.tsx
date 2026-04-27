import { AppProviders } from "@/app/providers/app-providers";
import RootShell from "@/app/shell/root-shell";

export default function RootApp(): JSX.Element {
  return (
    <AppProviders>
      <RootShell />
    </AppProviders>
  );
}
