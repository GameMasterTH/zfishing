// Pure logic ของ Rig_Menu: ประกอบแถว, จัดรูปแบบจำนวน, ตัดสิน action, map notify key
// ไม่พึ่งพา React/DOM เพื่อให้ทดสอบด้วย unit + property test ได้

export type PartType = 'reel' | 'line' | 'hook' | 'float'

export interface CatalogEntry {
  partType: PartType
  name: string
  label: string
}

export interface CarriedItemInstance {
  slot: number
  name: string
  label: string
  dur: number
  max: number
}

export interface RigView {
  rod: string
  rodLabel: string
  parts: Partial<Record<PartType, { name: string; label: string; dur: number; max: number }>>
  carried: Record<PartType, CarriedItemInstance[]>
}

export interface ItemGroup {
  name: string
  label: string
  partType: PartType
  fitted: boolean
  fittedInstance?: { dur: number; max: number }
  instances: CarriedItemInstance[]
  totalOwned: number
}

export interface CategoryGroup {
  partType: PartType
  titleKey: string
  fittedName?: string
  fittedLabel?: string
  fittedDur?: number
  fittedMax?: number
  items: ItemGroup[]
}

export interface RigRow {
  partType: PartType
  name: string
  label: string
  owned: number
  fitted: boolean
}

export type RigAction =
  | { kind: 'attach'; partType: PartType; itemName: string }
  | { kind: 'detach'; partType: PartType }
  | { kind: 'blocked' }

export const PART_ORDER: PartType[] = ['reel', 'line', 'hook', 'float']

export const CATEGORY_TITLES: Record<PartType, string> = {
  reel: 'rig_cat_reel',
  line: 'rig_cat_line',
  hook: 'rig_cat_hook',
  float: 'rig_cat_float',
}

export function groupRigCategories(view: RigView, catalog: CatalogEntry[]): CategoryGroup[] {
  return PART_ORDER.map((partType) => {
    const fittedPart = view.parts?.[partType]
    const carriedInstances = view.carried?.[partType] ?? []

    const catCatalog = catalog.filter((c) => c.partType === partType)

    const items: ItemGroup[] = catCatalog.map((entry) => {
      const instances = carriedInstances.filter((inst) => inst.name === entry.name)
      const fitted = fittedPart?.name === entry.name
      return {
        name: entry.name,
        label: entry.label,
        partType,
        fitted,
        fittedInstance: fitted && fittedPart ? { dur: fittedPart.dur, max: fittedPart.max } : undefined,
        instances,
        totalOwned: instances.length + (fitted ? 1 : 0),
      }
    })

    return {
      partType,
      titleKey: CATEGORY_TITLES[partType],
      fittedName: fittedPart?.name,
      fittedLabel: fittedPart?.label,
      fittedDur: fittedPart?.dur,
      fittedMax: fittedPart?.max,
      items: items.sort((a, b) => a.name.localeCompare(b.name)),
    }
  })
}


// R2.2: หนึ่งแถวต่อหนึ่ง item ใน catalog; เรียงตาม PART_ORDER แล้วภายใน partType เรียงชื่อ ascending
// owned = จำนวน entry ใน carried[partType] ที่ชื่อตรงกัน; fitted = parts[partType]?.name === row.name
export function buildRigRows(view: RigView, catalog: CatalogEntry[]): RigRow[] {
  const rows: RigRow[] = catalog.map((entry) => {
    const carried = view.carried?.[entry.partType] ?? []
    const owned = carried.reduce((n, item) => (item.name === entry.name ? n + 1 : n), 0)
    const fitted = view.parts?.[entry.partType]?.name === entry.name
    return {
      partType: entry.partType,
      name: entry.name,
      label: entry.label,
      owned,
      fitted,
    }
  })

  return rows.sort((a, b) => {
    const order = PART_ORDER.indexOf(a.partType) - PART_ORDER.indexOf(b.partType)
    if (order !== 0) return order
    return a.name.localeCompare(b.name)
  })
}

// R2.3: clamp เป็นจำนวนเต็มช่วง 0..9999 (ลบ→0, >9999→9999, ทศนิยม truncate ด้วย Math.floor หลัง clamp)
export function formatOwned(n: number): string {
  const safe = Number.isNaN(n) ? 0 : n
  const clamped = Math.min(9999, Math.max(0, safe))
  return `${Math.floor(clamped)}x`
}

// R2.5, R2.6: แถวจางเมื่อไม่มีของ
export function isDimmed(owned: number): boolean {
  return owned === 0
}

// R4.1, R4.2, R4.3: detach เมื่อ fitted; attach เมื่อไม่ fitted และ owned > 0; blocked เมื่อไม่ fitted และ owned === 0
export function resolveRigAction(row: RigRow): RigAction {
  if (row.fitted) {
    return { kind: 'detach', partType: row.partType }
  }
  if (row.owned > 0) {
    return { kind: 'attach', partType: row.partType, itemName: row.name }
  }
  return { kind: 'blocked' }
}

// R4.5–R4.8: map ผลลัพธ์ callback เป็น locale key
// ok=true → attached/detached ตาม kind; err='inv_full' → rig_inv_full; อื่น ๆ และ timeout → rig_error
export function resolveNotifyKey(
  kind: 'attach' | 'detach',
  result: { ok: boolean; err?: string } | 'timeout',
): string {
  if (result === 'timeout') return 'rig_error'
  if (result.ok) return kind === 'attach' ? 'attached' : 'detached'
  if (result.err === 'inv_full') return 'rig_inv_full'
  return 'rig_error'
}
