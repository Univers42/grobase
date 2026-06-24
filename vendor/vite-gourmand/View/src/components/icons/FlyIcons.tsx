/**
 * FlyIcons - Fly.io-inspired SVG icons for DevBoard
 * Clean, modern icons with consistent styling
 */

interface IconProps {
  className?: string;
  size?: number;
}

/** Settings gear icon */
export function SettingsIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M7.226.738c.266-.985 1.64-.985 1.905 0l.265.983c.065.244.21.458.413.61a1.25 1.25 0 0 0 .693.26l1.007.068c1.01.069 1.432 1.337.584 1.762l-.847.424c-.22.11-.397.287-.505.506-.107.22-.14.467-.094.707l.182.999c.182 1-.958 1.722-1.783 1.127l-.823-.594a1.26 1.26 0 0 0-.73-.23 1.26 1.26 0 0 0-.728.23l-.822.594c-.826.595-1.965-.126-1.783-1.127l.18-.999a1.262 1.262 0 0 0-.095-.707 1.256 1.256 0 0 0-.504-.506l-.847-.424c-.847-.425-.426-1.693.584-1.762l1.007-.067c.251-.018.493-.105.693-.261.2-.152.346-.366.413-.61l.258-.983Zm.953 2.606a2.762 2.762 0 0 1-.908 1.342c-.44.338-1 .535-1.522.571l.555.277c.485.243.884.627 1.14 1.098a2.758 2.758 0 0 1 .205 1.549l.544-.393c.401-.29.895-.444 1.404-.435.509.008.997.175 1.39.476l.543.392a2.76 2.76 0 0 1 .206-1.549 2.758 2.758 0 0 1 1.14-1.097l.555-.277c-.523-.037-1.025-.233-1.466-.572a2.76 2.76 0 0 1-.907-1.341 2.76 2.76 0 0 1-.91 1.341 2.761 2.761 0 0 1-1.522.571 2.768 2.768 0 0 1-1.447-.572 2.757 2.757 0 0 1-.909-1.341c-.001-.007-.043.09-.09.226l-.001-.025v-.24Zm.821 3.156a.5.5 0 1 0 0 1 .5.5 0 0 0 0-1Z"
      />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M2.28 7.002a.5.5 0 0 0-.5.5v5.04l1.188-.48a.5.5 0 0 1 .44.022L5.333 13.2l2.205-1.07a.5.5 0 0 1 .44 0l2.232 1.073 1.925-1.119a.5.5 0 0 1 .44-.024l1.204.487v-5.06a.5.5 0 0 0-.5-.5l-1.186.008a1 1 0 0 1-.994-.878l-.095-.59-1.002-.066a2.25 2.25 0 0 1-1.917-1.56l-.027-.095-.101-.35-.095.352-.007.026a2.25 2.25 0 0 1-1.873 1.549l-1.01.066-.094.59a1 1 0 0 1-.99.88H2.28Zm12.5-.985v6.519a.5.5 0 0 1-.7.457l-1.675-.677-1.939 1.126a.5.5 0 0 1-.467.01L7.771 12.38l-2.204 1.07a.5.5 0 0 1-.45-.006l-1.977-1.14L1.7 12.96a.5.5 0 0 1-.7-.46V6.53l.048-.002.033-.001h1.003l.127-.787A2 2 0 0 1 4 4.103l.33-.023a1.25 1.25 0 0 0 1.035-.854l.265-.984A1.578 1.578 0 0 1 6.89 1.11l.037.017.108.06a1.761 1.761 0 0 1 .09 3.054l-.015.008-.053.03.013.004a1.763 1.763 0 0 1 1.203 1.21l-.003.011.14-.502a2.25 2.25 0 0 1 1.917-1.56l.33-.023a1.251 1.251 0 0 0 1.036-.853l.265-.984a1.578 1.578 0 0 1 3.02.052l.025.093.055.2.056.207.022.083.086.32a2.25 2.25 0 0 1 1.874 1.549l.124.787h.04a1.5 1.5 0 0 1 1.445 1.1Z"
      />
    </svg>
  );
}

/** Metrics/Monitoring icon - circles pattern */
export function MetricsIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <circle cx="3.5" cy="3.5" r="2" />
      <circle cx="12.5" cy="3.5" r="2" />
      <circle cx="3.5" cy="12.5" r="2" />
      <circle cx="12.5" cy="12.5" r="2" />
      <circle cx="8" cy="8" r="2.5" />
    </svg>
  );
}

