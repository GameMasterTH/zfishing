import { t } from '../i18n'
import { renderWithKeycaps } from './Keycap'

export default function WaitingHud(props: { phase: 'waiting' | 'bite' }) {
  if (props.phase === 'bite') {
    return (
      <div className="hud-panel hud-panel--warn bite-panel">
        <div className="bite-text">{t('ui_bite')}</div>
        <div className="bite-prompt">{renderWithKeycaps(t('ui_bite_prompt'), 'urgent')}</div>
      </div>
    )
  }
  return (
    <div className="hud-panel waiting-panel">
      <span className="waiting-ripple" />
      <span>{t('ui_waiting')}</span>
    </div>
  )
}
