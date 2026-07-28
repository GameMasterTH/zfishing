import { tOr } from './i18n'

// fallback ต่อ key (R6.4): เมื่อ dict ไม่มี key ทั้ง active และ en หรือค่าว่าง
const FALLBACK: Record<string, string> = {
  rig_title: 'Manage Rod',
  rig_close_hint: 'Press ESC to close',
  rig_empty: 'No rod parts to manage',
  rig_locale_error: 'Language failed to load',
  rig_cat_reel: 'Reel',
  rig_cat_line: 'Line',
  rig_cat_hook: 'Hook',
  rig_cat_float: 'Float',
  rig_attach: 'Attach',
  rig_detach: 'Detach',
}

// fallback สุดท้ายเมื่อ key ไม่อยู่ใน FALLBACK เพื่อกันไม่ให้คืน raw key หรือสตริงว่าง
const GENERIC_FALLBACK = 'Manage Rod'

// R6.3, R6.4: คืนค่าจาก dict ถ้ามีและไม่ว่างหลัง trim มิฉะนั้นคืน fallback;
// ไม่คืน raw key และไม่คืนสตริงว่างในทุกกรณี
export function rigText(key: string): string {
  const fallback = FALLBACK[key] ?? GENERIC_FALLBACK
  const v = tOr(key, fallback)
  return v.trim().length > 0 ? v : fallback
}
