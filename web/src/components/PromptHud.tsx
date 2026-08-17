import { resolvePromptText, prepareLines } from '../promptText'
import { renderWithKeycaps } from './Keycap'

type Props = { titleKey: string; subtitleKey: string }

export default function PromptHud({ titleKey, subtitleKey }: Props) {
  const title = resolvePromptText(titleKey)
  const subtitle = resolvePromptText(subtitleKey)
  const [titleLine, subtitleLine] = prepareLines(title, subtitle)

  if (!titleLine && !subtitleLine) return null

  return (
    <div className="prompt-hud">
      {titleLine && <div className="prompt-title">{titleLine}</div>}
      {subtitleLine && (
        <div className="prompt-subtitle">{renderWithKeycaps(subtitleLine, 'breathe')}</div>
      )}
    </div>
  )
}
