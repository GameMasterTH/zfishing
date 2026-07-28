# Implementation Plan: Fishing Rig Menu (NUI)

## Overview

แผนงานนี้แทนที่เมนูจัดการเบ็ด (rig) จาก ox_lib context menu ให้เป็น NUI menu ใหม่ที่เปิดด้วยปุ่ม G ในช่วง Equip_Standby_Phase โดยยึดหลัก **presentation-only** — ไม่แตะ server callback logic ของ rig (`zfishing:rig:get/attach/detach` คง signature/return เดิม, Requirement 7) การเปลี่ยนแปลงจำกัดอยู่ที่ฝั่งการนำเสนอ (`web/src/`, `client/rig.lua`), flag ช่วย standby ใน `client/main.lua`, การลบคำสั่ง `/fishrig` ใน `server/rig.lua`, locale keys และ asset entry ใน `fxmanifest.lua`

ลำดับงานเริ่มจากไฟล์อิสระ (locale, fxmanifest) → pure logic + property test ฝั่ง NUI (`rigRows.ts`, `rigText.ts`) → component + CSS (`RigMenu.tsx`) → ต่อ App state → rewrite `client/rig.lua` + flag ใน `main.lua` → ลบ `/fishrig` → build และตรวจ regression ทุก task ต่อยอดจาก task ก่อนหน้าและจบด้วยการ wire เข้าด้วยกันโดยไม่มีโค้ดค้างที่ไม่ได้เชื่อมต่อ

ภาษา implementation: **TypeScript + React 18** (NUI) และ **Lua** (client/server) ตามที่ระบุใน design โดยตรง — ไม่มี pseudocode จึงไม่ต้องเลือกภาษาเพิ่ม test tooling (Vitest + fast-check + Testing Library) ตั้งค่าไว้แล้วจากสเปค `fishing-prompt-hud`

## Tasks

- [x] 1. เพิ่ม locale key และ asset entry (ไฟล์อิสระ)
  - [x] 1.1 เพิ่ม locale key ของ Rig_Menu ใน `locales/en.json` และ `locales/th.json`
    - en: `rig_close_hint` = "Press ESC to close", `rig_empty` = "No rod parts to manage", `rig_locale_error` = "Language failed to load"
    - th: `rig_close_hint` = "กด ESC เพื่อปิด", `rig_empty` = "ไม่มีชิ้นส่วนเบ็ดให้จัดการ", `rig_locale_error` = "โหลดภาษาไม่สำเร็จ"
    - คง key เดิมที่มีอยู่แล้ว (`rig_title`, `rig_no_rod`, `rig_inv_full`, `rig_error`, `attached`, `detached`) ไว้ไม่แตะ
    - _Requirements: 6.2_

  - [x] 1.2 เพิ่ม asset entry สำหรับ Item_Icon ใน `fxmanifest.lua`
    - เพิ่ม `'assets/items/*.png'` ในบล็อก `files{}` เพื่อให้ NUI โหลด icon ผ่าน `nui://zfishing/assets/items/<name>.png` ได้
    - _Requirements: 2.4_

