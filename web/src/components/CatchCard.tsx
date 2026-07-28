import { fetchNui } from '../hooks/useNui'
import { t } from '../i18n'

export default function CatchCard(props: { label?: string; weight?: number; quality?: number }) {
  const stars = '★'.repeat(props.quality ?? 0) + '☆'.repeat(5 - (props.quality ?? 0))
  return (
    <div className="panel catch-card">
      <div className="panel-title">{t('ui_catch_title')}</div>
      <div className="catch-name">{props.label ?? '-'}</div>
      <div className="catch-weight">{(props.weight ?? 0).toFixed(2)} kg</div>
      <div className="catch-stars">{stars}</div>
      <div className="catch-actions">
        <button className="btn btn-primary" onClick={() => fetchNui('keep')}>{t('ui_keep')}</button>
        <button className="btn" onClick={() => fetchNui('release')}>{t('ui_release')}</button>
      </div>
    </div>
  )
}
