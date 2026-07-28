import { t } from '../i18n'

export default function WaitingHud(props: { phase: 'waiting' | 'bite' }) {
  if (props.phase === 'bite') {
    return (
      <div className="panel bite-panel">
        <div className="bite-text">{t('ui_bite')}</div>
        <div className="bite-prompt">{t('ui_bite_prompt')}</div>
      </div>
    )
  }
  return (
    <div className="panel waiting-panel">
      <span className="waiting-dot" />
      <span>{t('ui_waiting')}</span>
    </div>
  )
}