- [x] 2. Implement pure logic modules และ property-based tests
  - [x] 2.1 สร้าง `web/src/rigRows.ts`
    - export types: `PartType`, `CatalogEntry`, `RigView`, `RigRow`, `RigAction`, `PART_ORDER = ['reel','line','hook','float']`
    - `buildRigRows(view, catalog)`: หนึ่งแถวต่อหนึ่ง item ใน catalog; เรียงตาม `PART_ORDER` แล้วภายใน partType เรียงชื่อ item ascending; `owned` = จำนวน entry ใน `view.carried[partType]` ที่ชื่อตรงกัน; `fitted` = `view.parts[partType]?.name === row.name`
    - `formatOwned(n)`: clamp เป็นจำนวนเต็มช่วง 0..9999 แล้วคืน `` `${n}x` ``
    - `isDimmed(owned)`: คืน true เมื่อ `owned === 0`
    - `resolveRigAction(row)`: `detach` เมื่อ fitted; `attach` เมื่อไม่ fitted และ `owned > 0`; `blocked` เมื่อไม่ fitted และ `owned === 0`
    - `resolveNotifyKey(kind, result)`: `attached`/`detached` เมื่อ `ok=true`; `rig_inv_full` เมื่อ `err==='inv_full'`; `rig_error` สำหรับ err อื่นและ timeout
    - _Requirements: 2.2, 2.3, 4.1, 4.2, 4.3, 4.5, 4.6, 4.7, 4.8_

  - [x] 2.2 เขียน property test สำหรับ `buildRigRows` ใน `web/src/__tests__/rigRows.test.ts`
    - **Property 1: การประกอบแถวถูกต้องและ deterministic**
    - generate `view`/`catalog` ที่มี item ซ้ำ/ขาด/ว่าง; assert จำนวนแถว = จำนวน catalog entry, ลำดับตาม `PART_ORDER` + ชื่อ ascending คงที่, `owned >= 0` และตรงกับจำนวนใน `carried`, `fitted` ตรงกับ `parts`
    - `fc.assert(fc.property(...), { numRuns: 100 })`, tag `// Feature: fishing-rig-menu-nui, Property 1`
    - **Validates: Requirements 2.2**

  - [x] 2.3 เขียน property test สำหรับ `formatOwned` (เพิ่มใน `web/src/__tests__/rigRows.test.ts`)
    - **Property 2: การจัดรูปแบบจำนวนที่ถือ**
    - generate `n` จาก `fc.oneof(fc.integer(), fc.double(), ค่าลบ, ค่า > 9999)`; assert ผลตรงรูปแบบ `Nx` โดย `N` เป็นจำนวนเต็ม clamp 0..9999 (ลบ→0, >9999→9999)
    - `fc.assert(..., { numRuns: 100 })`, tag `// Feature: fishing-rig-menu-nui, Property 2`
    - **Validates: Requirements 2.3**

  - [x] 2.4 เขียน property test สำหรับ `isDimmed` (เพิ่มใน `web/src/__tests__/rigRows.test.ts`)
    - **Property 3: การจางของแถวสัมพันธ์กับจำนวนที่ถือ**
    - generate `owned` ใด ๆ; assert `isDimmed(owned)` เป็น true ก็ต่อเมื่อ `owned === 0`, และ opacity ที่ derive ต้อง ≤ 0.5 เมื่อ dimmed และ = 1.0 เมื่อไม่ dimmed
    - `fc.assert(..., { numRuns: 100 })`, tag `// Feature: fishing-rig-menu-nui, Property 3`
    - **Validates: Requirements 2.5, 2.6**

  - [x] 2.5 เขียน property test สำหรับ `resolveRigAction` (เพิ่มใน `web/src/__tests__/rigRows.test.ts`)
    - **Property 4: การตัดสิน action จากแถว**
    - generate `RigRow` ใด ๆ; assert ได้ `detach` เมื่อ fitted, `attach` เมื่อไม่ fitted และ `owned > 0`, `blocked` เมื่อไม่ fitted และ `owned === 0`
    - `fc.assert(..., { numRuns: 100 })`, tag `// Feature: fishing-rig-menu-nui, Property 4`
    - **Validates: Requirements 4.1, 4.2, 4.3**

  - [x] 2.6 เขียน property test สำหรับ `resolveNotifyKey` (เพิ่มใน `web/src/__tests__/rigRows.test.ts`)
    - **Property 5: การ map ผลลัพธ์ callback เป็น locale key**
    - generate ผลลัพธ์ callback ทุกกิ่ง (`ok=true`, `err='inv_full'`, err อื่น, timeout) × kind (attach/detach); assert key: `attached`/`detached` เมื่อ ok, `rig_inv_full` เมื่อ inv_full, `rig_error` สำหรับ err อื่นและ timeout
    - `fc.assert(..., { numRuns: 100 })`, tag `// Feature: fishing-rig-menu-nui, Property 5`
    - **Validates: Requirements 4.5, 4.6, 4.7, 4.8**

  - [x] 2.7 สร้าง `web/src/rigText.ts`
    - `rigText(key)`: คืนค่าจาก locale dictionary เมื่อ trim แล้วไม่ว่าง มิฉะนั้นคืน fallback คงที่ต่อ key (ตาราง `FALLBACK`) — ไม่คืน raw key และไม่คืนสตริงว่างในทุกกรณี (pattern เดียวกับ `promptText.ts`)
    - fallback keys ครอบคลุม `rig_title`, `rig_close_hint`, `rig_empty`, `rig_locale_error`
    - _Requirements: 6.3, 6.4_

  - [x] 2.8 เขียน property test สำหรับ `rigText` ใน `web/src/__tests__/rigText.test.ts`
    - **Property 6: การ resolve ข้อความ locale มี fallback เสมอ**
    - generate dictionary ที่ขาด key / ค่าว่าง / ช่องว่างล้วน / ข้อความจริง × key ของ Rig_Menu; assert คืน dict value เมื่อไม่ว่าง มิฉะนั้นคืน fallback, ไม่เท่ากับ raw key, ไม่เป็นสตริงว่าง
    - `fc.assert(..., { numRuns: 100 })`, tag `// Feature: fishing-rig-menu-nui, Property 6`
    - **Validates: Requirements 6.3, 6.4**

- [x] 3. Checkpoint - รัน property test ให้ผ่าน
  - Ensure all tests pass, ask the user if questions arise.

