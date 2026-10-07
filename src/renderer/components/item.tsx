import type { ReactNode } from 'react';

function statusItem(props: { label: string; value: ReactNode }): ReactNode {
  return (
    <div className="status-row">
      <span className="status-label">{props.label}</span>
      <span className="status-value">{props.value}</span>
    </div>
  );
}

export { statusItem as StatusItem };
