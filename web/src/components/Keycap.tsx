import type { ReactNode } from 'react'

type Variant = 'breathe' | 'urgent'

// ปุ่มคีย์บอร์ดหนึ่งอัน — ใช้ร่วมกันทั้ง PromptHud, bite prompt และหัวข้อ reel
// เพื่อให้ทุกจุดที่บอก "กดปุ่มนี้" หน้าตาและจังหวะเดียวกัน
export default function Keycap({ label, variant }: { label: string; variant?: Variant }) {
  return <kbd className={variant ? `keycap keycap--${variant}` : 'keycap'}>{label}</kbd>
}

// locale เขียนปุ่มไว้ในวงเล็บเหลี่ยม เช่น "[E] เริ่มตกปลา   ·   [G] จัดการเบ็ด"
// ตัวนี้แยกสตริงเป็น text + <Keycap> โดยตัดวงเล็บออก ข้อความอื่นคงเดิมทุกตัวอักษร
export function renderWithKeycaps(text: string, variant?: Variant): ReactNode[] {
  const pattern = /\[([A-Za-z0-9]+)\]/g
  const out: ReactNode[] = []
  let last = 0
  let match: RegExpExecArray | null

  while ((match = pattern.exec(text)) !== null) {
    if (match.index > last) out.push(text.slice(last, match.index))
    out.push(<Keycap key={`${match.index}-${match[1]}`} label={match[1]} variant={variant} />)
    last = match.index + match[0].length
  }
  if (last < text.length) out.push(text.slice(last))

  return out
}