- [x] 4. Implement Rig_Menu component และ CSS
  - [x] 4.1 สร้าง `web/src/components/RigMenu.tsx`
    - รับ props `{ view, catalog }`; เรียก `buildRigRows(view, catalog)` แล้ว map เป็นแถวตามลำดับ
    - หัวข้อจาก `rigText('rig_title')` + บรรทัด `rigText('rig_close_hint')`; ถ้าไม่มีแถวแสดง `rigText('rig_empty')`
    - แต่ละแถว: `<img src={nui://zfishing/assets/items/${name}.png}>` + label + `formatOwned(owned)`; `onError` → ซ่อนรูปแต่คง box ขนาดคงที่; opacity ตาม `isDimmed(owned)`
    - `onClick` แถว → `resolveRigAction(row)`; ได้ action → `fetchNui('rigAction', ...)`, ถ้า `blocked` → ไม่เรียก
    - keydown ESC → `fetchNui('rigClose')`
    - รอ `loadLocale()` ให้เสร็จก่อนเรนเดอร์ครั้งแรก; ถ้าโหลด locale ล้มเหลว → ใช้ค่าฐาน + แสดง `rig_locale_error`
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 3.2, 4.1, 4.2, 4.3, 6.1, 6.5_

  - [x] 4.2 เพิ่ม CSS ของ Rig_Menu ใน `web/src/style.css`
    - `.rig-menu`: `position:fixed`, `right: ≥2vw`, `top:50%` + `translateY(-50%)` (right-center)
    - `.rig-row` dimmed: opacity ≤ 0.5 เมื่อ `owned === 0`, เต็ม 1.0 เมื่อ > 0; `.rig-row__icon` มี box ขนาดคงที่เพื่อไม่ให้แถวเลื่อนเมื่อรูปโหลดไม่ได้
    - _Requirements: 2.5, 2.6, 2.7, 2.9_

  - [x] 4.3 เขียน unit test สำหรับ `RigMenu` ใน `web/src/components/__tests__/RigMenu.test.tsx`
    - แสดง title + `rig_close_hint`; img src อ้าง `assets/items/<name>.png`; กรณี 0 แถวแสดง `rig_empty` (R2.1, 2.4, 2.8)
    - จำลอง img `onError` → แถวยังมี label + qty, box คงขนาด (R2.7)
    - จำลอง keydown ESC → เรียก `fetchNui('rigClose')` (R3.2)
    - mock `loadLocale` reject → เรนเดอร์ต่อ + แสดง `rig_locale_error` (R6.5)
    - _Requirements: 2.1, 2.4, 2.7, 2.8, 3.2, 6.5_

- [x] 5. ต่อ Rig_Menu เข้ากับ App overlay
  - [x] 5.1 แก้ `web/src/App.tsx` เพิ่ม rig overlay state และ dispatch
    - เพิ่ม state `rig` (`{ view, catalog } | null`) แยกจาก HUD view state machine
    - เพิ่ม case ใน `useNuiEvent`: `rigOpen` → set state, `rigClose` → null
    - render `<RigMenu view catalog />` เป็น overlay อิสระ (coexist กับ view อื่นเหมือน PromptHud)
    - _Requirements: 2.1, 3.3_

  - [x] 5.2 เขียน unit test สำหรับ rig dispatch ใน `web/src/__tests__/App.test.tsx`
    - action `rigOpen` → render `RigMenu`; action `rigClose` → เอา `RigMenu` ออก
    - _Requirements: 2.1_

