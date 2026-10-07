import { useRef } from 'react';

type Listener = (event: Event) => void;

export function markSelectClick(event: Event): void {
  const item = (event.target as HTMLElement | undefined)?.closest?.('mdui-menu-item') as (HTMLElement & { selected?: boolean }) | undefined;
  const select = item?.closest?.('mdui-select') as HTMLElement | undefined;
  if (!item || !select || !item.selected) return;
  event.preventDefault();
  event.stopImmediatePropagation();
  const dropdown = select.shadowRoot?.querySelector('mdui-dropdown') as (HTMLElement & { open?: boolean }) | undefined;
  if (dropdown?.open) dropdown.open = false;
}

export function restoreSelect(event: Event, fallback?: string): boolean {
  const select = event.currentTarget as HTMLElement | undefined;
  if (!select || fallback === undefined) return false;
  const menu = select.shadowRoot?.querySelector('mdui-menu') as (HTMLElement & { value?: string }) | undefined;
  if (menu && menu.value === undefined) menu.value = fallback;
  (select as HTMLElement & { value?: string }).value = fallback;
  return true;
}

export function useElementEvent<T extends HTMLElement>(name: string, listener: Listener): (element: T | null) => void {
  const saved = useRef(listener);
  saved.current = listener;
  const bound = useRef<WeakSet<HTMLElement>>(new WeakSet());
  return (element) => {
    
    if (!element || bound.current.has(element)) return;
    bound.current.add(element);
    element.addEventListener(name, (event) => saved.current(event));
  };
}

export function targetValue(event: Event): string {
  const current = event.currentTarget as HTMLInputElement | undefined;
  const target = event.target as HTMLInputElement | undefined;
  return String(current?.value ?? target?.value ?? '');
}

export function targetChecked(event: Event): boolean {
  const current = event.currentTarget as HTMLInputElement | undefined;
  const target = event.target as HTMLInputElement | undefined;
  return Boolean(current?.checked ?? target?.checked);
}

export function targetNumber(event: Event): number {
  return Number(targetValue(event)) || 0;
}
