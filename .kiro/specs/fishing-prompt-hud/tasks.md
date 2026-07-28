# Implementation Plan: Fishing Prompt HUD

## Overview

แผนงานนี้แปลง prompt ตอนตกปลา 2 จุด (Equip_Standby_Phase และ Cancel_Phase) จาก `lib.showTextUI` ให้เป็น Prompt_HUD กลางจอด้านล่างแบบ title + subtitle โดยยึดหลัก **presentation-only** — แตะเฉพาะ `config/main.lua`, `locales/*.json`, `web/src/` (NUI) และจุดแสดง/ซ่อน prompt ใน `client/main.lua` เท่านั้น ไม่แตะ server logic, lifecycle, server callback/event และ Sell_Prompt (Requirement 5)

ลำดับงานเริ่มจากไฟล์อิสระ (config, locale, test tooling) → pure logic + property test ฝั่ง NUI → component + CSS → การต่อ App state → การต่อ Lua client → build และตรวจ regression ทุก task ต่อยอดจาก task ก่อนหน้าและจบด้วยการ wire เข้าด้วยกันโดยไม่มีโค้ดค้างที่ไม่ได้เชื่อมต่อ

ภาษา implementation: **Lua** (client/config) และ **TypeScript + React 18** (NUI) ตามที่ระบุใน design โดยตรง — ไม่มี pseudocode จึงไม่ต้องเลือกภาษาเพิ่ม

## Tasks

- [x] 1. เพิ่ม config, locale key และตั้งค่า test tooling ฝั่ง NUI
  - [x] 1.1 เพิ่ม `Config.PromptHud` ใน `config/main.lua`
    - เพิ่มบรรทัด `Config.PromptHud = true` พร้อมคอมเมนต์อธิบาย (true = HUD กลางจอล่าง, false = ox_lib TextUI เดิม) วางใกล้ `Config.Locale`
    - _Requirements: 3.1, 3.6_

  - [x] 1.2 เพิ่ม locale key `equip_title` และ `cancel_title` ใน `locales/en.json` และ `locales/th.json`
    - en: `equip_title` = "Fishing", `cancel_title` = "Reeling"
    - th: `equip_title` = "การตกปลา", `cancel_title` = "กำลังตกปลา"
    - คง key `equip_hint` / `cancel_hint` เดิมไว้ (ใช้เป็น Subtitle_Text)
    - _Requirements: 4.2_

  - [x] 1.3 ตั้งค่า test tooling ฝั่ง NUI (`web/`)
    - เพิ่ม `vitest` และ `fast-check` ใน devDependencies ของ `web/package.json` และเพิ่ม script `"test": "vitest --run"`
    - สร้าง `web/vitest.config.ts` (environment `jsdom` สำหรับ component test, ตั้ง `globals: true`) และเพิ่ม `jsdom` + `@testing-library/react` ใน devDependencies
    - ติดตั้ง dependency ด้วย `npm install` ใน `web/`
    - _Requirements: 2.7, 4.4, 1.7, 1.8_

