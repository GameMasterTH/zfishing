import { fetchNui } from './hooks/useNui'

// Flat dict served by the client's getLocale NUI callback (locales/*.json,
// en base + active language overlay). Outside FiveM the fetch fails and t()
// falls back to returning the key itself.
let dict: Record<string, string> = {}

export async function loadLocale(): Promise<void> {
  try {
    dict = (await fetchNui<Record<string, string>>('getLocale')) ?? {}
  } catch {
    dict = {}
  }
}

export function t(key: string, ...args: (string | number)[]): string {
  let s = dict[key] ?? key
  for (const a of args) s = s.replace(/%[sd]/, String(a))
  return s
}

// like t(), but unknown keys render the given fallback instead of the key
export function tOr(key: string, fallback: string): string {
  return dict[key] ?? fallback
}
