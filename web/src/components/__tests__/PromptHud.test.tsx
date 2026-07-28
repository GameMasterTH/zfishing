import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup } from '@testing-library/react'
import PromptHud from '../PromptHud'

// Unit tests สำหรับ PromptHud (task 4.3)
//
// หมายเหตุเรื่อง localization: i18n dict เป็นค่าว่าง {} โดย default ใน test env
// (ไม่มีการเรียก loadLocale / ไม่มี NUI) ดังนั้น:
//   - key ที่มีใน FALLBACK (equip_title/equip_hint) -> resolvePromptText คืนค่า fallback ที่ไม่ว่าง
//   - key ที่ไม่มีใน FALLBACK -> resolvePromptText คืนสตริงว่าง -> prepareLine คืน null
// สมบัตินี้ทำให้ทดสอบทั้งกรณีมีข้อความ (R1.3) และกรณีว่างทั้งคู่ (R1.7) ได้อย่างเชื่อถือได้

afterEach(() => cleanup())

describe('PromptHud', () => {
  // R1.3: Subtitle_Text วางอยู่ใต้ Title_Text -> DOM order: .prompt-title ก่อน .prompt-subtitle
  it('renders .prompt-title before .prompt-subtitle in DOM order (R1.3)', () => {
    const { container } = render(
      <PromptHud titleKey="equip_title" subtitleKey="equip_hint" />,
    )

    const title = container.querySelector('.prompt-title')
    const subtitle = container.querySelector('.prompt-subtitle')

    // ทั้งสองบรรทัดต้องถูก render (fallback ของ equip_title/equip_hint ไม่ว่าง)
    expect(title).not.toBeNull()
    expect(subtitle).not.toBeNull()

    // ยืนยันลำดับผ่าน querySelectorAll (document order)
    const nodes = Array.from(
      container.querySelectorAll('.prompt-title, .prompt-subtitle'),
    )
    expect(nodes[0]).toBe(title)
    expect(nodes[1]).toBe(subtitle)

    // ยืนยันลำดับผ่าน compareDocumentPosition (title มาก่อน subtitle)
    const position = title!.compareDocumentPosition(subtitle!)
    expect(position & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  // R1.7: เมื่อ title และ subtitle ว่างทั้งคู่ -> component คืน null (container ว่าง)
  it('renders nothing when both title and subtitle resolve empty (R1.7)', () => {
    // ใช้ key ที่ไม่มีใน FALLBACK และไม่มีใน dict (ว่าง) -> resolve เป็นสตริงว่างทั้งคู่
    const { container } = render(
      <PromptHud
        titleKey="__no_such_title_key__"
        subtitleKey="__no_such_subtitle_key__"
      />,
    )

    expect(container.firstChild).toBeNull()
    expect(container.querySelector('.prompt-hud')).toBeNull()
  })
})
