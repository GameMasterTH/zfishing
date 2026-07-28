import { useEffect, useState } from 'react'
import { adminSave, TabProps } from './AdminPanel'
import { t, tOr } from '../i18n'
import { Btn, ConfirmModal, ConfirmSpec, NumInput, SaveBar, Select, TextInput, useDraft, useToast } from './ui'

export default function ZonesTab({ cfg, setCfg, reportDirty }: TabProps) {
  // keyed by zone id so useDraft can diff per zone
  const d = useDraft<Record<string, any>>(
    Object.fromEntries(cfg.zones.map((z) => [String(z.id), z]))
  )
  const [busy, setBusy] = useState(false)
  const [modal, setModal] = useState<ConfirmSpec | null>(null)
  const toast = useToast()

  useEffect(() => { reportDirty(d.dirtyKeys.length > 0) }, [d.dirtyKeys.length])

  const save = async () => {
    setBusy(true)
    const failed: string[] = []
    for (const id of d.dirtyKeys) {
      const res = await adminSave('zfishing:admin:saveZone', d.draft[id])
      if (!res.ok) failed.push(d.draft[id].name + (res.err ? ` (${res.err})` : ''))
    }
    setBusy(false)
    if (failed.length) {
      toast(t('ui_toast_fail', failed.join(', ')), 'err')
    } else {
      toast(t('ui_toast_saved'))
      d.markSaved()
      setCfg({ ...cfg, zones: Object.values(d.draft) })
    }
  }

  const askDelete = (z: any) => setModal({
    title: t('ui_zone_delete_title'),
    body: t('ui_zone_delete_body', z.name),
    danger: true,
    confirmLabel: t('ui_delete'),
    onConfirm: async () => {
      const res = await adminSave('zfishing:admin:deleteZone', z.id)
      if (res.ok) {
        const next = { ...d.draft }
        delete next[String(z.id)]
        d.replace(next)
        setCfg({ ...cfg, zones: Object.values(next) })
        toast(t('ui_toast_saved'))
      } else {
        toast(t('ui_toast_fail', res.err ?? '?'), 'err')
      }
    },
  })

  const zones = Object.values(d.draft)

  return (
    <div>
      <p className="adm-hint" style={{ marginBottom: 12 }}>{t('ui_zone_hint')}</p>

      {zones.length === 0 && <p className="adm-hint">{t('ui_zone_empty')}</p>}

      {zones.length > 0 && (
        <div className="adm-table-head">
          <span style={{ flex: 2 }}>{t('ui_zone_name')}</span>
          <span style={{ width: 140 }}>{t('ui_zone_water')}</span>
          <span style={{ width: 110 }}>{t('ui_zone_radius')}</span>
          <span style={{ width: 70 }} />
        </div>
      )}
      {zones.map((z: any) => {
        const id = String(z.id)
        return (
          <div className={'adm-row' + (d.isDirty(id) ? ' dirty' : '')} key={id}>
            <div style={{ flex: 2 }}>
              <TextInput value={z.name} width={240} onChange={(v) => d.set(id, { ...z, name: v })} />
            </div>
            <div style={{ width: 140 }}>
              <Select
                value={z.water}
                onChange={(v) => d.set(id, { ...z, water: v })}
                options={cfg.waterTypes.map((w) => ({ value: w, label: tOr('ui_water_' + w, w) }))}
              />
            </div>
            <NumInput value={z.radius} width={110} onChange={(v) => d.set(id, { ...z, radius: v })} />
            <Btn variant="danger" onClick={() => askDelete(z)}>{t('ui_delete')}</Btn>
          </div>
        )
      })}

      <SaveBar count={d.dirtyKeys.length} busy={busy} onSave={save} onDiscard={d.discard} />
      <ConfirmModal spec={modal} onClose={() => setModal(null)} />
    </div>
  )
}
