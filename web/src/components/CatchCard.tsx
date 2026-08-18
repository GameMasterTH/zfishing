import { fetchNui } from '../hooks/useNui'
import { t } from '../i18n'

export default function CatchCard(props: { label?: string; weight?: number; quality?: number }) {
  const quality = props.quality ?? 0
  // แตกเป็น element ละดวงเพื่อให้หน่วงเวลาเติมทีละดาวได้
  const stars = Array.from({ length: 5 }, (_, i) => i < quality)

  return (
    <div className="hud-panel catch-card">
      <div className="panel-title">{t('ui_catch_title')}</div>
      <div className="catch-name">{props.label ?? '-'}</div>
      <div className="catch-weight">{(props.weight ?? 0).toFixed(2)} kg</div>
      <div className="catch-stars">
        {stars.map((filled, i) => (
          <span
            key={i}
            className={`catch-star${filled ? ' catch-star--filled' : ''}`}
            style={{ animationDelay: `${260 + i * 90}ms` }}
          >
            {filled ? '★' : '☆'}
          </span>
        ))}
      </div>
      <div className="catch-actions">
        <button className="hud-btn hud-btn--primary" onClick={() => fetchNui('keep')}>
          {t('ui_continue')}
        </button>
      </div>
    </div>
  )
}
