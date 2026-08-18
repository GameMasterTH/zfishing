import { useEffect, useState } from 'react'
import { useNuiEvent } from './hooks/useNui'
import { loadLocale } from './i18n'
import FishingInfoCard from './components/FishingInfoCard'
import CastBar from './components/CastBar'
import WaitingHud from './components/WaitingHud'
import TensionMinigame from './components/TensionMinigame'
import CatchCard from './components/CatchCard'
import PromptHud from './components/PromptHud'
import RigMenu from './components/RigMenu'
import AdminPanel from './admin/AdminPanel'
import type { RigView, CatalogEntry } from './rigRows'
import './style.css'

type View = 'hidden' | 'casting' | 'waiting' | 'reeling' | 'caught'
type Prompt = { titleKey: string; subtitleKey: string } | null

export default function App() {
  const [view, setView] = useState<View>('hidden')
  const [data, setData] = useState<any>({})
  const [holding, setHolding] = useState(false)
  const [admin, setAdmin] = useState<any | null>(null)
  const [ready, setReady] = useState(false)
  const [prompt, setPrompt] = useState<Prompt>(null)
  const [rig, setRig] = useState<{ view: RigView; catalog: CatalogEntry[] } | null>(null)

  useEffect(() => {
    loadLocale().finally(() => setReady(true))
  }, [])

  useNuiEvent((msg) => {
    switch (msg.action) {
      case 'cast':
        setView('casting'); setData(msg); break
      case 'waiting':
        setView('waiting'); setData(msg); break
      case 'reel':
        setHolding(false); setView('reeling'); setData(msg); break
      case 'reelInput':
        setHolding(!!msg.holding); break
      case 'caught':
        setView('caught'); setData(msg); break
      case 'prompt':
        setPrompt({ titleKey: msg.titleKey, subtitleKey: msg.subtitleKey }); break
      case 'promptHide':
        setPrompt(null); break
      case 'rigOpen':
        setRig({ view: msg.view, catalog: msg.catalog }); break
      case 'rigClose':
        setRig(null); break
      case 'hide':
        setView('hidden'); setData({}); setPrompt(null); setRig(null); break
      case 'admin':
        setAdmin(msg.config); break
    }
  })

  if (!ready) return null
  if (admin) return <AdminPanel config={admin} onClose={() => setAdmin(null)} />

  return (
    <>
      {view !== 'hidden' && (
        <div className="hud-root">
          {view === 'casting' && <CastBar power={data.power ?? 0} state={data.state} />}
          {view === 'waiting' && (
            <div className="hud-stack">
              <FishingInfoCard rod={data.rod} bait={data.bait} distance={data.distance} />
              <WaitingHud phase={data.phase ?? 'waiting'} />
            </div>
          )}
          {view === 'reeling' && (
          <TensionMinigame
              key={data.startedAt ?? 'reel'}
              behavior={data.behavior}
              tensionDiff={data.tensionDiff ?? 1}
              fishEnergy={data.fishEnergy ?? 100}
              greenZone={data.greenZone ?? 0}
              snapFactor={data.snapFactor ?? 1}
              drainRate={data.drainRate ?? 1}
              baseDrain={data.baseDrain ?? 12}
              reelTimeout={data.reelTimeout ?? 28000}
              fishWeight={data.fishWeight ?? 5}
              holding={holding}
            />
          )}
          {view === 'caught' && (
            <CatchCard label={data.label} weight={data.weight} quality={data.quality} />
          )}
        </div>
      )}
      {prompt && <PromptHud titleKey={prompt.titleKey} subtitleKey={prompt.subtitleKey} />}
      {rig && <RigMenu view={rig.view} catalog={rig.catalog} />}
    </>
  )
}