- [x] 2. Implement pure logic ของ Prompt_HUD และ property-based tests
  - [x] 2.1 สร้าง `web/src/promptText.ts`
    - export `MAX_LINE = 120`, ตาราง `FALLBACK` ต่อ key (`equip_title`/`equip_hint`/`cancel_title`/`cancel_hint`)
    - `resolvePromptText(key)`: คืนค่าจาก dict ผ่าน `tOr(key, fallback)` เมื่อ trim แล้วไม่ว่าง มิฉะนั้นคืน fallback — ไม่คืน raw key และไม่คืนสตริงว่าง
    - `prepareLines(title, subtitle)` + `prepareLine(text)`: แปลง null/ว่าง/ช่องว่างล้วนเป็น `null` และ truncate ให้ยาวไม่เกิน `MAX_LINE`
    - _Requirements: 1.7, 1.8, 2.7, 4.4_

  - [x] 2.2 เขียน property test สำหรับ `prepareLines` ใน `web/src/__tests__/promptText.test.ts`
    - **Property 1: การเตรียมบรรทัด prompt กรองบรรทัดว่างและตัดความยาว**
    - generate title/subtitle จาก `fc.oneof(fc.string(), constant(''), whitespace strings, constant(null), long strings > 120)` แล้ว assert: ไม่มีบรรทัดว่าง/ช่องว่างล้วน/null-source หลงเหลือ และทุกบรรทัดที่ไม่ใช่ null ยาว ≤ 120
    - `fc.assert(fc.property(...), { numRuns: 100 })` และ tag `// Feature: fishing-prompt-hud, Property 1`
    - **Validates: Requirements 1.7, 1.8**

  - [x] 2.3 เขียน property test สำหรับ `resolvePromptText` (เพิ่มในไฟล์ `web/src/__tests__/promptText.test.ts`)
    - **Property 2: การ resolve ข้อความ prompt มี fallback เสมอ**
    - generate dict สุ่ม (`fc.dictionary`) + key จาก prompt keys แล้ว assert: คืน dict value เมื่อไม่ว่าง มิฉะนั้นคืน fallback, ไม่เท่ากับ raw key, ไม่เป็นสตริงว่าง
    - `fc.assert(fc.property(...), { numRuns: 100 })` และ tag `// Feature: fishing-prompt-hud, Property 2`
    - **Validates: Requirements 2.7, 4.4**

- [x] 3. Checkpoint - รัน property test ให้ผ่าน
  - Ensure all tests pass, ask the user if questions arise.

- [x] 4. Implement Prompt_HUD component และ CSS
  - [x] 4.1 สร้าง `web/src/components/PromptHud.tsx`
    - รับ props `{ titleKey, subtitleKey }`, เรียก `resolvePromptText` แล้ว `prepareLines`
    - render `.prompt-title` ก่อน `.prompt-subtitle` (title อยู่บน subtitle), render เฉพาะบรรทัดที่ไม่ใช่ null, คืน `null` เมื่อว่างทั้งคู่
    - _Requirements: 1.2, 1.3, 1.7, 2.7, 4.4_

  - [x] 4.2 เพิ่ม CSS ของ Prompt_HUD ใน `web/src/style.css`
    - `.prompt-hud`: `position:fixed`, `left:50%` + `translateX(-50%)`, `bottom:7vh` (อยู่ในช่วง 5–10%), `max-width:40vw`, `pointer-events:none`, `flex-direction:column`, `align-items:center`
    - `.prompt-title` `font-size:3vh`/`font-weight:700`, `.prompt-subtitle` `font-size:1.8vh` (อัตราส่วน ≈ 1.66x ≥ 1.5x)
    - _Requirements: 1.1, 1.2, 1.3, 1.5, 2.5_

  - [x] 4.3 เขียน unit test สำหรับ `PromptHud` ใน `web/src/components/__tests__/PromptHud.test.tsx`
    - ยืนยัน DOM order: `.prompt-title` มาก่อน `.prompt-subtitle` (R1.3)
    - ยืนยันเมื่อ title/subtitle ว่างทั้งคู่ component คืน null (R1.7)
    - _Requirements: 1.3, 1.7_

- [x] 5. ต่อ Prompt_HUD เข้ากับ App state machine
  - [x] 5.1 แก้ `web/src/App.tsx` เพิ่ม prompt state และ render `PromptHud`
    - เพิ่ม `prompt` state (`{ titleKey, subtitleKey } | null`)
    - เพิ่ม case ใน `useNuiEvent`: `prompt` → set state, `promptHide` → null, และแก้ case `hide` เดิมให้เคลียร์ `prompt` ด้วย
    - ปรับ render ให้ไม่ return null ทันทีเมื่อ `view === 'hidden'` — render `PromptHud` แยกจาก `hud-root` เพื่อให้ coexist กับ view `waiting` และแสดงได้ตอน view เป็น `hidden`
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.6, 4.1_

  - [x] 5.2 เขียน unit test สำหรับ prompt handling ใน `web/src/__tests__/App.test.tsx`
    - `view='hidden'` แต่ `prompt != null` → render `PromptHud` (R2.1), action `promptHide` → prompt=null (R2.2/R2.6), action `hide` → prompt=null (R2.4)
    - _Requirements: 2.1, 2.2, 2.4, 2.6_

