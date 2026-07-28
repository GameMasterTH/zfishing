import { useEffect, useState } from 'react'
import { adminSave, TabProps } from './AdminPanel'
import { t, tOr } from '../i18n'
import { Btn, Field, NumInput, SaveBar, Section, Select, TextInput, Toggle, useDraft, useToast } from './ui'

const TIMING_KEYS = ['biteMin', 'biteMax', 'hookWindow', 'hookLatency', 'reelTimeout'] as const

export default function SettingsTab({ cfg, setCfg, reportDirty }: TabProps) {
  const d = useDraft<Record<string, any>>(cfg.settings)
  const [busy, setBusy] = useState(false)
  const toast = useToast()

  useEffect(() => { reportDirty(d.dirtyKeys.length > 0) }, [d.dirtyKeys.length])

  const save = async () => {
    setBusy(true)
    const failed: string[] = []
    for (const key of d.dirtyKeys) {
      const res = await adminSave('zfishing:admin:saveSetting', key, d.draft[key])
      if (!res.ok) failed.push(key + (res.err ? ` (${res.err})` : ''))
    }
    setBusy(false)
    if (failed.length) {
      toast(t('ui_toast_fail', failed.join(', ')), 'err')
    } else {
      toast(t('ui_toast_saved'))
      d.markSaved()
      setCfg({ ...cfg, settings: d.draft })
    }
  }

  const s = d.draft

  return (
    <div>
      <Section title={t('ui_sec_fishing')}>
        <Field label={t('ui_set_RateLimit')} hint={t('ui_set_RateLimit_hint')} dirty={d.isDirty('RateLimit')}>
          <NumInput value={s.RateLimit} onChange={(v) => d.set('RateLimit', v)} />
        </Field>
        <Field label={t('ui_set_CastMaxDistance')} hint={t('ui_set_CastMaxDistance_hint')} dirty={d.isDirty('CastMaxDistance')}>
          <NumInput value={s.CastMaxDistance} onChange={(v) => d.set('CastMaxDistance', v)} />
        </Field>
      </Section>

      <Section title={t('ui_sec_gear')} hint={t('ui_sec_gear_hint')}>
        <Field label={t('ui_set_Durability')} hint={t('ui_set_Durability_hint')} dirty={d.isDirty('Durability')}>
          <Toggle checked={!!s.Durability} onChange={(v) => d.set('Durability', v)} />
        </Field>
        <Field label={t('ui_set_RodCanBreak')} hint={t('ui_set_RodCanBreak_hint')} dirty={d.isDirty('RodCanBreak')}>
          <Toggle checked={!!s.RodCanBreak} onChange={(v) => d.set('RodCanBreak', v)} />
        </Field>
        <Field label={t('ui_set_RequireAssembly')} hint={t('ui_set_RequireAssembly_hint')} dirty={d.isDirty('RequireAssembly')}>
          <Toggle checked={!!s.RequireAssembly} onChange={(v) => d.set('RequireAssembly', v)} />
        </Field>
      </Section>

      <Section title={t('ui_sec_zone')}>
        <Field label={t('ui_set_RequireZone')} hint={t('ui_set_RequireZone_hint')} dirty={d.isDirty('RequireZone')}>
          <Toggle checked={!!s.RequireZone} onChange={(v) => d.set('RequireZone', v)} />
        </Field>
        <Field label={t('ui_set_DefaultWater')} hint={t('ui_set_DefaultWater_hint')} dirty={d.isDirty('DefaultWater')}>
          <Select
            value={s.DefaultWater}
            disabled={!!s.RequireZone}
            onChange={(v) => d.set('DefaultWater', v)}
            options={cfg.waterTypes.map((w) => ({ value: w, label: tOr('ui_water_' + w, w) }))}
          />
        </Field>
      </Section>

      <Section title={t('ui_sec_timing')}>
        {TIMING_KEYS.map((k) => (
          <Field key={k} label={t('ui_tm_' + k)} dirty={d.isDirty('Timings')}>
            <NumInput value={s.Timings[k]} onChange={(v) => d.set('Timings', { ...s.Timings, [k]: v })} />
          </Field>
        ))}
      </Section>

      <Section title={t('ui_sec_loot')} hint={t('ui_loot_hint')}>
        <div className="adm-table-head">
          <span style={{ flex: 2 }}>{t('ui_loot_item')}</span>
          <span style={{ width: 110 }}>{t('ui_loot_chance')}</span>
          <span style={{ width: 70 }} />
        </div>
        {s.RareLoot.map((loot: any, i: number) => (
          <div className="adm-row" key={i}>
            <div style={{ flex: 2 }}>
              <TextInput value={loot.item} width={220} onChange={(v) => {
                const next = [...s.RareLoot]; next[i] = { ...loot, item: v }; d.set('RareLoot', next)
              }} />
            </div>
            <NumInput value={loot.chance} step={0.001} width={110} onChange={(v) => {
              const next = [...s.RareLoot]; next[i] = { ...loot, chance: v }; d.set('RareLoot', next)
            }} />
            <Btn variant="danger" onClick={() => d.set('RareLoot', s.RareLoot.filter((_: any, j: number) => j !== i))}>
              {t('ui_delete')}
            </Btn>
          </div>
        ))}
        <div style={{ marginTop: 10 }}>
          <Btn onClick={() => d.set('RareLoot', [...s.RareLoot, { item: '', chance: 0.01, label: '' }])}>
            + {t('ui_loot_add')}
          </Btn>
        </div>
      </Section>

      <SaveBar count={d.dirtyKeys.length} busy={busy} onSave={save} onDiscard={d.discard} />
    </div>
  )
}
