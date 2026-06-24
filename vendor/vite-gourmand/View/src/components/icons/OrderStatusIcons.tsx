/**
 * Order Status Icons
 * SVG icons representing order workflow states
 */

interface IconProps {
  className?: string;
  size?: number;
}

/** Pending - Clock icon */
export function PendingIcon({ className = '', size = 24 }: Readonly<IconProps>) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} className={className} fill="currentColor">
      <path d="M12 2C6.5 2 2 6.5 2 12s4.5 10 10 10 10-4.5 10-10S17.5 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm.5-13H11v6l5.2 3.2.8-1.3-4.5-2.7V7z" />
    </svg>
  );
}

/** Confirmed - Checkmark circle */
export function ConfirmedIcon({ className = '', size = 24 }: Readonly<IconProps>) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} className={className} fill="currentColor">
      <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z" />
    </svg>
  );
}

/** Preparing - Ingredients/Knife */
export function PreparingIcon({ className = '', size = 24 }: Readonly<IconProps>) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} className={className} fill="currentColor">
      <path d="M19.88 4.95l-.71.71-2.83-2.83.71-.71a.996.996 0 011.41 0l1.41 1.41c.4.39.4 1.03.01 1.42zM3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM14.88 5.36l3.75 3.75 1.06-1.06-3.75-3.75-1.06 1.06z" />
    </svg>
  );
}

/** Cooking - Fire/Flame */
export function CookingIcon({ className = '', size = 24 }: Readonly<IconProps>) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} className={className} fill="currentColor">
      <path d="M13.5.67s.74 2.65.74 4.8c0 2.06-1.35 3.73-3.41 3.73-2.07 0-3.63-1.67-3.63-3.73l.03-.36C5.21 7.51 4 10.62 4 14c0 4.42 3.58 8 8 8s8-3.58 8-8C20 8.61 17.41 3.8 13.5.67zM11.71 19c-1.78 0-3.22-1.4-3.22-3.14 0-1.62 1.05-2.76 2.81-3.12 1.77-.36 3.6-1.21 4.62-2.58.39 1.29.59 2.65.59 4.04 0 2.65-2.15 4.8-4.8 4.8z" />
    </svg>
  );
}

/** Assembling - Boxes/Stack */
export function AssemblingIcon({ className = '', size = 24 }: Readonly<IconProps>) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} className={className} fill="currentColor">
      <path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 16H5V5h14v14zM7 10h2v7H7zm4-3h2v10h-2zm4 6h2v4h-2z" />
    </svg>
  );
}

/** Ready - Bell/Notification */
export function ReadyIcon({ className = '', size = 24 }: Readonly<IconProps>) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} className={className} fill="currentColor">
      <path d="M12 22c1.1 0 2-.9 2-2h-4c0 1.1.89 2 2 2zm6-6v-5c0-3.07-1.64-5.64-4.5-6.32V4c0-.83-.67-1.5-1.5-1.5s-1.5.67-1.5 1.5v.68C7.63 5.36 6 7.92 6 11v5l-2 2v1h16v-1l-2-2z" />
    </svg>
  );
}

/** Delivery - Truck/Scooter */
export function DeliveryIcon({ className = '', size = 24 }: Readonly<IconProps>) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} className={className} fill="currentColor">
      <path d="M18.92 6.01C18.72 5.42 18.16 5 17.5 5H15V3H9v2H6.5c-.66 0-1.21.42-1.42 1.01L3 12v8c0 .55.45 1 1 1h1c.55 0 1-.45 1-1v-1h12v1c0 .55.45 1 1 1h1c.55 0 1-.45 1-1v-8l-2.08-5.99zM6.5 16c-.83 0-1.5-.67-1.5-1.5S5.67 13 6.5 13s1.5.67 1.5 1.5S7.33 16 6.5 16zm11 0c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zM5 11l1.5-4.5h11L19 11H5z" />
    </svg>
  );
}

/** Delivered - House with check */
export function DeliveredIcon({ className = '', size = 24 }: Readonly<IconProps>) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} className={className} fill="currentColor">
      <path d="M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8h5zm-1-7l2 2 4-4 1.5 1.5L11 18l-3.5-3.5L9 13z" />
    </svg>
  );
}

/** Cancelled - X circle */
export function CancelledIcon({ className = '', size = 24 }: Readonly<IconProps>) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} className={className} fill="currentColor">
      <path d="M12 2C6.47 2 2 6.47 2 12s4.47 10 10 10 10-4.47 10-10S17.53 2 12 2zm5 13.59L15.59 17 12 13.41 8.41 17 7 15.59 10.59 12 7 8.41 8.41 7 12 10.59 15.59 7 17 8.41 13.41 12 17 15.59z" />
    </svg>
  );
}

/** Get icon component by status */
// eslint-disable-next-line react-refresh/only-export-components
export function getStatusIcon(status: string): React.FC<IconProps> {
  const icons: Record<string, React.FC<IconProps>> = {
    pending: PendingIcon,
    confirmed: ConfirmedIcon,
    preparing: PreparingIcon,
    cooking: CookingIcon,
    assembling: AssemblingIcon,
    ready: ReadyIcon,
    delivery: DeliveryIcon,
    delivered: DeliveredIcon,
    cancelled: CancelledIcon,
  };
  return icons[status] || PendingIcon;
}
