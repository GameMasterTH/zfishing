import { t } from '../i18n'

export default function CastBar(props: { power: number; state?: string }) {
  const pct = Math.round(props.power * 100)
  // client/casting.lua ส่ง state = 'start' | 'charge' | 'release'
  const charging = props.state === 'start' || props.state === 'charge'
  const released = props.state === 'release'
  const nearMax = charging && pct > 90

  const panelClass = [
    'hud-panel',
    'cast-panel',
    charging ? 'hud-panel--warn' : '',
    released ? 'cast-panel--released' : '',
  ]
    .filter(Boolean)
    .join(' ')

  const fillClass = [
    'bar-fill',
    'cast-fill',
    charging ? 'cast-fill--charging' : '',
    nearMax ? 'cast-fill--near-max' : '',
  ]
    .filter(Boolean)
    .join(' ')

  return (
    <div className={panelClass}>
      <div className="panel-title">{t('ui_cast_title')}</div>
      <div className="bar-track">
        <div className={fillClass} style={{ width: `${pct}%` }} />
        {[25, 50, 75].map((x) => (
          <div key={x} className="bar-tick" style={{ left: `${x}%` }} />
        ))}
      </div>
      <div className="bar-caption">{pct}%</div>
    </div>
  )
}
