import { t } from '../i18n'

export default function CastBar(props: { power: number; state?: string }) {
  const pct = Math.round(props.power * 100)
  return (
    <div className="panel cast-panel">
      <div className="panel-title">{t('ui_cast_title')}</div>
      <div className="bar-track">
        <div className="bar-fill cast-fill" style={{ width: `${pct}%` }} />
        {[25, 50, 75].map((x) => (
          <div key={x} className="bar-tick" style={{ left: `${x}%` }} />
        ))}
      </div>
      <div className="bar-caption">{pct}%</div>
    </div>
  )
}
