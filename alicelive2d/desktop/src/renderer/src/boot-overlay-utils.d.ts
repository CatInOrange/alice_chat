export function ensureBootOverlay(
  document: Document | {
    body?: { appendChild?: (node: unknown) => unknown } | null;
    createElement?: (tagName: string) => {
      id?: string;
      innerHTML?: string;
      style?: Record<string, string>;
    };
    getElementById?: (id: string) => { remove?: () => void } | null;
  } | null | undefined,
  payload: {
    status: 'loading' | 'error';
    message: string;
  },
): unknown;

export function hideBootOverlay(
  document: Document | {
    getElementById?: (id: string) => { remove?: () => void } | null;
  } | null | undefined,
): void;
