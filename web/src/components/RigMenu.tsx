import { useEffect, useState } from 'react'
import { fetchNui } from '../hooks/useNui'
import { loadLocale } from '../i18n'
import { rigText } from '../rigText'
import { groupRigCategories } from '../rigRows'
import type { CatalogEntry, CategoryGroup, ItemGroup, PartType, RigView } from '../rigRows'

type Props = { view: RigView; catalog: CatalogEntry[] }

export default function RigMenu({ view, catalog }: Props) {
  const [ready, setReady] = useState(false)
  const [localeError, setLocaleError] = useState(false)
  const [activeCategory, setActiveCategory] = useState<PartType | null>(null)
  const [lockedCategory, setLockedCategory] = useState<PartType | null>(null)

  useEffect(() => {
    let alive = true
    loadLocale()
      .catch(() => {
        if (alive) setLocaleError(true)
      })
      .finally(() => {
        if (alive) setReady(true)
      })
    return () => {
      alive = false
    }
  }, [])

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') fetchNui('rigClose')
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [])

  if (!ready) return null

  const categories = groupRigCategories(view, catalog)
  const currentCategory = categories.find((c) => c.partType === (lockedCategory || activeCategory))

  const handleCategoryHover = (partType: PartType) => {
    if (!lockedCategory) {
      setActiveCategory(partType)
    }
  }

  const handleCategoryClick = (partType: PartType) => {
    if (lockedCategory === partType) {
      setLockedCategory(null)
      setActiveCategory(null)
    } else {
      setLockedCategory(partType)
      setActiveCategory(partType)
    }
  }

  const handleContainerMouseLeave = () => {
    if (!lockedCategory) {
      setActiveCategory(null)
    }
  }

  return (
    <div className="rig-menu__overlay" onClick={() => fetchNui('rigClose')}>
      <div
        className="rig-menu__container"
        onClick={(e) => e.stopPropagation()}
        onMouseLeave={handleContainerMouseLeave}
      >
        {/* Level 2: Left Flyout Sub-menu */}
        {currentCategory && (
          <FlyoutPanel
            category={currentCategory}
            onClose={() => {
              setLockedCategory(null)
              setActiveCategory(null)
            }}
          />
        )}

        {/* Level 1: Main Category Cards on Right */}
        <div className="rig-menu">
          <div className="rig-menu__header">
            <div className="rig-menu__title">{rigText('rig_title')}</div>
            <div className="rig-menu__hint">{rigText('rig_close_hint')}</div>
            {localeError && <div className="rig-menu__locale-error">{rigText('rig_locale_error')}</div>}
          </div>

          <div className="rig-menu__categories">
            {categories.map((cat) => (
              <CategoryCard
                key={cat.partType}
                category={cat}
                isActive={currentCategory?.partType === cat.partType}
                isLocked={lockedCategory === cat.partType}
                onHover={() => handleCategoryHover(cat.partType)}
                onClick={() => handleCategoryClick(cat.partType)}
              />
            ))}
          </div>
        </div>
      </div>
    </div>
  )
}

function CategoryCard({
  category,
  isActive,
  isLocked,
  onHover,
  onClick,
}: {
  category: CategoryGroup
  isActive: boolean
  isLocked: boolean
  onHover: () => void
  onClick: () => void
}) {
  const statusText = category.fittedLabel
    ? `${category.fittedLabel} (${Math.round(((category.fittedDur || 0) / (category.fittedMax || 1)) * 100)}%)`
    : rigText('rig_empty')

  return (
    <div
      className={`rig-category-card ${isActive ? 'rig-category-card--active' : ''} ${
        isLocked ? 'rig-category-card--locked' : ''
      }`}
      onMouseEnter={onHover}
      onClick={onClick}
    >
      <div className="rig-category-card__header">
        <span className="rig-category-card__title">{rigText(category.titleKey as any) || category.partType}</span>
      </div>
      <div className="rig-category-card__status">{statusText}</div>
    </div>
  )
}