/** Logs/Archive icon */
export function LogsIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M2 3a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1.5a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V3Zm1.5.25a.25.25 0 0 0-.25.25v.5c0 .138.112.25.25.25h9a.25.25 0 0 0 .25-.25v-.5a.25.25 0 0 0-.25-.25h-9Z"
      />
      <path d="M3.5 6.5h9v1h-9v-1Zm0 2h9v1h-9v-1Zm0 2h7v1h-7v-1Z" />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M1 2.5A1.5 1.5 0 0 1 2.5 1h11A1.5 1.5 0 0 1 15 2.5v11a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 1 13.5v-11ZM2.5 2a.5.5 0 0 0-.5.5v11a.5.5 0 0 0 .5.5h11a.5.5 0 0 0 .5-.5v-11a.5.5 0 0 0-.5-.5h-11Z"
      />
    </svg>
  );
}

/** Dashboard/Overview icon - grid pattern */
export function OverviewIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M2 2h5v5H2V2Zm1 1v3h3V3H3Z" />
      <path d="M9 2h5v5H9V2Zm1 1v3h3V3h-3Z" />
      <path d="M2 9h5v5H2V9Zm1 1v3h3v-3H3Z" />
      <path d="M9 9h5v5H9V9Zm1 1v3h3v-3h-3Z" />
    </svg>
  );
}

/** Activity/Toggle icon */
export function ActivityIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M1 3a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V3Zm2-1a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1V3a1 1 0 0 0-1-1H3Z"
      />
      <path d="M4 6.5a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v4a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1v-4Z" />
      <path d="M8 8.5a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v2a1 1 0 0 1-1 1H9a1 1 0 0 1-1-1v-2Z" />
    </svg>
  );
}

/** Tests/Automation icon - checkmark in box */
export function TestsIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M1.5 2A1.5 1.5 0 0 1 3 .5h10A1.5 1.5 0 0 1 14.5 2v12a1.5 1.5 0 0 1-1.5 1.5H3A1.5 1.5 0 0 1 1.5 14V2ZM3 1.5a.5.5 0 0 0-.5.5v12a.5.5 0 0 0 .5.5h10a.5.5 0 0 0 .5-.5V2a.5.5 0 0 0-.5-.5H3Z"
      />
      <path d="M10.854 5.354a.5.5 0 0 0-.708-.708L7 7.793 5.854 6.646a.5.5 0 1 0-.708.708l1.5 1.5a.5.5 0 0 0 .708 0l3.5-3.5Z" />
      <path d="M4.5 10.5h7v1h-7v-1Zm0 2h5v1h-5v-1Z" />
    </svg>
  );
}

/** Scenarios/Play icon - theater masks or clapperboard */
export function ScenariosIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M2 1.5A1.5 1.5 0 0 1 3.5 0h9A1.5 1.5 0 0 1 14 1.5v13a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 14.5v-13ZM3.5 1a.5.5 0 0 0-.5.5v1h2V1H3.5ZM6 1v1.5h2V1H6Zm3 0v1.5h2V1H9Zm3 0v1.5h.5a.5.5 0 0 0 .5-.5v-1H12Zm1 2.5H3v11a.5.5 0 0 0 .5.5h9a.5.5 0 0 0 .5-.5v-11Z"
      />
      <path d="M5.5 6a1 1 0 1 1 2 0 1 1 0 0 1-2 0Zm3 0a1 1 0 1 1 2 0 1 1 0 0 1-2 0ZM6.5 9a.5.5 0 0 0 0 1h3a.5.5 0 0 0 0-1h-3Z" />
    </svg>
  );
}

/** Machine/Compute icon */
export function MachineIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M1 3.5A1.5 1.5 0 0 1 2.5 2h11A1.5 1.5 0 0 1 15 3.5v9a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 1 12.5v-9ZM2.5 3a.5.5 0 0 0-.5.5v9a.5.5 0 0 0 .5.5h11a.5.5 0 0 0 .5-.5v-9a.5.5 0 0 0-.5-.5h-11Z"
      />
      <circle cx="4.5" cy="6" r="1" />
      <circle cx="4.5" cy="10" r="1" />
      <path d="M7 5.5h5v1H7v-1Zm0 4h5v1H7v-1Z" />
    </svg>
  );
}

/** ChevronDown icon for dropdowns */
export function ChevronDownIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M4.22 6.22a.75.75 0 0 1 1.06 0L8 8.94l2.72-2.72a.75.75 0 1 1 1.06 1.06l-3.25 3.25a.75.75 0 0 1-1.06 0L4.22 7.28a.75.75 0 0 1 0-1.06Z"
      />
    </svg>
  );
}

/** Collapse/Sidebar toggle icon */
export function CollapseIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M1 3.5A1.5 1.5 0 0 1 2.5 2h11A1.5 1.5 0 0 1 15 3.5v9a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 1 12.5v-9ZM2.5 3a.5.5 0 0 0-.5.5v9a.5.5 0 0 0 .5.5H5V3H2.5ZM6 3v10h7.5a.5.5 0 0 0 .5-.5v-9a.5.5 0 0 0-.5-.5H6Z"
      />
    </svg>
  );
}

