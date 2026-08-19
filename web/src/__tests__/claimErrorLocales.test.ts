import { describe, it, expect } from 'vitest'
import { readFileSync, existsSync } from 'node:fs'
import { join, resolve } from 'node:path'

// ────────────────────────────────────────────────────────────────────────────
// client/minigame.lua maps a failed zfishing:claim onto a locale key. A key that
// is not in locales/*.json renders as the raw key in-game, which is how an
// earlier pass shipped an unreachable error_settle_failed and had to delete it.
// This is the guard: every value in CLAIM_ERRORS, plus the fallback, must exist
// in BOTH locale files.
//
// Lives in web/ because the Lua harness (tests/luarun.mjs) mounts only .lua files
// into its VM and cannot read locales/*.json.
// ────────────────────────────────────────────────────────────────────────────

function findWeb(): string {
  const cwd = process.cwd()
  if (existsSync(join(cwd, 'src', 'style.css')) && existsSync(join(cwd, 'dist'))) return cwd
  if (existsSync(join(cwd, 'web', 'src', 'style.css'))) return join(cwd, 'web')
  return cwd
}
const REPO = resolve(findWeb(), '..')

const FALLBACK_KEY = 'error_claim_failed'

// keys are read inside the tests, not at collection time, so a regression shows
// up as a named failing assertion rather than a file that collects no tests
function claimErrorKeys(): string[] {
  const lua = readFileSync(join(REPO, 'client', 'minigame.lua'), 'utf8')
  const start = lua.indexOf('local CLAIM_ERRORS')
  expect(start, 'CLAIM_ERRORS table must exist in client/minigame.lua').toBeGreaterThan(-1)
  const body = lua.slice(start, lua.indexOf('}', start))
  const keys = [...body.matchAll(/=\s*'([a-z_]+)'/g)].map((m) => m[1])
  expect(keys.length, 'the mapping must not be empty').toBeGreaterThan(0)

  // the fallback is applied inline, not in the table
  expect(lua, 'the unmapped-reason fallback must stay').toContain(`or '${FALLBACK_KEY}'`)
  return [...keys, FALLBACK_KEY]
}

function locale(lang: string): Record<string, string> {
  return JSON.parse(readFileSync(join(REPO, 'locales', `${lang}.json`), 'utf8'))
}

describe('Claim failure locale coverage', () => {
  it.each(['en', 'th'])('every claim error key resolves in %s.json', (lang) => {
    const dict = locale(lang)
    for (const key of claimErrorKeys()) {
      expect(dict, `${key} is mapped by client/minigame.lua but missing from ${lang}.json`)
        .toHaveProperty([key])
      expect(String(dict[key]).trim().length, `${key} in ${lang}.json must not be blank`)
        .toBeGreaterThan(0)
    }
  })

  // client/main.lua's sellFish still builds its key dynamically ('error_' .. reason),
  // the pattern minigame.lua moved away from. Every reason server/rewards.lua can
  // answer with is pinned here so a new one cannot ship as a raw key in-game.
  it.each(['en', 'th'])('every sellAll reason resolves in %s.json', (lang) => {
    const dict = locale(lang)
    for (const reason of ['too_many_requests', 'sale_busy', 'payout_failed', 'sale_failed']) {
      const key = `error_${reason}`
      expect(dict, `${key} is a sellAll reason but is missing from ${lang}.json`)
        .toHaveProperty([key])
    }
  })

  it('a failed claim never falls back to the escape message', () => {
    const lua = readFileSync(join(REPO, 'client', 'minigame.lua'), 'utf8')
    const branch = lua.slice(lua.indexOf("elseif res and res.ok then"), lua.indexOf("RegisterNUICallback('keep'"))
    // the `else` arm handles ok == false: it must not reuse fish_escaped, which is
    // what a legitimate escape (ok = true, fish = nil) reports. Match `else` alone
    // on its own line so the preceding `elseif` is not what we slice from.
    const idx = branch.search(/\n\s*else\s*\n/)
    expect(idx, 'the reelResult handler must keep an else arm for ok == false').toBeGreaterThan(-1)
    const elseArm = branch.slice(idx)
    expect(elseArm).toContain('CLAIM_ERRORS')
    expect(elseArm).not.toContain('fish_escaped')
  })
})
