import { t } from '../i18n'

export default function FishingInfoCard(props: { rod?: string; bait?: string; distance?: number }) {
  return (
    <div className="hud-panel info-card">
      <div className="panel-title">{t('ui_info_title')}</div>
      <div className="info-row" style={{ animationDelay: '0ms' }}>
        <span>{t('ui_info_rod')}</span><b>{props.rod ?? '-'}</b>
      </div>
      <div className="info-row" style={{ animationDelay: '60ms' }}>
        <span>{t('ui_info_bait')}</span><b>{props.bait ?? '-'}</b>
      </div>
      {props.distance != null && (
        <div className="info-row" style={{ animationDelay: '120ms' }}>
          <span>{t('ui_info_distance')}</span><b>{props.distance.toFixed(1)} m</b>
        </div>
      )}
    </div>
  )
}
