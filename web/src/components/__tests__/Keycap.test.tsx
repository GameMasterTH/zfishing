import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup, screen } from '@testing-library/react'
import Keycap, { renderWithKeycaps } from '../Keycap'

afterEach(() => cleanup())

describe('Keycap', () => {
  it('renders the label inside a .keycap element', () => {
    render(<Keycap label="G" />)
    const cap = document.querySelector('.keycap')
    expect(cap).not.toBeNull()
    expect(cap!.textContent).toBe('G')
  })

  it('adds a variant modifier class when asked', () => {
    render(<Keycap label="SPACE" variant="urgent" />)
    expect(document.querySelector('.keycap--urgent')).not.toBeNull()
  })
})

describe('renderWithKeycaps', () => {
  it('turns every [KEY] run into a keycap and drops the brackets', () => {
    render(<div data-testid="host">{renderWithKeycaps('[E] เริ่มตกปลา   ·   [G] จัดการเบ็ด')}</div>)
    const host = screen.getByTestId('host')

    const caps = host.querySelectorAll('.keycap')
    expect(caps.length).toBe(2)
    expect(caps[0].textContent).toBe('E')
    expect(caps[1].textContent).toBe('G')

    // ข้อความรอบ ๆ ต้องคงอยู่ครบ เหลือแค่วงเล็บที่หายไป
    expect(host.textContent).toBe('E เริ่มตกปลา   ·   G จัดการเบ็ด')
  })

  it('passes text through untouched when there is no [KEY]', () => {
    render(<div data-testid="host">{renderWithKeycaps('รอปลากินเบ็ด…')}</div>)
    const host = screen.getByTestId('host')
    expect(host.querySelectorAll('.keycap').length).toBe(0)
    expect(host.textContent).toBe('รอปลากินเบ็ด…')
  })

  it('handles a string that is nothing but a key', () => {
    render(<div data-testid="host">{renderWithKeycaps('[SPACE]')}</div>)
    const host = screen.getByTestId('host')
    expect(host.querySelectorAll('.keycap').length).toBe(1)
    expect(host.textContent).toBe('SPACE')
  })
})
