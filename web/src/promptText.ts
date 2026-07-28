import { tOr } from './i18n'

export const MAX_LINE = 120

// fallback ต่อ key (R4.4): เมื่อ dict ไม่มี key ทั้ง active และ en
const FALLBACK: Record<string, string> = {
  equip_title: 'Fishing',
  equip_hint: '[E] Start fishing   ·   [X] Pack up rod   ·   [G] Manage Rod',
  cancel_title: 'Reeling',
  cancel_hint: '[X] Pack up rod',
}

// R2.7, R4.4: คืนค่าจาก dict ถ้ามีและไม่ว่าง มิฉะนั้นคืน fallback; ไม่คืน raw key
export function resolvePromptText(key: string): string {
  const fallback = FALLBACK[key] ?? ''
  const v = tOr(key, fallback)
  return v.trim().length > 0 ? v : fallback
}

// R1.7 + R1.8: ตัดบรรทัดว่าง/ช่องว่างล้วน/null ออก และ truncate <= MAX_LINE
export function prepareLines(
  title?: string | null,
  subtitle?: string | null,
): [string | null, string | null] {
  return [prepareLine(title), prepareLine(subtitle)]
}

function prepareLine(text?: string | null): string | null {
  if (text == null) return null
  const trimmed = text.trim()
  if (trimmed.length === 0) return null
  return trimmed.length > MAX_LINE ? trimmed.slice(0, MAX_LINE) : trimmed
}
