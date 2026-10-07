import type { CSSProperties, DOMAttributes, Key, ReactNode, Ref } from 'react';

interface MduiBase extends DOMAttributes<HTMLElement> {
  className?: string;
  style?: CSSProperties;
  ref?: Ref<HTMLElement>;
  slot?: string;
  id?: string;
  name?: string;
  key?: Key;
  children?: ReactNode;
}

declare module 'react' {
  namespace JSX {
    interface IntrinsicElements {
      'mdui-layout': MduiBase;
      'mdui-layout-main': MduiBase;
      'mdui-top-app-bar': MduiBase & { variant?: string };
      'mdui-navigation-drawer': MduiBase & { placement?: 'left' | 'right'; open?: boolean; borderless?: boolean; contained?: boolean };
      'mdui-list': MduiBase;
      'mdui-list-item': MduiBase & {
        icon?: string;
        'end-icon'?: string;
        active?: boolean;
        rounded?: boolean;
        disabled?: boolean;
        nonclickable?: boolean;
      };
      'mdui-button': MduiBase & { variant?: 'elevated' | 'filled' | 'tonal' | 'outlined' | 'text'; icon?: string; disabled?: boolean; 'full-width'?: boolean; loading?: boolean };
      'mdui-button-icon': MduiBase & { icon?: string; disabled?: boolean; selected?: boolean };
      'mdui-icon': MduiBase & { name?: string; src?: string; dangerouslySetInnerHTML?: { __html: string } };
      'mdui-checkbox': MduiBase & { checked?: boolean; disabled?: boolean };
      'mdui-switch': MduiBase & { checked?: boolean; disabled?: boolean };
      'mdui-select': MduiBase & { value?: string; variant?: string; label?: string; disabled?: boolean };
      'mdui-menu-item': MduiBase & { value?: string; disabled?: boolean };
      'mdui-text-field': MduiBase & { value?: string; label?: string; variant?: string; rows?: number; readonly?: boolean; disabled?: boolean; placeholder?: string; type?: string; min?: number; max?: number; step?: number };
      'mdui-slider': MduiBase & { min?: number; max?: number; step?: number; value?: number; label?: string; disabled?: boolean; tickmarks?: boolean; nolabel?: boolean };
      'mdui-dialog': MduiBase & { open?: boolean; headline?: string; description?: string; 'close-on-overlay-click'?: boolean };
      'mdui-linear-progress': MduiBase & { max?: number; value?: number; indeterminate?: boolean };
      'mdui-divider': MduiBase & { vertical?: boolean; middle?: boolean; inset?: boolean };
      'mdui-circular-progress': MduiBase & { value?: number; max?: number; indeterminate?: boolean };
      'mdui-chip': MduiBase & { variant?: 'assist' | 'filter' | 'input' | 'suggestion'; selected?: boolean; elevated?: boolean; icon?: string; clickable?: boolean };
      'mdui-fab': MduiBase & { variant?: 'primary' | 'surface' | 'secondary' | 'tertiary'; size?: 'normal' | 'small' | 'large'; icon?: string; extended?: boolean; lowered?: boolean; disabled?: boolean };
    }
  }
}