- [x] 6. ต่อ Prompt_HUD เข้ากับ Fishing_Client (Lua) โดยไม่แตะ lifecycle/callback
  - [x] 6.1 เพิ่ม helper ใน `client/main.lua`
    - `normalizePromptHud(raw)`: boolean คงค่า, nil/ชนิดอื่น → true; เก็บผลเป็น `PROMPT_HUD` ครั้งเดียวตอน resource start
    - `showPrompt(titleKey, subtitleKey)`: true → `SendNUIMessage({action='prompt', titleKey, subtitleKey})`, false → `lib.showTextUI(locale(subtitleKey))`
    - `hidePrompt()`: true → `SendNUIMessage({action='promptHide'})`, false → `lib.hideTextUI()`
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6_

  - [x] 6.2 แทนที่จุดเรียก TextUI 2 จุดใน `client/main.lua`
    - `startFishing()`: `lib.showTextUI(locale('equip_hint'))` → `showPrompt('equip_title','equip_hint')`; จุดซ่อนหลังกด E/X ออกจาก standby → `hidePrompt()`; `lib.showTextUI(locale('cancel_hint'))` → `showPrompt('cancel_title','cancel_hint')`
    - `cleanup()`: คง `lib.hideTextUI()` ไว้ และให้ action `hide` ฝั่ง NUI เคลียร์ prompt (ครอบคลุม R2.4)
    - ห้ามแตะ: `lib.showTextUI(locale('sell'))` (Sell_Prompt), lifecycle 6 สถานะ, signature/payload ของ `zfishing:cast/cancel/sellAll/reportWeather`, การไม่ส่ง bait arg, ความถี่ `zfishing:reportWeather`, path error → `cleanup` เดิม
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.6, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6_

- [x] 7. Checkpoint - รัน test ทั้งหมดและตรวจ regression
  - Ensure all tests pass, ask the user if questions arise.

- [x] 8. Build NUI และตรวจสอบขั้นสุดท้าย
  - [x] 8.1 Build NUI และรัน test suite ใน `web/`
    - รัน `npm run build` (tsc + vite build) ให้ผ่านโดยไม่มี TS error และรัน `npm run test` (vitest --run) ให้ property test + unit test ผ่านทั้งหมด
    - ตรวจว่า `web/dist/` ถูกสร้างใหม่และ App โหลด PromptHud ได้ (ไม่มี import ค้าง)
    - _Requirements: 1.1, 1.2, 1.3, 4.1_

## Notes

- Tasks ที่มี `*` เป็น optional (unit/property test) สามารถข้ามเพื่อทำ MVP ได้เร็วขึ้น แต่แนะนำให้ทำเพื่อยืนยัน Property 1/2
- แต่ละ task อ้างอิง requirement/property เพื่อ traceability
- Property test ใช้ fast-check + Vitest รันขั้นต่ำ 100 iterations ต่อ property และ tag อ้าง Property number ตาม design
- Regression ของ Requirement 5 ทำผ่านข้อจำกัดใน task 6.2 (ไม่แตะ lifecycle/callback/Sell_Prompt) ร่วมกับ checkpoint การรัน test/build
- งานฝั่ง Lua ยังไม่มี test runner ตั้งไว้ จึงยืนยันด้วยข้อจำกัดเชิงโครงสร้างใน task และ build/test ฝั่ง NUI

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "1.2", "1.3", "2.1", "6.1"] },
    { "id": 1, "tasks": ["2.2", "4.1", "4.2", "6.2"] },
    { "id": 2, "tasks": ["2.3", "4.3", "5.1"] },
    { "id": 3, "tasks": ["5.2"] },
    { "id": 4, "tasks": ["8.1"] }
  ]
}
```