function FlyoutPanel({ category, onClose }: { category: CategoryGroup; onClose: () => void }) {
  return (
    <div className="rig-flyout-panel">
      <div className="rig-flyout-panel__header">
        <span className="rig-flyout-panel__title">
          {rigText(category.titleKey as any) || category.partType}
        </span>
        <button className="rig-flyout-panel__close" onClick={onClose}>
          ✕
        </button>
      </div>

      <div className="rig-flyout-panel__list">
        {category.items.map((itemGroup) => (
          <ItemAccordionGroup key={itemGroup.name} itemGroup={itemGroup} />
        ))}
      </div>
    </div>
  )
}

function ItemAccordionGroup({ itemGroup }: { itemGroup: ItemGroup }) {
  const [expanded, setExpanded] = useState(false)
  const [iconFailed, setIconFailed] = useState(false)

  const handleAttach = (slot?: number) => {
    if (itemGroup.instances.length > 0) {
      const targetSlot = slot ?? itemGroup.instances[0].slot
      fetchNui('rigAction', {
        kind: 'attach',
        partType: itemGroup.partType,
        itemName: itemGroup.name,
        slot: targetSlot,
      })
    }
  }

  const handleDetach = () => {
    fetchNui('rigAction', { kind: 'detach', partType: itemGroup.partType })
  }

  const canExpand = itemGroup.totalOwned > 1

  return (
    <div className="rig-item-group">
      <div
        className={`rig-item-row ${itemGroup.totalOwned === 0 && !itemGroup.fitted ? 'rig-item-row--dimmed' : ''}`}
        onClick={() => {
          if (canExpand) setExpanded(!expanded)
          else if (itemGroup.fitted) handleDetach()
          else if (itemGroup.instances.length > 0) handleAttach()
        }}
      >
        <div className="rig-item-row__icon">
          {!iconFailed && (
            <img
              src={`nui://zfishing/assets/items/${itemGroup.name}.png`}
              alt=""
              onError={() => setIconFailed(true)}
            />
          )}
        </div>

        <div className="rig-item-row__info">
          <span className="rig-item-row__label">{itemGroup.label}</span>
          <span className="rig-item-row__owned">({itemGroup.totalOwned}x)</span>
        </div>

        <div className="rig-item-row__actions" onClick={(e) => e.stopPropagation()}>
          {canExpand ? (
            <span
              className="rig-item-row__arrow"
              onClick={() => setExpanded(!expanded)}
            >
              {expanded ? '▲' : '▼'}
            </span>
          ) : itemGroup.fitted ? (
            <button
              className="rig-btn rig-btn--detach"
              onClick={() => handleDetach()}
            >
              {rigText('rig_detach' as any) || 'ถอดออก'}
            </button>
          ) : itemGroup.instances.length > 0 ? (
            <button
              className="rig-btn rig-btn--attach"
              onClick={() => handleAttach()}
            >
              {rigText('rig_attach' as any) || 'ติดตั้ง'}
            </button>
          ) : (
            <span className="rig-item-row__empty">-</span>
          )}
        </div>
      </div>

      {/* Level 3 Accordion for multiple instances */}
      {expanded && canExpand && (
        <div className="rig-instance-list">
          {itemGroup.fitted && itemGroup.fittedInstance && (
            <div
              className="rig-instance-row rig-instance-row--fitted"
              onClick={handleDetach}
            >
              <span className="rig-instance-row__dur">
                Durability: {Math.round((itemGroup.fittedInstance.dur / itemGroup.fittedInstance.max) * 100)}%
              </span>
              <button className="rig-btn rig-btn--detach-sm">
                {rigText('rig_detach' as any) || 'ถอดออก'}
              </button>
            </div>
          )}

          {itemGroup.instances.map((inst, idx) => {
            const pct = Math.round((inst.dur / inst.max) * 100)
            return (
              <div
                key={`${inst.slot}-${idx}`}
                className="rig-instance-row"
                onClick={() => handleAttach(inst.slot)}
              >
                <span className="rig-instance-row__dur">
                  Durability: {pct}%
                </span>
                <button className="rig-btn rig-btn--attach-sm">
                  {rigText('rig_attach' as any) || 'ติดตั้ง'}
                </button>
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}

