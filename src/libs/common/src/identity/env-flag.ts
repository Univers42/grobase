/** True when the variable is `1` or `true` (any case, surrounding space ignored). */
export function envFlag(name: string): boolean {
  return /^(1|true)$/i.test(String(process.env[name] ?? '').trim());
}
