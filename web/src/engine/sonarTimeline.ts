// Mirrors server/encounter_sonar.lua's public pass timeline. This is render maths only:
// the server still judges strike arrival, grade, reward and outcome.

export type SonarPass = {
  duration: number
  hold: number
  k: number
  dir: 1 | -1
}

const clamp = (value: number, low: number, high: number) => Math.min(high, Math.max(low, value))

export function passProgress(pass: SonarPass, elapsed: number): number {
  const travel = Math.max(1, pass.duration - pass.hold)
  return clamp((elapsed - pass.hold) / travel, 0, 1)
}

export function weakAt(pass: SonarPass, elapsed: number): number {
  const u = passProgress(pass, elapsed)
  const c = u - 0.5
  const f = 0.5 + (1 - pass.k) * c + 4 * pass.k * c * c * c
  return pass.dir > 0 ? f : 1 - f
}