/** Check/Success icon */
export function CheckIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.75.75 0 0 1 1.06-1.06L6 10.94l6.72-6.72a.75.75 0 0 1 1.06 0Z"
      />
    </svg>
  );
}

/** X/Error/Close icon */
export function XIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M3.72 3.72a.75.75 0 0 1 1.06 0L8 6.94l3.22-3.22a.75.75 0 1 1 1.06 1.06L9.06 8l3.22 3.22a.75.75 0 1 1-1.06 1.06L8 9.06l-3.22 3.22a.75.75 0 0 1-1.06-1.06L6.94 8 3.72 4.78a.75.75 0 0 1 0-1.06Z"
      />
    </svg>
  );
}

/** Warning/Alert icon */
export function WarningIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l5.847 10.933A1.75 1.75 0 0 1 13.847 14H2.153a1.75 1.75 0 0 1-1.543-2.02L6.457 1.047ZM8 5a.75.75 0 0 1 .75.75v2.5a.75.75 0 0 1-1.5 0v-2.5A.75.75 0 0 1 8 5Zm0 6.25a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z"
      />
    </svg>
  );
}

/** Lightning/Bolt icon for auto/fast */
export function BoltIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M9.405 1.05c-.413-1.4-2.397-1.4-2.81 0l-.1.34a1.464 1.464 0 0 1-2.105.872l-.31-.17c-1.283-.698-2.686.705-1.987 1.987l.169.311c.446.82.023 1.841-.872 2.105l-.34.1c-1.4.413-1.4 2.397 0 2.81l.34.1a1.464 1.464 0 0 1 .872 2.105l-.17.31c-.698 1.283.705 2.686 1.987 1.987l.311-.169a1.464 1.464 0 0 1 2.105.872l.1.34c.413 1.4 2.397 1.4 2.81 0l.1-.34a1.464 1.464 0 0 1 2.105-.872l.31.17c1.283.698 2.686-.705 1.987-1.987l-.169-.311a1.464 1.464 0 0 1 .872-2.105l.34-.1c1.4-.413 1.4-2.397 0-2.81l-.34-.1a1.464 1.464 0 0 1-.872-2.105l.17-.31c.698-1.283-.705-2.686-1.987-1.987l-.311.169a1.464 1.464 0 0 1-2.105-.872l-.1-.34zM8 10.93a2.929 2.929 0 1 1 0-5.858 2.929 2.929 0 0 1 0 5.858z" />
    </svg>
  );
}

/** Performance/Lightning bolt */
export function PerformanceIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M5.52.359A.5.5 0 0 1 6 0h4a.5.5 0 0 1 .474.658L8.694 6H12.5a.5.5 0 0 1 .395.807l-7 9a.5.5 0 0 1-.873-.454L6.823 9.5H3.5a.5.5 0 0 1-.48-.641l2.5-8.5Z" />
    </svg>
  );
}

/** Clock/Time icon */
export function ClockIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M8 15A7 7 0 1 0 8 1a7 7 0 0 0 0 14Zm0-1.5a5.5 5.5 0 1 0 0-11 5.5 5.5 0 0 0 0 11Z"
      />
      <path d="M8 4a.75.75 0 0 1 .75.75v2.69l1.78 1.78a.75.75 0 1 1-1.06 1.06l-2-2A.75.75 0 0 1 7.25 8V4.75A.75.75 0 0 1 8 4Z" />
    </svg>
  );
}

/** Chart/Analytics icon */
export function ChartIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M1 2.75A.75.75 0 0 1 1.75 2h12.5a.75.75 0 0 1 0 1.5H1.75A.75.75 0 0 1 1 2.75ZM4 7a1 1 0 0 1 1 1v5a1 1 0 0 1-2 0V8a1 1 0 0 1 1-1Zm4-2a1 1 0 0 1 1 1v7a1 1 0 1 1-2 0V6a1 1 0 0 1 1-1Zm4 4a1 1 0 0 1 1 1v3a1 1 0 1 1-2 0v-3a1 1 0 0 1 1-1Z"
      />
    </svg>
  );
}

/** Target/Bullseye icon */
export function TargetIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M8 14A6 6 0 1 0 8 2a6 6 0 0 0 0 12Zm0-1.5a4.5 4.5 0 1 0 0-9 4.5 4.5 0 0 0 0 9Z"
      />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M8 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm0-1.5a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3Z"
      />
    </svg>
  );
}

/** Play icon for running tests */
export function PlayIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M4 2.75c0-.973 1.077-1.551 1.91-.986l7.2 4.8a1.25 1.25 0 0 1 0 2.072l-7.2 4.8c-.833.565-1.91-.013-1.91-.986V2.75Z" />
    </svg>
  );
}