- [x] 6. Rewrite Rig_Client และเพิ่ม standby flag
  - [x] 6.1 เพิ่ม flag `ZClient.standby` ใน `client/main.lua`
    - ตั้ง `ZClient.standby = true` ก่อนเข้า equip-standby loop ใน `startFishing()` และ `= false` เมื่อออกจาก loop; ให้ `cleanup()` ตั้ง `false` และเรียกปิดเมนู rig ด้วย (surgical — ไม่แตะ lifecycle 6 สถานะ)
    - _Requirements: 3.4, 7.3_

  - [x] 6.2 เขียนใหม่ `client/rig.lua`
    - ลบ `openRigMenu` (ox_lib context), handler `zfishing:manageRod`, handler `zfishing:rig:open`, และการเรียก `lib.registerContext`/`lib.showContext` ของ rig ทั้งหมด (R5.1, 5.2, 5.6)
    - `RegisterCommand('zfishing_rig', handler, false)` + `RegisterKeyMapping('zfishing_rig', 'Manage fishing rod', 'keyboard', 'G')` (R1.1, 1.5)
    - `RigState = { open, pending }`; handler toggle: เปิดอยู่→ปิด; ไม่เปิด→ gate (standby? ไม่ pending? ยังไม่เปิด?) แล้ว `zfishing:rig:get(rodSlot)` timeout 5s (R1.2, 1.3, 1.4, 1.7, 1.8)
    - view=nil/ว่าง → ไม่เปิด + notify `rig_no_rod` (R1.6)
    - `buildCatalog()` จาก `Config.Equipment.reels/lines/hooks/floats` แล้ว `SendNUIMessage({action='rigOpen', view, catalog})` + `SetNuiFocus(true,true)` (R2.4, 3.1, 5.4, 5.7)
    - `RegisterNUICallback('rigAction', cb)`: `attach`→`zfishing:rig:attach(slot, partType, itemName)`, `detach`→`zfishing:rig:detach(slot, partType)` timeout 5s; ok→refresh view + notify `attached`/`detached`; err→ notify ผ่าน `resolveNotifyKey` mapping (`rig_inv_full`/`rig_error`) คงสภาพเดิม (R4.1, 4.2, 4.4, 4.5, 4.6, 4.7, 4.8, 4.9, 4.10, 7.5, 7.6)
    - `closeMenu()` (จุดปิดจุดเดียว, idempotent): `SetNuiFocus(false,false)` เป็นสิ่งแรกเสมอ แล้ว `SendNUIMessage({action='rigClose'})`; `RegisterNUICallback('rigClose', cb)` เรียก `closeMenu()` (R3.3, 3.4, 3.5, 3.6, 3.7)
    - ไม่มีการตรวจ mode และไม่เรียก `zfishing:rig:mode` (Enhanced_Mode เท่านั้น)
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 3.1, 3.3, 3.4, 3.5, 3.6, 3.7, 4.1, 4.2, 4.4, 4.5, 4.6, 4.7, 4.8, 4.9, 4.10, 5.1, 5.2, 5.4, 5.5, 5.6, 5.7, 6.1, 7.5, 7.6_

- [x] 7. ลบคำสั่ง `/fishrig` ฝั่ง server
  - [x] 7.1 ลบบล็อก `RegisterCommand('fishrig', ...)` ใน `server/rig.lua`
    - ลบ command ที่ trigger `zfishing:rig:open` ทั้งบล็อก; คง callback `zfishing:rig:get/attach/detach` และ `Rig.*` เดิมไม่แตะ (R5.3, 7.1, 7.2)
    - _Requirements: 5.3, 7.1, 7.2_

- [x] 8. Build NUI และตรวจสอบขั้นสุดท้าย
  - [x] 8.1 Build NUI และรัน test suite ใน `web/`
    - รัน `npm run build` (tsc + vite build) ให้ผ่านโดยไม่มี TS error และรัน `npm run test` (vitest --run) ให้ property test (Property 1–6) + unit test ผ่านทั้งหมด
    - ตรวจ smoke/inspection: `fxmanifest.lua` มี `'assets/items/*.png'`; `client/rig.lua` มี `RegisterKeyMapping('zfishing_rig', ..., 'keyboard', 'G')`; `en.json`/`th.json` มี `rig_title`/`rig_close_hint`/`rig_empty`; ไม่มี `lib.registerContext`/`RegisterCommand('fishrig')`/handler `zfishing:manageRod` ที่เปิดเมนูหลงเหลือ
    - _Requirements: 1.1, 2.4, 5.1, 5.2, 5.3, 6.2_

- [x] 9. Final checkpoint - ตรวจ regression และ contract
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks ที่มี `*` เป็น optional (property/unit test) ข้ามเพื่อทำ MVP ได้เร็วขึ้น แต่แนะนำให้ทำเพื่อยืนยัน Property 1–6
- แต่ละ task อ้างอิง requirement/property เพื่อ traceability
- Property test ใช้ fast-check + Vitest รันขั้นต่ำ 100 iterations ต่อ property และ tag อ้าง Property number ตาม design
- Requirement 7 (contract preservation) บังคับผ่านข้อจำกัดใน task 6.2 และ 7.1 (ไม่แตะ signature/return ของ callback) ร่วมกับ smoke check ใน 8.1
- งานฝั่ง Lua ยังไม่มี test runner สำหรับ client จึงยืนยันด้วยข้อจำกัดเชิงโครงสร้างใน task + smoke check + build/test ฝั่ง NUI; requirement ที่ขึ้นกับ FiveM native/timing (เช่น 1.2, 3.1, 4.4, 5.4) ยืนยันในเกม/mock runtime ตาม Testing Strategy

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "1.2", "2.1", "2.7", "6.1"] },
    { "id": 1, "tasks": ["2.2", "2.8", "4.1", "4.2", "7.1"] },
    { "id": 2, "tasks": ["2.3", "4.3", "5.1"] },
    { "id": 3, "tasks": ["2.4", "5.2", "6.2"] },
    { "id": 4, "tasks": ["2.5"] },
    { "id": 5, "tasks": ["2.6"] },
    { "id": 6, "tasks": ["8.1"] }
  ]
}
```
