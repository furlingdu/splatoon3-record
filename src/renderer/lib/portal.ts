import { createPortal } from 'react-dom';
import type { ReactElement, ReactNode } from 'react';

export function dialogLayer(node: ReactNode): ReactElement {
  return createPortal(node, document.body);
}
