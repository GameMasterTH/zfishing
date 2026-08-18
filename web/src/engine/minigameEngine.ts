export type EngineConfig = {
  behavior: 'steady_light' | 'steady_heavy' | 'run_stop' | 'erratic'
  tensionDiff: number
  fishEnergy: number
  greenZone: number
  snapFactor: number
  drainRate: number
  fishWeight: number
  baseDrain: number   // authoritative, from Config.Minigame.baseDrain via the bite payload
  reelTimeout: number // authoritative, from Config.Timings.reelTimeout via the bite payload
}

export type EngineState = {
  tension: number
  energy: number
  greenLo: number
  greenHi: number
  overTension: boolean
  isFinished: boolean
  finishReason?: 'success' | 'snap' | 'timeout' | 'escape'
  shouldStreamEnergy: boolean
  energyPct: number
}

function pullFor(behavior: EngineConfig['behavior'], t: number, seedRef: { phase: number; until: number; value: number }): number {
  switch (behavior) {
    case 'steady_light':
      return 12
    case 'steady_heavy':
      return 22
    case 'run_stop': {
      const cycle = t % 5000
      return cycle < 3000 ? 30 : 5
    }
    case 'erratic': {
      if (t >= seedRef.until) {
        seedRef.value = 5 + Math.random() * 30
        seedRef.until = t + 700 + Math.random() * 800
      }
      return seedRef.value
    }
    default:
      return 15
  }
}

function centerTargetFor(
  behavior: EngineConfig['behavior'], elapsed: number,
  seedRef: { until: number; center: number },
  amp: number, spd: number
): number {
  switch (behavior) {
    case 'steady_light':
    case 'steady_heavy':
      return 55 + Math.sin(elapsed / spd) * amp
    case 'run_stop': {
      const cycle = elapsed % 5000
      return cycle < 3000 ? 55 + amp : 55 - amp
    }
    case 'erratic': {
      if (elapsed >= seedRef.until) {
        seedRef.center = 55 + (Math.random() - 0.5) * 2 * amp
        seedRef.until = elapsed + spd
      }
      return seedRef.center
    }
    default:
      return 55
  }
}

export class MinigameEngine {
  private config: EngineConfig
  private tensionV = 30
  private energyV: number
  private snapMs = 0
  private snapBudget: number
  private erratic = { phase: 0, until: 0, value: 15 }
  private erraticCenter = { until: 0, center: 55 }
  private damaged = false
  private lastSentAt = 0
  private lastSentPct = 1
  private smoothCenter = 55

  private wf: number
  private amp: number
  private spd: number
  private lerpRate: number
  private greenHalf: number
  private isFinished = false
  private finishReason?: 'success' | 'snap' | 'timeout' | 'escape'

  constructor(config: EngineConfig) {
    this.config = config
    this.energyV = config.fishEnergy
    this.snapBudget = 900 * config.snapFactor
    this.greenHalf = 14 + config.greenZone * 80

    this.wf = Math.max(0.3, Math.min(2.5, (config.fishWeight || 5) / 50))
    switch (config.behavior) {
      case 'steady_light':  this.amp = 10 + 5 * this.wf;  this.spd = 1400 / this.wf; this.lerpRate = 3.0; break
      case 'steady_heavy':  this.amp = 15 + 12 * this.wf; this.spd = 900 / this.wf;  this.lerpRate = 2.5; break
      case 'run_stop':      this.amp = 15 + 10 * this.wf; this.spd = 0;           this.lerpRate = 2.0; break
      case 'erratic':       this.amp = 20 + 8 * this.wf;  this.spd = 900 / this.wf;  this.lerpRate = 5.0; break
      default:              this.amp = 13;                 this.spd = 1200;        this.lerpRate = 3.0
    }
  }

  public tick(dt: number, holding: boolean, elapsedMs: number): EngineState {
    if (this.isFinished) {
      const total = this.config.fishEnergy || 100
      const pct = Math.max(0, Math.min(100, (this.energyV / total) * 100))
      return {
        tension: this.tensionV,
        energy: Math.max(0, this.energyV),
        greenLo: 55 - this.greenHalf,
        greenHi: 55 + this.greenHalf,
        overTension: this.tensionV > 92,
        isFinished: true,
        finishReason: this.finishReason,
        shouldStreamEnergy: false,
        energyPct: pct
      }
    }

    const targetCenter = centerTargetFor(this.config.behavior, elapsedMs, this.erraticCenter, this.amp, this.spd)
    this.smoothCenter += (targetCenter - this.smoothCenter) * Math.min(1.0, dt * this.lerpRate)
    const center = Math.max(this.greenHalf + 4, Math.min(100 - this.greenHalf - 4, this.smoothCenter))
    const gLo = center - this.greenHalf
    const gHi = center + this.greenHalf

    const pull = pullFor(this.config.behavior, elapsedMs, this.erratic) * this.config.tensionDiff
    this.tensionV += ((holding ? 40 : -50) + pull) * dt
    this.tensionV = Math.max(0, Math.min(100, this.tensionV))

    if (this.tensionV >= gLo && this.tensionV <= gHi) {
      this.energyV -= this.config.baseDrain * (this.config.drainRate || 1) * dt
    } else if (this.tensionV < gLo) {
      this.energyV = Math.min(this.config.fishEnergy, this.energyV + 3 * dt)
    }

    if (this.tensionV > 92) this.snapMs += dt * 1000
    else this.snapMs = Math.max(0, this.snapMs - dt * 500)

    const pct = this.energyV / this.config.fishEnergy
    if (pct < 0.98) this.damaged = true

    let shouldStream = false
    if (elapsedMs - this.lastSentAt > 150 && Math.abs(pct - this.lastSentPct) >= 0.01) {
      this.lastSentAt = elapsedMs
      this.lastSentPct = pct
      shouldStream = true
    }

    if (this.damaged && this.energyV >= this.config.fishEnergy) {
      this.isFinished = true
      this.finishReason = 'escape'
    } else if (this.energyV <= 0) {
      this.isFinished = true
      this.finishReason = 'success'
    } else if (this.snapMs >= this.snapBudget) {
      this.isFinished = true
      this.finishReason = 'snap'
    } else if (elapsedMs >= this.config.reelTimeout) {
      this.isFinished = true
      this.finishReason = 'timeout'
    }

    const totalEnergy = this.config.fishEnergy || 100
    const energyPct = Math.max(0, Math.min(100, (this.energyV / totalEnergy) * 100))

    return {
      tension: this.tensionV,
      energy: Math.max(0, this.energyV),
      greenLo: gLo,
      greenHi: gHi,
      overTension: this.tensionV > 92,
      isFinished: this.isFinished,
      finishReason: this.finishReason,
      shouldStreamEnergy: shouldStream,
      energyPct: energyPct
    }
  }
}
