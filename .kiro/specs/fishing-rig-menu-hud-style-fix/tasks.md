# Implementation Plan: fishing-rig-menu-hud-style-fix

## Overview

แผนงานนี้แก้ 2 อาการฝั่ง presentation ของระบบตกปลา โดยใช้ bug condition methodology ตามลำดับ: เขียน exploration test (Property 1) ยืนยันว่าบั๊กมีจริงบนโค้ดที่ยังไม่แก้ → เขียน preservation test (Property 2) จับ baseline behavior → apply fix (CSS ของ `.rig-menu` ให้โปร่งใส + text-shadow และเพิ่มคำใบ้ `[G]` ในค่า locale/FALLBACK) → ยืนยัน Property 1 pass และ Property 2 ไม่ regress → checkpoint

**หมายเหตุด้านขอบเขต:** การแก้อยู่ที่ presentation layer เท่านั้น — `web/src/style.css`, `locales/th.json`, `locales/en.json`, `web/src/promptText.ts` (+ test fixture) โดย **ไม่แตะ** `client/rig.lua`, `client/main.lua` lifecycle/`showPrompt`, โครงสร้าง DOM ของ `RigMenu.tsx`/`PromptHud.tsx` และฝั่ง server ทั้งหมด การแก้ที่ค่า `equip_hint` เดียวครอบทั้ง NUI (`resolvePromptText`) และ TextUI fallback (`lib.showTextUI(locale('equip_hint'))`)

## Tasks

- [x] 1. เขียน bug condition exploration test (ก่อนแก้ไข)
  - **Property 1: Bug Condition** - Rig_Menu โปร่งใส + text-shadow และคำใบ้ปุ่ม G
  - **CRITICAL**: test นี้ต้อง FAIL บนโค้ดที่ยังไม่แก้ (unfixed) — การ fail ยืนยันว่าบั๊กมีอยู่จริง
  - **DO NOT attempt to fix the test or the code when it fails** — เป้าหมายคือ surface counterexample เท่านั้น
  - **NOTE**: test นี้ encode พฤติกรรมที่คาดหวังไว้ — จะใช้ validate การแก้เมื่อ test ผ่านหลัง implement
  - **GOAL**: surface counterexample ที่แสดงว่า Rig_Menu เป็นกล่องทึบ/ไม่มี text-shadow และ `equip_hint` ไม่มี `[G]`
  - **Scoped PBT Approach**: บั๊กเป็นแบบ deterministic — scope property ไปที่ concrete case ที่ fail แน่นอน (surface `rig_menu` และ key `equip_hint`) พร้อมสุ่ม dict states สำหรับ edge case (dict มีค่า / dict ว่าง)
  - เขียน test render `RigMenu` แล้ว assert computed style ของ `.rig-menu`: ไม่มี solid background (`var(--bg)`), ไม่มี box border/`border-left` accent, ไม่มี `box-shadow`, ไม่มี backdrop blur ที่ทำให้เกิดกล่องทึบ (จาก Bug Condition ใน design)
  - เขียน test assert ว่า `.rig-menu__title` / `.rig-row__label` มี `text-shadow`
  - เขียน test assert ว่า `resolvePromptText('equip_hint')` มีสตริง `[G]` และคำว่า `จัดการเบ็ด` (ไทย) หรือ `Manage Rod` (อังกฤษ) — ครอบทั้งกรณี dict มีค่า และ dict ว่าง (FALLBACK นอก FiveM)
  - assertion ต้องตรงกับ Expected Behavior Properties (Property 1 + Property 2) ใน design
  - รัน test บนโค้ด UNFIXED
  - **EXPECTED OUTCOME**: Test FAILS (ถูกต้อง — พิสูจน์ว่าบั๊กมีอยู่จริง)
  - Document counterexamples ที่พบ (เช่น `.rig-menu` มี `background: var(--bg)` + `box-shadow` + backdrop blur; `resolvePromptText('equip_hint')` = `[E] ... · [X] ...` ไม่มี `[G]`) เพื่อเข้าใจ root cause
  - ทำเครื่องหมาย task เสร็จเมื่อ test ถูกเขียน, รัน, และ documented การ fail แล้ว
  - _Requirements: 1.1, 1.2, 1.3_

