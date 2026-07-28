import { useRef, useState } from 'react'
import { fetchNui } from '../hooks/useNui'
import { t } from '../i18n'
import { ConfirmModal, ConfirmSpec, ToastProvider } from './ui'
import SettingsTab from './SettingsTab'
import ZonesTab from './ZonesTab'
import FishTab from './FishTab'
import EquipmentTab from './EquipmentTab'
import './admin.css'

export type AdminConfig = {
  settings: any
  zones: any[]
  fish: Record<string, any>
  equipment: Record<string, Record<string, any>>
  rarity: Record<string, any>
  waterTypes: string[]
}

export async function adminSave(cbName: string, ...args: any[]) {
  return fetchNui<{ ok?: boolean; err?: string; id?: number }>('adminSave', { cbName, args })
}

export type TabProps = {
  cfg: AdminConfig
  setCfg: (c: AdminConfig) => void
  // tabs report whether they hold unsaved edits so the shell can warn on switch
  reportDirty: (dirty: boolean) => void
}

const TABS = [
  { id: 'settings', icon: '⚙', label: 'ui_nav_settings' },
  { id: 'zones', icon: '◎', label: 'ui_nav_zones' },
  { id: 'fish', icon: '⌘', label: 'ui_nav_fish' },
  { id: 'equipment', icon: '⚒', label: 'ui_nav_equipment' },
] as const
type TabId = typeof TABS[number]['id']

export default function AdminPanel({ config, onClose }: { config: AdminConfig; onClose: () => void }) {
  const [tab, setTab] = useState<TabId>('settings')
  const [cfg, setCfg] = useState<AdminConfig>(config)
  const [modal, setModal] = useState<ConfirmSpec | null>(null)
  const dirtyRef = useRef(false)

  const reportDirty = (d: boolean) => { dirtyRef.current = d }

  const guarded = (go: () => void) => {
    if (!dirtyRef.current) return go()
    setModal({
      title: t('ui_modal_unsaved_title'),
      body: t('ui_modal_unsaved_body'),
      confirmLabel: t('ui_modal_discard'),
      danger: true,
      onConfirm: () => { dirtyRef.current = false; go() },
    })
  }

  const switchTab = (next: TabId) => {
    if (next === tab) return
    guarded(() => setTab(next))
  }

  const close = () => guarded(() => {
    fetchNui('adminClose')
    onClose()
  })

  const tabProps: TabProps = { cfg, setCfg, reportDirty }

  return (
    <div className="admin-overlay">
      <div className="admin-window">
        <ToastProvider>
          <header className="admin-header">
            <h1>{t('ui_adm_title')}</h1>
            <button className="admin-close" onClick={close}>✕</button>
          </header>
          <div className="admin-main">
            <nav className="admin-nav">
              {TABS.map((x) => (
                <button key={x.id} className={x.id === tab ? 'active' : ''} onClick={() => switchTab(x.id)}>
                  <span className="icon">{x.icon}</span>{t(x.label)}
                </button>
              ))}
            </nav>
            <main className="admin-body">
              {/* key remounts the tab after a discard so its draft resets */}
              {tab === 'settings' && <SettingsTab key={tab} {...tabProps} />}
              {tab === 'zones' && <ZonesTab key={tab} {...tabProps} />}
              {tab === 'fish' && <FishTab key={tab} {...tabProps} />}
              {tab === 'equipment' && <EquipmentTab key={tab} {...tabProps} />}
            </main>
          </div>
          <ConfirmModal spec={modal} onClose={() => setModal(null)} />
        </ToastProvider>
      </div>
    </div>
  )
}
