// Small square-cornered UI kit for the admin panel — no external deps.
// Every tab composes these + useDraft for the shared dirty/save-all flow.
import { createContext, useContext, useMemo, useState } from 'react'
import { t } from '../i18n'

// ---------------------------------------------------------------- layout

export function Section(props: { title: string; hint?: string; children: React.ReactNode }) {
  return (
    <section className="adm-section">
      <div className="adm-section-head">
        <h2>{props.title}</h2>
        {props.hint && <p className="adm-hint">{props.hint}</p>}
      </div>
      {props.children}
    </section>
  )
}

export function Field(props: { label: string; hint?: string; dirty?: boolean; children: React.ReactNode }) {
  return (
    <div className={'adm-field' + (props.dirty ? ' dirty' : '')}>
      <div className="adm-field-label">
        <label>{props.label}</label>
        {props.hint && <span className="adm-hint">{props.hint}</span>}
      </div>
      <div className="adm-field-control">{props.children}</div>
    </div>
  )
}

// ---------------------------------------------------------------- controls

export function Toggle(props: { checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <button
      type="button"
      className={'adm-toggle' + (props.checked ? ' on' : '')}
      onClick={() => props.onChange(!props.checked)}
    >
      <span className="adm-toggle-knob" />
    </button>
  )
}

export function NumInput(props: { value: number; onChange: (v: number) => void; step?: number; width?: number }) {
  return (
    <input
      type="number"
      className="adm-input"
      style={props.width ? { width: props.width } : undefined}
      step={props.step ?? 1}
      value={props.value}
      onChange={(e) => props.onChange(+e.target.value)}
    />
  )
}

export function TextInput(props: { value: string; onChange: (v: string) => void; placeholder?: string; width?: number }) {
  return (
    <input
      className="adm-input"
      style={props.width ? { width: props.width } : undefined}
      value={props.value}
      placeholder={props.placeholder}
      onChange={(e) => props.onChange(e.target.value)}
    />
  )
}

export function Select(props: {
  value: string
  onChange: (v: string) => void
  options: { value: string; label: string }[]
  disabled?: boolean
}) {
  return (
    <select
      className="adm-input"
      value={props.value}
      disabled={props.disabled}
      onChange={(e) => props.onChange(e.target.value)}
    >
      {props.options.map((o) => (
        <option key={o.value} value={o.value}>{o.label}</option>
      ))}
    </select>
  )
}

export function Btn(props: {
  variant?: 'primary' | 'ghost' | 'danger'
  onClick: () => void
  disabled?: boolean
  children: React.ReactNode
}) {
  return (
    <button
      type="button"
      className={'adm-btn ' + (props.variant ?? 'ghost')}
      disabled={props.disabled}
      onClick={props.onClick}
    >
      {props.children}
    </button>
  )
}

// ---------------------------------------------------------------- save bar

export function SaveBar(props: { count: number; busy: boolean; onSave: () => void; onDiscard: () => void }) {
  if (props.count === 0) return null
  return (
    <div className="adm-savebar">
      <span>{props.busy ? t('ui_save_busy') : t('ui_save_dirty', props.count)}</span>
      <div className="adm-savebar-actions">
        <Btn variant="ghost" disabled={props.busy} onClick={props.onDiscard}>{t('ui_save_discard')}</Btn>
        <Btn variant="primary" disabled={props.busy} onClick={props.onSave}>{t('ui_save_all')}</Btn>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------- modal

export type ConfirmSpec = {
  title: string
  body: string
  confirmLabel?: string
  danger?: boolean
  onConfirm: () => void
}

export function ConfirmModal(props: { spec: ConfirmSpec | null; onClose: () => void }) {
  const s = props.spec
  if (!s) return null
  return (
    <div className="adm-modal-backdrop" onClick={props.onClose}>
      <div className="adm-modal" onClick={(e) => e.stopPropagation()}>
        <h3>{s.title}</h3>
        <p>{s.body}</p>
        <div className="adm-modal-actions">
          <Btn variant="ghost" onClick={props.onClose}>{t('ui_modal_cancel')}</Btn>
          <Btn variant={s.danger ? 'danger' : 'primary'} onClick={() => { s.onConfirm(); props.onClose() }}>
            {s.confirmLabel ?? t('ui_modal_confirm')}
          </Btn>
        </div>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------- toasts

type Toast = { id: number; msg: string; kind: 'ok' | 'err' }
const ToastCtx = createContext<(msg: string, kind?: 'ok' | 'err') => void>(() => {})

export const useToast = () => useContext(ToastCtx)

export function ToastProvider(props: { children: React.ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([])
  const push = useMemo(() => {
    let nextId = 1
    return (msg: string, kind: 'ok' | 'err' = 'ok') => {
      const id = nextId++
      setToasts((ts) => [...ts, { id, msg, kind }])
      setTimeout(() => setToasts((ts) => ts.filter((x) => x.id !== id)), 3500)
    }
  }, [])
  return (
    <ToastCtx.Provider value={push}>
      {props.children}
      <div className="adm-toasts">
        {toasts.map((x) => (
          <div key={x.id} className={'adm-toast ' + x.kind}>{x.msg}</div>
        ))}
      </div>
    </ToastCtx.Provider>
  )
}

// ---------------------------------------------------------------- draft state

// Per-tab dirty tracking over a flat record: compares each top-level key by
// JSON value. save() should persist dirtyKeys then call markSaved().
export function useDraft<T extends Record<string, any>>(original: T) {
  const [base, setBase] = useState<T>(original)
  const [draft, setDraft] = useState<T>(original)

  const dirtyKeys = useMemo(() => {
    const keys = new Set([...Object.keys(base), ...Object.keys(draft)])
    return [...keys].filter((k) => JSON.stringify(base[k]) !== JSON.stringify(draft[k]))
  }, [base, draft])

  return {
    draft,
    dirtyKeys,
    isDirty: (k: string) => JSON.stringify(base[k]) !== JSON.stringify(draft[k]),
    set: (k: string, v: any) => setDraft((d) => ({ ...d, [k]: v })),
    replace: (next: T) => { setBase(next); setDraft(next) },
    discard: () => setDraft(base),
    markSaved: () => setBase(draft),
  }
}