- [x] 2. เขียน preservation property tests (ก่อนแก้ไข)
  - **Property 2: Preservation** - Input นอกเงื่อนไขบั๊กไม่เปลี่ยนแปลง
  - **IMPORTANT**: ใช้ observation-first methodology — สังเกตพฤติกรรมบนโค้ด UNFIXED ก่อน แล้วเขียน test จับพฤติกรรมนั้น
  - สังเกตบนโค้ดที่ยังไม่แก้สำหรับ input ที่ `isBugCondition` คืนค่า false:
    - `resolvePromptText('equip_title')` / `resolvePromptText('cancel_title')` / `resolvePromptText('cancel_hint')` คืนค่าเดิม (จดค่าที่ observe ได้)
    - `RigMenu` render จำนวน/ลำดับแถวจาก `buildRigRows`, การ dim แถวที่ owned = 0, empty state, locale-error, box icon ขนาดคงที่
    - ESC ในเมนู → dispatch `fetchNui('rigClose')`; คลิกแถว → dispatch `fetchNui('rigAction', ...)` ด้วย args เดิม
  - เขียน property-based test (fast-check): สำหรับทุก key ∈ {`equip_title`, `cancel_title`, `cancel_hint`} และ dict states ที่สุ่ม (มี key / ไม่มี key / ค่าว่าง) ผลของ `resolvePromptText` เท่ากับพฤติกรรมเดิมที่ observe ได้ (จาก Preservation Requirements ใน design)
  - เขียน property-based test: สุ่ม `view` + `catalog` แล้ว assert จำนวน/ลำดับแถว และการ dim owned = 0 ของ `RigMenu` ไม่เปลี่ยนจากเดิม
  - เขียน test: locale fallback ของ key อื่น (ที่ไม่ใช่ `equip_hint`) ยังคืน fallback/ไม่คืน raw key เหมือนเดิม
  - property-based testing generate test case จำนวนมากอัตโนมัติเพื่อการรับประกันที่แข็งแรงว่าพฤติกรรมไม่เปลี่ยนสำหรับทุก input นอกเงื่อนไขบั๊ก
  - รัน tests บนโค้ด UNFIXED
  - **EXPECTED OUTCOME**: Tests PASS (ยืนยัน baseline behavior ที่ต้องคงไว้)
  - ทำเครื่องหมาย task เสร็จเมื่อ tests ถูกเขียน, รัน, และ pass บนโค้ดที่ยังไม่แก้แล้ว
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_

