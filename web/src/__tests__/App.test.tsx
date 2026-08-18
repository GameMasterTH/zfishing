import { describe, it, expect, afterEach, vi } from 'vitest'
import { render, cleanup, waitFor, act, screen, fireEvent } from '@testing-library/react'

// Mock เฉพาะ fetchNui ให้ resolve ทันที (คง useNuiEvent จริงไว้)
// เหตุผล: App เรียก loadLocale() -> fetchNui('getLocale') ซึ่งใน jsdom จะ fetch ไป
// https://zfishing/getLocale แล้วค้าง/ช้ากว่าจะ reject ทำให้ ready ไม่ทันเป็น true
// ภายใน timeout ของ waitFor. mock ให้คืน {} เพื่อให้ loadLocale จบเร็ว -> ready=true
// (dict คงเป็น {} -> resolvePromptText ยังใช้ FALLBACK ของ equip/cancel keys ได้)
vi.mock('../hooks/useNui', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../hooks/useNui')>()
  return { ...actual, fetchNui: vi.fn().mockResolvedValue({}) }
})

// Stub RigMenu ให้เป็น component ง่าย ๆ ที่ render testid เดียว
// เหตุผล: task 5.2 ทดสอบเฉพาะ dispatch wiring ของ App (rigOpen -> render, rigClose -> remove)
// ไม่ใช่ internals ของ RigMenu (ซึ่งมี unit test แยกใน RigMenu.test.tsx) การ stub ทำให้
// test โฟกัสที่ state machine ของ App และไม่ผูกกับ loadLocale/asset ของ RigMenu จริง
vi.mock('../components/RigMenu', () => ({
  default: () => <div data-testid="rig-menu" />,
}))

import App from '../App'
import { fetchNui } from '../hooks/useNui'

// Unit tests สำหรับ prompt handling ใน App state machine (task 5.2)
//
// การจำลอง NUI message: useNuiEvent (web/src/hooks/useNui.ts) ผูก listener กับ
// window 'message' event แล้วส่ง e.data เข้า handler ตรง ๆ จึงจำลองด้วยการ
// dispatch MessageEvent('message', { data: <msg> }) ตามรูปแบบที่ client ใช้
// (SendNUIMessage -> window.postMessage)

afterEach(() => cleanup())

function sendMessage(msg: Record<string, unknown>) {
  act(() => {
    window.dispatchEvent(new MessageEvent('message', { data: msg }))
  })
}

describe('App prompt handling', () => {
  // R2.1: view='hidden' (state เริ่มต้น) แต่ action 'prompt' -> PromptHud ต้องปรากฏ
  it('renders PromptHud when action "prompt" arrives while view is hidden (R2.1)', async () => {
    const { container } = render(<App />)

    sendMessage({
      action: 'prompt',
      titleKey: 'equip_title',
      subtitleKey: 'equip_hint',
    })

    await waitFor(() => {
      expect(container.querySelector('.prompt-hud')).not.toBeNull()
    })
    // ยืนยันว่า view ยังคง hidden (ไม่มี hud-root) — prompt เป็น overlay อิสระ
    expect(container.querySelector('.hud-root')).toBeNull()
  })

  // R2.2 / R2.6: หลังแสดง prompt แล้ว action 'promptHide' -> PromptHud หายไป (prompt=null)
  it('clears the prompt when action "promptHide" arrives (R2.2/R2.6)', async () => {
    const { container } = render(<App />)

    sendMessage({
      action: 'prompt',
      titleKey: 'equip_title',
      subtitleKey: 'equip_hint',
    })
    await waitFor(() => {
      expect(container.querySelector('.prompt-hud')).not.toBeNull()
    })

    sendMessage({ action: 'promptHide' })
    await waitFor(() => {
      expect(container.querySelector('.prompt-hud')).toBeNull()
    })
  })

  // R2.4: หลังแสดง prompt แล้ว action 'hide' (cleanup) -> PromptHud หายไป (prompt เคลียร์)
  it('clears the prompt when action "hide" arrives (R2.4)', async () => {
    const { container } = render(<App />)

    sendMessage({
      action: 'prompt',
      titleKey: 'cancel_title',
      subtitleKey: 'cancel_hint',
    })
    await waitFor(() => {
      expect(container.querySelector('.prompt-hud')).not.toBeNull()
    })

    sendMessage({ action: 'hide' })
    await waitFor(() => {
      expect(container.querySelector('.prompt-hud')).toBeNull()
    })
  })
})

