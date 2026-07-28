import { describe, it, expect, beforeEach, vi, type Mock } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import RigMenu from '../RigMenu'
import type { CatalogEntry, RigView } from '../../rigRows'

// mock NUI bridge — fetchNui ไม่ยิง fetch จริงในสภาพ jsdom
vi.mock('../../hooks/useNui', () => ({
  fetchNui: vi.fn(() => Promise.resolve({})),
}))

// mock i18n — loadLocale คุมได้ต่อเทสต์; tOr คืน fallback (arg2) เพื่อให้ rigText
// คืนค่าจากตาราง FALLBACK ที่รู้แน่ ๆ (predictable strings)
vi.mock('../../i18n', () => ({
  loadLocale: vi.fn(() => Promise.resolve()),
  tOr: (_key: string, fallback: string) => fallback,
  t: (key: string) => key,
}))

import { fetchNui } from '../../hooks/useNui'
import { loadLocale } from '../../i18n'

// ค่าคาดหวังจาก rigText FALLBACK (เมื่อ tOr คืน fallback)
const TITLE = 'Manage Rod'
const CLOSE_HINT = 'Press ESC to close'
const EMPTY = 'No rod parts to manage'
const LOCALE_ERROR = 'Language failed to load'

const catalog: CatalogEntry[] = [
  { partType: 'reel', name: 'reel_cheap', label: 'Cheap Reel' },
]

// view ที่ทำให้ reel_cheap มี owned = 1 (ไม่ dimmed) และไม่ได้ติดตั้ง
const view: RigView = {
  rod: 'rod_basic',
  rodLabel: 'Basic Rod',
  parts: {},
  carried: {
    reel: [{ slot: 1, name: 'reel_cheap', label: 'Cheap Reel', dur: 100, max: 100 }],
    line: [],
    hook: [],
    float: [],
  },
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe('RigMenu', () => {
  it('renders title + close hint and 4 category cards', async () => {
    const { unmount } = render(<RigMenu view={view} catalog={catalog} />)

    expect(await screen.findByText(TITLE)).toBeTruthy()
    expect(screen.getByText(CLOSE_HINT)).toBeTruthy()

    const cards = document.querySelectorAll('.rig-category-card')
    expect(cards).toHaveLength(4)

    unmount()
  })

  it('renders flyout sub-menu when hovering category card', async () => {
    render(<RigMenu view={view} catalog={catalog} />)
    await screen.findByText(TITLE)

    const cards = document.querySelectorAll('.rig-category-card')
    fireEvent.mouseEnter(cards[0]) // Hover reel category

    const flyout = document.querySelector('.rig-flyout-panel')
    expect(flyout).not.toBeNull()

    const img = document.querySelector('.rig-item-row__icon img') as HTMLImageElement | null
    expect(img).not.toBeNull()
    expect(img!.getAttribute('src')).toContain('assets/items/reel_cheap.png')

    // เลื่อนเมาส์ออกจากเมนู → sub-menu หายไป
    const container = document.querySelector('.rig-menu__container')!
    fireEvent.mouseLeave(container)
    expect(document.querySelector('.rig-flyout-panel')).toBeNull()
  })

  it('กด ESC ขณะเมนูเปิด → เรียก fetchNui("rigClose")', async () => {
    render(<RigMenu view={view} catalog={catalog} />)
    await screen.findByText(TITLE)

    fireEvent.keyDown(window, { key: 'Escape' })

    expect(fetchNui).toHaveBeenCalledWith('rigClose')
  })

  it('คลิกพื้นที่ด้านนอกเมนู (overlay) → เรียก fetchNui("rigClose")', async () => {
    render(<RigMenu view={view} catalog={catalog} />)
    await screen.findByText(TITLE)

    const overlay = document.querySelector('.rig-menu__overlay')!
    expect(overlay).not.toBeNull()
    fireEvent.click(overlay)

    expect(fetchNui).toHaveBeenCalledWith('rigClose')
  })

  it('เมื่อ loadLocale reject → ยังเรนเดอร์ต่อและแสดงตัวบ่งชี้ rig_locale_error', async () => {
    ;(loadLocale as Mock).mockRejectedValueOnce(new Error('locale fail'))

    render(<RigMenu view={view} catalog={catalog} />)

    expect(await screen.findByText(LOCALE_ERROR)).toBeTruthy()
    expect(screen.getByText(TITLE)).toBeTruthy()
  })
})
