import { useEffect, useState } from 'react'
import { adminSave, TabProps } from './AdminPanel'
import { t, tOr } from '../i18n'
import { Btn, ConfirmModal, ConfirmSpec, Field, NumInput, SaveBar, Section, Select, TextInput, useDraft, useToast } from './ui'

const BEHAVIORS = ['steady_light', 'steady_heavy', 'run_stop', 'erratic']

export default function FishTab({ cfg, setCfg, reportDirty }: TabProps) {
  const d = useDraft<Record<string, any>>(cfg.fish)
  const [sel, setSel] = useState<string>(Object.keys(cfg.fish)[0] ?? '')
  const [query, setQuery] = useState('')
  const [newKey, setNewKey] = useState('')
  const [busy, setBusy] = useState(false)
  const [modal, setModal] = useState<ConfirmSpec | null>(null)
  const toast = useToast()

  useEffect(() => { reportDirty(d.dirtyKeys.length > 0) }, [d.dirtyKeys.length])

  const save = async () => {
    setBusy(true)
    const failed: string[] = []
    for (const key of d.dirtyKeys) {
      const res = await adminSave('zfishing:admin:saveFish', key, d.draft[key])
      if (!res.ok) failed.push(key + (res.err ? ` (${res.err})` : ''))
    }
    setBusy(false)
    if (failed.length) {
      toast(t('ui_toast_fail', failed.join(', ')), 'err')
    } else {
      toast(t('ui_toast_saved'))
      d.markSaved()
      setCfg({ ...cfg, fish: d.draft })
    }
  }

  const addSpecies = () => {
    const key = newKey.trim().toLowerCase().replace(/[^a-z0-9_]/g, '_')
    if (!key || d.draft[key]) return
    const blank = {
      label: key, water: ['lake'], weight: { min: 0.5, max: 5 },
      rarity: Object.keys(cfg.rarity)[0], price: 10, baits: [], behavior: 'steady_light', xp: 10,
    }
    d.set(key, blank)
    setSel(key)
    setNewKey('')
  }

  const askDelete = () => setModal({
    title: t('ui_fish_delete_title'),
    body: t('ui_fish_delete_body', sel),
    danger: true,
    confirmLabel: t('ui_delete'),
    onConfirm: async () => {
      const res = await adminSave('zfishing:admin:deleteFish', sel)
      if (res.ok) {
        const next = { ...d.draft }
        delete next[sel]
        d.replace(next)
        setCfg({ ...cfg, fish: next })
        setSel(Object.keys(next)[0] ?? '')
        toast(t('ui_toast_saved'))
      } else {
        toast(t('ui_toast_fail', res.err ?? '?'), 'err')
      }
    },
  })

  const resetAll = () => setModal({
    title: t('ui_fish_reset'),
    body: t('ui_fish_reset_body'),
    danger: true,
    onConfirm: async () => {
      const res = await adminSave('zfishing:admin:resetDomain', 'fish')
      toast(res.ok ? t('ui_reset_done') : t('ui_toast_fail', res.err ?? '?'), res.ok ? 'ok' : 'err')
    },
  })

  const fish = d.draft[sel]
  const setFish = (patch: any) => d.set(sel, { ...fish, ...patch })
  const keys = Object.keys(d.draft).filter((k) => k.includes(query.toLowerCase()))

  return (
    <div>
      <div className="adm-split">
        <div className="adm-split-list">
          <div className="adm-row">
            <TextInput value={query} placeholder={t('ui_fish_search')} width={190} onChange={setQuery} />
          </div>
          <div className="list-scroll">
            {keys.map((k) => (
              <div
                key={k}
                className={'adm-row clickable' + (k === sel ? ' active' : '') + (d.isDirty(k) ? ' dirty' : '')}
                onClick={() => setSel(k)}
              >
                {k}
              </div>
            ))}
          </div>
          <div className="adm-row">
            <TextInput value={newKey} placeholder={t('ui_fish_new_ph')} width={150} onChange={setNewKey} />
            <Btn variant="primary" onClick={addSpecies}>+</Btn>
          </div>
        </div>

        {fish && (
          <div className="adm-split-body">
            <Section title={fish.label || sel}>
              <Field label={t('ui_fish_label')}>
                <TextInput value={fish.label} onChange={(v) => setFish({ label: v })} />
              </Field>
              <Field label={t('ui_fish_rarity')}>
                <Select
                  value={fish.rarity}
                  onChange={(v) => setFish({ rarity: v })}
                  options={Object.keys(cfg.rarity).map((r) => ({ value: r, label: r }))}
                />
              </Field>
              <Field label={t('ui_fish_behavior')}>
                <Select
                  value={fish.behavior}
                  onChange={(v) => setFish({ behavior: v })}
                  options={BEHAVIORS.map((b) => ({ value: b, label: t('ui_bhv_' + b) }))}
                />
              </Field>
              <Field label={t('ui_fish_price')}>
                <NumInput value={fish.price} onChange={(v) => setFish({ price: v })} />
              </Field>
              <Field label={t('ui_fish_xp')}>
                <NumInput value={fish.xp} onChange={(v) => setFish({ xp: v })} />
              </Field>
              <Field label={t('ui_fish_wmin')}>
                <NumInput value={fish.weight.min} step={0.1} onChange={(v) => setFish({ weight: { ...fish.weight, min: v } })} />
              </Field>
              <Field label={t('ui_fish_wmax')}>
                <NumInput value={fish.weight.max} step={0.1} onChange={(v) => setFish({ weight: { ...fish.weight, max: v } })} />
              </Field>
              <Field label={t('ui_fish_water')}>
                <div className="adm-pills" style={{ marginBottom: 0 }}>
                  {cfg.waterTypes.map((w) => {
                    const on = fish.water.includes(w)
                    return (
                      <button
                        key={w}
                        className={'adm-pill' + (on ? ' active' : '')}
                        onClick={() => setFish({ water: on ? fish.water.filter((x: string) => x !== w) : [...fish.water, w] })}
                      >
                        {tOr('ui_water_' + w, w)}
                      </button>
                    )
                  })}
                </div>
              </Field>
              <Field label={t('ui_fish_baits')}>
                <TextInput
                  value={fish.baits.join(', ')}
                  width={280}
                  onChange={(v) => setFish({ baits: v.split(',').map((x) => x.trim()).filter(Boolean) })}
                />
              </Field>
            </Section>
            <div style={{ display: 'flex', gap: 8 }}>
              <Btn variant="danger" onClick={askDelete}>{t('ui_fish_delete_title')}</Btn>
              <Btn variant="danger" onClick={resetAll}>{t('ui_fish_reset')}</Btn>
            </div>
          </div>
        )}
      </div>

      <SaveBar count={d.dirtyKeys.length} busy={busy} onSave={save} onDiscard={d.discard} />
      <ConfirmModal spec={modal} onClose={() => setModal(null)} />
    </div>
  )
}