// Unit tests สำหรับ rig menu dispatch ใน App state machine (task 5.2)
//
// useNuiEvent ผูก listener กับ window 'message' แล้วส่ง e.data เข้า handler ตรง ๆ
// (client ใช้ SendNUIMessage -> window.postMessage) จึงจำลองด้วย sendMessage() ด้านบน
// RigMenu ถูก stub เป็น [data-testid="rig-menu"] เพื่อโฟกัสที่ dispatch ของ App

// Rig_View ขั้นต่ำที่ valid: มีเบ็ดแต่ยังไม่ติดตั้งชิ้นส่วนและไม่มีชิ้นสำรอง
const MINIMAL_VIEW = {
  rod: 'rod_basic',
  rodLabel: 'Basic Rod',
  rodDur: 100,
  rodMax: 100,
  missing: ['reel', 'line', 'hook', 'float'],
  parts: {},
  carried: {},
}
const MINIMAL_CATALOG = [{ partType: 'reel', name: 'reel_cheap', label: 'Cheap Reel' }]

describe('App rig menu dispatch', () => {
  // R2.1: action 'rigOpen' (พร้อม view + catalog) -> RigMenu ต้องถูก render
  it('renders RigMenu when action "rigOpen" arrives (R2.1)', async () => {
    const { container } = render(<App />)

    sendMessage({
      action: 'rigOpen',
      view: MINIMAL_VIEW,
      catalog: MINIMAL_CATALOG,
    })

    await waitFor(() => {
      expect(container.querySelector('[data-testid="rig-menu"]')).not.toBeNull()
    })
    // rig เป็น overlay อิสระ — view หลักยังคง hidden (ไม่มี hud-root)
    expect(container.querySelector('.hud-root')).toBeNull()
  })

  // R2.1: หลังเปิด rig แล้ว action 'rigClose' -> RigMenu ถูกเอาออก (rig=null)
  it('removes RigMenu when action "rigClose" arrives (R2.1)', async () => {
    const { container } = render(<App />)

    sendMessage({
      action: 'rigOpen',
      view: MINIMAL_VIEW,
      catalog: MINIMAL_CATALOG,
    })
    await waitFor(() => {
      expect(container.querySelector('[data-testid="rig-menu"]')).not.toBeNull()
    })

    sendMessage({ action: 'rigClose' })
    await waitFor(() => {
      expect(container.querySelector('[data-testid="rig-menu"]')).toBeNull()
    })
  })
})

// Unit test สำหรับ catch card (task 7): Keep/Release เดิมทั้งคู่เรียก closeCatchCard()
// เหมือนกัน (ปลาถูกมอบไปแล้วตอน claim ก่อนการ์ดจะ render) การเลือกจึงเป็นแค่ภาพลวงตา
// เหลือปุ่มเดียว 'Continue' ที่ยังผูกกับ callback 'keep' เดิม (teardown path ฝั่ง Lua)

describe('App catch card dispatch', () => {
  it('the catch card offers a single Continue action', async () => {
    render(<App />)

    sendMessage({ action: 'caught', label: 'Bass', weight: 2.4, quality: 3 })

    const buttons = await screen.findAllByRole('button')
    expect(buttons).toHaveLength(1)

    fireEvent.click(buttons[0])
    expect(fetchNui).toHaveBeenCalledWith('keep')
  })
})