- [x] 3. Fix สำหรับ Rig_Menu HUD style + คำใบ้ปุ่ม G

  - [x] 3.1 แก้ CSS ของ `.rig-menu` ให้โปร่งใส + เพิ่ม text-shadow
    - แก้ `web/src/style.css`: ลบ `background: var(--bg)`, `border`, `border-left` accent, `box-shadow`, `backdrop-filter: blur(4px)` ออกจาก `.rig-menu` ให้ `background: transparent` คงไว้แต่ layout (ตำแหน่งกึ่งกลางแนวตั้งฝั่งขวา, `pointer-events: auto`)
    - เพิ่ม `text-shadow` (เช่น `0 1px 3px rgba(0,0,0,0.9)`) + สีขาว ให้ `.rig-menu__title`, `.rig-menu__hint`, `.rig-menu__empty`, `.rig-menu__locale-error`, `.rig-row__label`, `.rig-row__owned`
    - ปรับ `.rig-row` / `.rig-row__icon` ให้เข้าธีมโปร่งใส — คง box icon ขนาดคงที่ (กันแถวเลื่อนเมื่อรูปโหลดไม่ได้) แต่ไม่สร้างกล่องทึบ
    - คงโครงสร้าง header (title ตัวใหญ่ + บรรทัด "กด ESC เพื่อปิด") ให้ล้อสไตล์ `.prompt-title` / `.prompt-subtitle` — ไม่แตะโครงสร้าง DOM ของ `RigMenu.tsx`
    - _Bug_Condition: isBugCondition(X) where X.surface = 'rig_menu' (จาก design)_
    - _Expected_Behavior: no_solid_background AND no_box_border AND no_box_shadow AND has_text_shadow (Property 1 จาก design)_
    - _Preservation: Preservation Requirements จาก design_
    - _Requirements: 2.1, 2.2_

  - [x] 3.2 เพิ่มคำใบ้ปุ่ม G ในค่า locale + FALLBACK
    - แก้ `locales/th.json`: `"equip_hint": "[E] เริ่มตกปลา   ·   [X] เก็บเบ็ด   ·   [G] จัดการเบ็ด"`
    - แก้ `locales/en.json`: `"equip_hint": "[E] Start fishing   ·   [X] Pack up rod   ·   [G] Manage Rod"`
    - แก้ตาราง `FALLBACK` ใน `web/src/promptText.ts` ให้ `equip_hint` มี `[G] Manage Rod` (เพื่อครอบกรณี dict ว่าง / นอก FiveM / getLocale ล้มเหลว)
    - อัปเดต `FALLBACK` ที่ hard-code ใน `web/src/__tests__/promptText.test.ts` ให้ตรงกัน มิฉะนั้น property test เดิมจะ fail
    - การแก้ที่ค่า locale นี้ครอบทั้ง NUI (`resolvePromptText` → `getLocale`) และ TextUI fallback (`lib.showTextUI(locale('equip_hint'))` เมื่อ `Config.PromptHud = false`) โดยไม่ต้องเพิ่ม logic
    - ไม่แตะ key `equip_hint` ที่เรียกใน `client/main.lua`
    - _Bug_Condition: isBugCondition(X) where X.surface = 'prompt_hud' AND X.phase = 'equip_standby' (จาก design)_
    - _Expected_Behavior: contains(subtitle, '[G]') AND contains 'จัดการเบ็ด'/'Manage Rod' (Property 2 จาก design)_
    - _Preservation: Preservation Requirements จาก design_
    - _Requirements: 2.3, 3.5_

  - [x] 3.3 ยืนยันว่า bug condition exploration test ผ่านแล้ว
    - **Property 1: Expected Behavior** - Rig_Menu โปร่งใส + text-shadow และคำใบ้ปุ่ม G
    - **IMPORTANT**: รัน test เดิมจาก task 1 ซ้ำ — ห้ามเขียน test ใหม่
    - test จาก task 1 encode พฤติกรรมที่คาดหวังไว้ — เมื่อ test ผ่าน แสดงว่า Expected Behavior ถูกต้อง
    - รัน bug condition exploration test จาก task 1
    - **EXPECTED OUTCOME**: Test PASSES (ยืนยันว่าบั๊กถูกแก้แล้ว)
    - _Requirements: 2.1, 2.2, 2.3_

  - [x] 3.4 ยืนยันว่า preservation tests ยัง pass
    - **Property 2: Preservation** - Input นอกเงื่อนไขบั๊กไม่เปลี่ยนแปลง
    - **IMPORTANT**: รัน tests เดิมจาก task 2 ซ้ำ — ห้ามเขียน tests ใหม่
    - รัน preservation property tests จาก task 2
    - **EXPECTED OUTCOME**: Tests PASS (ยืนยันว่าไม่มี regression)
    - ยืนยันว่า tests ทั้งหมดยัง pass หลังแก้ (prompt keys อื่น, RigMenu rows/logic, locale fallback, TextUI fallback)
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_

- [x] 4. Checkpoint - ยืนยันว่า tests ทั้งหมดผ่าน
  - รัน test suite ทั้งหมด (`npx vitest --run`) และยืนยันว่า Property 1 (Bug Condition/Expected Behavior) และ Property 2 (Preservation) ผ่านทั้งหมด
  - (Manual in-game) integration flow: equip standby → Prompt_HUD แสดง `[E] · [X] · [G]` → กด G เปิด Rig_Menu (โปร่งใส + text-shadow) → attach/detach → ESC ปิด → prompt กลับมาเหมือนเดิม
  - ยืนยัน th/en switching และ `Config.PromptHud = false` (TextUI) แสดง `equip_hint` ที่มี `[G]`
  - ถ้ามีคำถามหรือ test ใด fail โดยไม่คาดคิด ให้สอบถามผู้ใช้

## Notes

- Property 1 (Bug Condition → Expected Behavior หลังแก้) และ Property 2 (Preservation) ใช้ format `**Property N:**` เพื่อรองรับ hover status ตาม bug condition methodology
- exploration test (task 1) และ preservation test (task 2) เป็น standalone task และต้องอยู่ **ก่อน** implementation (task 3) เสมอ
- fix เป็น presentation-only: CSS-only fix สำหรับอาการ Rig_Menu และ locale-value fix สำหรับคำใบ้ `[G]` — ไม่แตะ `client/rig.lua`, `client/main.lua` lifecycle, DOM ของ NUI components และฝั่ง server ตามขอบเขตใน bugfix.md/design.md
- การแก้ที่ค่า `equip_hint` เดียวครอบทั้ง NUI path และ TextUI fallback path (R3.5) โดยไม่เพิ่ม logic
- แต่ละ task อ้างอิง Correctness Property (design.md) + acceptance criteria (bugfix.md) เพื่อ traceability

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1", "2"] },
    { "id": 1, "tasks": ["3.1", "3.2"] },
    { "id": 2, "tasks": ["3.3", "3.4"] },
    { "id": 3, "tasks": ["4"] }
  ]
}
```