/** User/Person icon */
export function UserIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M10.5 5a2.5 2.5 0 1 1-5 0 2.5 2.5 0 0 1 5 0Zm.514 2.63a4 4 0 1 0-6.028 0A4.002 4.002 0 0 0 2 11.5V13a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2v-1.5a4.002 4.002 0 0 0-2.986-3.87ZM4 11.5a2.5 2.5 0 0 1 2.5-2.5h3A2.5 2.5 0 0 1 12 11.5V13a.5.5 0 0 1-.5.5h-7A.5.5 0 0 1 4 13v-1.5Z"
      />
    </svg>
  );
}

/** Eye/View icon */
export function EyeIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M8 2C4.318 2 1.222 4.493.254 7.862a.5.5 0 0 0 0 .276C1.222 11.507 4.318 14 8 14s6.778-2.493 7.746-5.862a.5.5 0 0 0 0-.276C14.778 4.493 11.682 2 8 2Zm0 10.5c-2.735 0-5.15-1.82-6.207-4.5C2.85 5.32 5.265 3.5 8 3.5c2.735 0 5.15 1.82 6.207 4.5-1.057 2.68-3.472 4.5-6.207 4.5Z"
      />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M8 5.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5ZM6.5 8a1.5 1.5 0 1 1 3 0 1.5 1.5 0 0 1-3 0Z"
      />
    </svg>
  );
}

/** Flask/Test tube icon */
export function FlaskIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M5 1a1 1 0 0 0 0 2v4.586L1.707 10.88A2 2 0 0 0 3.12 14.5h9.758a2 2 0 0 0 1.414-3.414L11 7.586V3a1 1 0 1 0 0-2H5Zm1.5 2v5a.5.5 0 0 1-.146.354L3.914 10.79a.5.5 0 0 0 .354.854h7.464a.5.5 0 0 0 .354-.854l-2.44-2.436A.5.5 0 0 1 9.5 8V3h-3Z"
      />
    </svg>
  );
}

/** Info circle icon */
export function InfoIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M8 15A7 7 0 1 0 8 1a7 7 0 0 0 0 14Zm0-1.5a5.5 5.5 0 1 0 0-11 5.5 5.5 0 0 0 0 11ZM8 4.5a.75.75 0 0 1 .75.75v4.5a.75.75 0 0 1-1.5 0v-4.5A.75.75 0 0 1 8 4.5Zm0 7a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z"
      />
    </svg>
  );
}

/** Refresh/Sync icon */
export function RefreshIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M8 2.5a5.5 5.5 0 0 1 4.95 3.08.75.75 0 0 0 1.35-.66A7 7 0 0 0 1.05 6.5H.75a.75.75 0 0 0 0 1.5h2.5a.75.75 0 0 0 .75-.75V4.75a.75.75 0 0 0-1.5 0v.56A5.48 5.48 0 0 1 8 2.5Zm5.5 5.75a.75.75 0 0 0-.75-.75h-2.5a.75.75 0 0 0-.75.75v2.5a.75.75 0 0 0 1.5 0v-.56A5.48 5.48 0 0 1 8 13.5a5.5 5.5 0 0 1-4.95-3.08.75.75 0 0 0-1.35.66A7 7 0 0 0 14.95 9.5h.3a.75.75 0 0 0 0-1.5h-1.75v.25Z"
      />
    </svg>
  );
}

/** Circle icon (for status dots) */
export function CircleIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <circle cx="8" cy="8" r="4" />
    </svg>
  );
}

/** Database icon - cylinder */
export function DatabaseIcon({ className = '', size = 16 }: Readonly<IconProps>) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <ellipse cx="8" cy="3.5" rx="5.5" ry="2" />
      <path d="M2.5 3.5v9c0 1.1 2.46 2 5.5 2s5.5-.9 5.5-2v-9c0 1.1-2.46 2-5.5 2S2.5 4.6 2.5 3.5Z" />
      <path
        d="M2.5 8c0 1.1 2.46 2 5.5 2s5.5-.9 5.5-2"
        fill="none"
        stroke="currentColor"
        strokeWidth="1"
      />
    </svg>
  );
}

export default {
  SettingsIcon,
  MetricsIcon,
  LogsIcon,
  OverviewIcon,
  ActivityIcon,
  TestsIcon,
  ScenariosIcon,
  DatabaseIcon,
  MachineIcon,
  ChevronDownIcon,
  CollapseIcon,
  CheckIcon,
  XIcon,
  WarningIcon,
  BoltIcon,
  PerformanceIcon,
  ClockIcon,
  ChartIcon,
  TargetIcon,
  PlayIcon,
  UserIcon,
  EyeIcon,
  FlaskIcon,
  InfoIcon,
  RefreshIcon,
  CircleIcon,
};
