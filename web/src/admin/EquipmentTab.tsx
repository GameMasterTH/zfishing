import { useEffect, useState } from 'react'
import { adminSave, TabProps } from './AdminPanel'
import { t, tOr } from '../i18n'
import { Btn, ConfirmModal, ConfirmSpec, Field, NumInput, SaveBar, TextInput, useDraft, useToast } from './ui'

const SLOTS = ['rods', 'reels', 'lines', 'hooks', 'floats', 'baits']
// stable display order for known stat keys; anything else renders after, raw
const KEY_ORDER = ['level', 'durability', 'degrade', 'rating', 'drainRate', 'biteSpeed', 'hookMod', 'greenZone', 'rareBonus']

function statKeys(data: Record<string, any>) {
  const nums = Object.keys(data).filter((k) => k !== 'label' && typeof data[k] === 'number')
  return nums.sort((a, b) => {
    const ia = KEY_ORDER.indexOf(a), ib = KEY_ORDER.indexOf(b)
    return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib)
  })
}

export default function EquipmentTab({ cfg, setCfg, reportDirty }: TabProps) {
  const [slot, setSlot] = useState('rods')
  return (
    <EquipmentSlot key={slot} slot={slot} setSlot={setSlot} cfg={cfg} setCfg={setCfg} reportDirty={reportDirty} />
  )
}

function EquipmentSlot({ slot, setSlot, cfg, setCfg, reportDirty }: TabProps & { slot: string; setSlot: (s: string) => void }) {
  const d = useDraft<Record<string, any>>(cfg.equipment[slot] ?? {})
  const [busy, setBusy] = useState(false)
  const [modal, setModal] = useState<ConfirmSpec | null>(null)
  const toast = useToast()
  const dirty = d.dirtyKeys.length > 0

  useEffect(() => { reportDirty(dirty) }, [dirty])

  const save = async () => {
    setBusy(true)
    const failed: string[] = []
    for (const item of d.dirtyKeys) {
      const res = await adminSave('zfishing:admin:saveEquipment', slot, item, d.draft[item])
      if (!res.ok) failed.push(item + (res.err ? ` (${res.err})` : ''))
    }
    setBusy(false)
    if (failed.length) {
      toast(t('ui_toast_fail', failed.join(', ')), 'err')
    } else {
      toast(t('ui_toast_saved'))
      d.markSaved()
      setCfg({ ...cfg, equipment: { ...cfg.equipment, [slot]: d.draft } })
    }
  }

  const resetAll = () => setModal({
    title: t('ui_eq_reset'),
    body: t('ui_eq_reset_body'),
    danger: true,
    onConfirm: async () => {
      const res = await adminSave('zfishing:admin:resetDomain', 'equipment')
      toast(res.ok ? t('ui_reset_done') : t('ui_toast_fail', res.err ?? '?'), res.ok ? 'ok' : 'err')
    },
  })

  return (
    <div>
      <div className="adm-pills" style={dirty ? { opacity: 0.5, pointerEvents: 'none' } : undefined}>
        {SLOTS.map((sName) => (
          <button key={sName} className={'adm-pill' + (sName === slot ? ' active' : '')} onClick={() => setSlot(sName)}>
            {t('ui_slot_' + sName)}
          </button>
        ))}
      </div>

      <div className="adm-cards">
        {Object.entries(d.draft).map(([item, data]: [string, any]) => (
          <div key={item} className={'adm-card' + (d.isDirty(item) ? ' dirty' : '')}>
            <div className="adm-card-head">
              <code>{item}</code>
            </div>
            <Field label={t('ui_eq_label')}>
              <TextInput value={data.label} onChange={(v) => d.set(item, { ...data, label: v })} />
            </Field>
            {statKeys(data).map((k) => (
              <Field key={k} label={tOr('ui_eq_' + k, k)} hint={tOr('ui_eq_' + k + '_hint', '') || undefined}>
                <NumInput value={data[k]} step={0.01} onChange={(v) => d.set(item, { ...data, [k]: v })} />
              </Field>
            ))}
          </div>
        ))}
      </div>

      <div style={{ marginTop: 16 }}>
        <Btn variant="danger" onClick={resetAll}>{t('ui_eq_reset')}</Btn>
      </div>

      <SaveBar count={d.dirtyKeys.length} busy={busy} onSave={save} onDiscard={d.discard} />
      <ConfirmModal spec={modal} onClose={() => setModal(null)} />
    </div>
  )
}
