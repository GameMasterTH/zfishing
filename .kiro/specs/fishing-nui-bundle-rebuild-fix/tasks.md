# Implementation Plan: fishing-nui-bundle-rebuild-fix

## Overview

บั๊กนี้เป็นปัญหา **stale build artifact + deploy** ไม่ใช่ข้อผิดพลาดของ source code — spec ก่อนหน้าแก้ CSS ของ Rig_Menu ใน `web/src/style.css` แล้วผ่าน `vitest` ระดับ source แต่ไม่เคยรัน `npm run build` ทำให้ `web/dist/` (bundle ที่ FiveM โหลดจริง) ยังเป็นเวอร์ชันเก่า และ resource สำเนาที่เซิร์ฟเวอร์รันจริงยังถือ bundle hash เก่า (`index-DLW4jjFM.css` / `index-zLgQY8bw.js`)

แผนงานนี้ใช้ bug condition methodology ตามลำดับ: เขียน exploration test (Property 1) ยืนยันว่า deployed bundle CSS ไม่ตรง source (บั๊กมีจริง) → เขียน preservation test (Property 2) จับ baseline ของทุกสิ่งที่ต้องไม่เปลี่ยน → rebuild bundle จาก source + deploy ไปทับสำเนา + restart resource → ยืนยัน Property 1 pass และ Property 2 ไม่ regress → checkpoint

**หมายเหตุด้านขอบเขต:** งานเป็น **build + deploy operations เท่านั้น ไม่มีการแก้ source code** — ไม่แตะ `web/src/*`, `fxmanifest.lua`, Lua ฝั่ง server/client และ DOM structure ของ NUI components เทสต์ทั้งหมดเป็นการ **assert เนื้อหาไฟล์ bundle ที่ deploy** (content/hash diffing) ไม่ใช่ unit test ของ logic

- เทสต์ใหม่วางไว้ที่ `web/src/__tests__/` (ตาม convention เดิม), รันด้วย `npm run test` (`vitest --run`) จาก `e:\Web\ZCore\zfishing\web\`
- fast-check (v3) มีอยู่แล้วใน devDependencies สำหรับ property-based testing
- Source repo dist: `e:\Web\ZCore\zfishing\web\dist\`
- Deploy copy dist: `c:\Users\GameMaster\Desktop\FiveM Server\txData\QBCore_E66DFA.base\resources\[zlab]\zfishing\web\dist\`
- Old (stale) bundle hash: `index-DLW4jjFM.css` / `index-zLgQY8bw.js`

## Tasks

- [x] 1. เขียน bug condition exploration test (ก่อน rebuild + deploy)
  - **Property 1: Bug Condition** - Stale Rig_Menu Bundle CSS
  - **CRITICAL**: test นี้ต้อง FAIL บน artifact เก่า (ที่ยังไม่ rebuild) — การ fail ยืนยันว่าบั๊กมีอยู่จริง
  - **DO NOT attempt to fix the test or the code when it fails** — stale bundle คือตัวบั๊กเอง
  - **NOTE**: test นี้ encode Expected Behavior ไว้ — จะใช้ validate การแก้เมื่อ test ผ่านหลัง rebuild + deploy
  - **GOAL**: surface counterexample ที่แสดงว่า deployed bundle CSS ไม่ตรงกับ `web/src/style.css`
  - **Scoped PBT Approach**: บั๊กเป็นแบบ deterministic (artifact ค้างเก่า) — scope property ไปที่ชุด selector ที่ยืนยันได้ (`.rig-menu`, `.rig-menu__title`, `.rig-menu__hint`, `.rig-menu__empty`, `.rig-row__label`, `.rig-row__owned`) เพื่อ reproducibility
  - เขียน test `web/src/__tests__/rigMenuBundleRebuild.exploration.test.ts` ที่:
    - อ่าน CSS ที่ deploy จริงจาก `web/dist/assets/*.css` (และ/หรือ deploy copy) แล้ว extract rule `.rig-menu`
    - assert (expected behavior จาก Bug Condition / Property 1): `.rig-menu` มี `background:transparent` และ **ไม่มี** `box-shadow` / `backdrop-filter` / `var(--bg)` ใน rule นั้น
    - assert: `.rig-menu__title` / `.rig-menu__hint` / `.rig-menu__empty` / `.rig-row__label` / `.rig-row__owned` มี `text-shadow` + สีขาว (`#fff`)
    - assert: `web/dist/index.html` **ไม่** อ้าง `index-DLW4jjFM.css` / `index-zLgQY8bw.js` (hash เก่า)
    - assert: deploy copy `web/dist/` **ไม่มี** ไฟล์ hash เก่า `index-DLW4jjFM.css` / `index-zLgQY8bw.js` ค้างอยู่
  - assertion ต้องตรงกับ Expected Behavior (Property 1) ใน design
  - รัน test บน artifact ปัจจุบัน (unfixed / ยังไม่ rebuild) ด้วย `npm run test`
  - **EXPECTED OUTCOME**: Test FAILS (ถูกต้อง — พิสูจน์ว่า stale bundle bug มีอยู่จริง)
  - Document counterexamples ที่พบ (เช่น deployed `.rig-menu` = `background:var(--bg);...box-shadow...backdrop-filter:blur(4px)` ในขณะที่ source = transparent; deploy copy ยังมี `index-DLW4jjFM.css`)
  - ทำเครื่องหมาย task เสร็จเมื่อ test ถูกเขียน, รัน, และ documented การ fail แล้ว
  - _Requirements: 1.1, 1.2, 1.3, 1.4_

- [x] 2. เขียน preservation property tests (ก่อน rebuild + deploy)
  - **Property 2: Preservation** - Source, Other HUD, and fxmanifest Unchanged
  - **IMPORTANT**: ใช้ observation-first methodology — สังเกตพฤติกรรมบน artifact/source เดิมก่อน แล้วเขียน test จับพฤติกรรมนั้น
  - **GOAL**: จับ baseline ของทุกสิ่งที่ bug condition ไม่ครอบคลุม เพื่อยืนยันว่าไม่เปลี่ยนหลัง rebuild + deploy
  - เขียน property-based test `web/src/__tests__/bundleRebuildPreservation.test.ts` (fast-check) ที่:
    - สังเกต: `web/src/*` (รวม `style.css`, `App.tsx`, components, hooks) เป็น source of truth — assert ว่างานนี้ไม่แก้ (`git diff` ของ `web/src`, Lua, `fxmanifest.lua` ต้องว่าง)
    - สังเกต + PBT: generate รายชื่อ CSS selector ของ HUD components อื่นใน bundle เดียวกัน (CastBar, PromptHud, Admin panel, catch card) แล้ว assert ว่า declaration ใน bundle เหมือน baseline (ไม่เปลี่ยนเชิงพฤติกรรม)
    - สังเกต: prompt `[G] จัดการเบ็ด` โหลดจาก `locales/*.json` โดยตรง (ไม่เกี่ยวกับ bundle) — assert ยังถูกต้อง
    - assert: `ui_page` และ `files` ใน `fxmanifest.lua` ไม่เปลี่ยน (ยังชี้ `web/dist/`)
  - property-based testing generate test case จำนวนมากอัตโนมัติเพื่อการรับประกันที่แข็งแรงว่าพฤติกรรมไม่เปลี่ยนสำหรับทุก input นอกเงื่อนไขบั๊ก
  - รัน tests บน artifact/code ปัจจุบัน (unfixed) ด้วย `npm run test`
  - **EXPECTED OUTCOME**: Tests PASS (ยืนยัน baseline behavior ที่ต้องคงไว้)
  - ทำเครื่องหมาย task เสร็จเมื่อ tests ถูกเขียน, รัน, และ pass บน artifact ปัจจุบันแล้ว
  - _Requirements: 3.1, 3.2, 3.3, 3.4_

- [x] 3. Fix สำหรับ stale NUI bundle (rebuild + deploy, no source changes)

  - [x] 3.1 Rebuild NUI bundle จาก source ปัจจุบัน
    - รัน `npm run build` (`tsc && vite build`) ใน `e:\Web\ZCore\zfishing\web\`
    - Vite (`emptyOutDir: true`) ล้าง `web/dist/` เก่าก่อน แล้ว regenerate `index.html` + `assets/index-*.css` + `assets/index-*.js` + fonts
    - เนื้อหา CSS เปลี่ยน → bundle hash เปลี่ยนจาก `index-DLW4jjFM.css` เป็น hash ใหม่ และ `index.html` ชี้ไฟล์ใหม่อัตโนมัติ
    - **ห้าม**แก้ไฟล์ใน `web/src/*`, `fxmanifest.lua`, หรือ Lua ฝั่ง server/client
    - _Bug_Condition: isBugCondition(input) — deployedRigMenuCss ≠ sourceRigMenuCss (artifact ค้างเก่า)_
    - _Expected_Behavior: expectedBehavior(result) — `.rig-menu` = transparent (ไม่มี box-shadow/backdrop-filter/var(--bg)); title/hint/empty/row labels มี text-shadow + #fff_
    - _Preservation: web/src/*, Lua, DOM, fxmanifest, HUD อื่น ไม่เปลี่ยน_
    - _Requirements: 2.1, 2.2_

  - [x] 3.2 Deploy bundle ที่ rebuild แล้วไปยัง resource สำเนาที่รันจริง
    - ลบโฟลเดอร์ `web/dist/` เดิมใน deploy copy ก่อน (กันไฟล์ hash เก่าค้าง เพราะ Vite ตั้ง filename ตาม hash — ไฟล์เก่าจะไม่ถูกเขียนทับ)
    - คัดลอก `e:\Web\ZCore\zfishing\web\dist\` ทั้งโฟลเดอร์ไปยัง `c:\Users\GameMaster\Desktop\FiveM Server\txData\QBCore_E66DFA.base\resources\[zlab]\zfishing\web\dist\`
    - ยืนยัน deploy copy มีชุดไฟล์ + เนื้อหา (hash) ตรงกับ source repo dist ทุกไฟล์
    - _Bug_Condition: deploy copy ถือ bundle hash เก่า (index-DLW4jjFM.css / index-zLgQY8bw.js)_
    - _Expected_Behavior: deploy copy hash == source repo dist hash_
    - _Preservation: ไม่แตะไฟล์อื่นใน resource copy นอกจาก web/dist/_
    - _Requirements: 2.3_

  - [x] 3.3 Restart resource `zfishing`
    - แจ้งผู้ใช้รัน `ensure zfishing` (หรือ `restart zfishing`) ใน server console เพื่อให้ FiveM โหลด `ui_page` จาก bundle ใหม่
    - _Bug_Condition: FiveM ยัง cache/โหลด bundle เก่าก่อน restart_
    - _Expected_Behavior: ผู้เล่นกด G เห็น Rig_Menu พื้นหลังโปร่งใส + text-shadow (ไม่เป็นกล่องดำ)_
    - _Requirements: 2.4_

  - [x] 3.4 ยืนยันว่า bug condition exploration test ผ่านแล้ว
    - **Property 1: Expected Behavior** - Rebuilt Rig_Menu Bundle CSS
    - **IMPORTANT**: รัน test เดิมจาก task 1 ซ้ำ — ห้ามเขียน test ใหม่
    - test จาก task 1 encode พฤติกรรมที่คาดหวังไว้ — เมื่อผ่าน แสดงว่า deployed bundle ตรงกับ source
    - รัน `npm run test` แล้วรัน exploration test จาก task 1
    - **EXPECTED OUTCOME**: Test PASSES (ยืนยัน `.rig-menu` transparent + text-shadow, index.html ชี้ hash ใหม่, deploy copy ไม่มี hash เก่า)
    - _Requirements: 2.1, 2.2, 2.3, 2.4_

  - [x] 3.5 ยืนยันว่า preservation tests ยัง pass
    - **Property 2: Preservation** - Source, Other HUD, and fxmanifest Unchanged
    - **IMPORTANT**: รัน tests เดิมจาก task 2 ซ้ำ — ห้ามเขียน tests ใหม่
    - รัน preservation property tests จาก task 2 ด้วย `npm run test`
    - **EXPECTED OUTCOME**: Tests PASS (ยืนยันว่าไม่มี regression — `web/src/*`, Lua, fxmanifest, HUD อื่น, prompt จาก locales ไม่เปลี่ยน)
    - ยืนยันว่า tests ทั้งหมดยัง pass หลัง rebuild + deploy (no regressions)
    - _Requirements: 3.1, 3.2, 3.3, 3.4_

- [x] 4. Checkpoint - ยืนยันว่า tests ทั้งหมดผ่าน
  - รัน `npm run test` แบบเต็มชุดใน `web/` ให้ผ่านทั้งหมด (exploration + preservation + เทสต์เดิม)
  - ยืนยัน hash parity ระหว่าง source repo dist กับ deploy copy dist อีกครั้ง
  - (Manual in-game) integration flow: กด G เปิด Rig_Menu → พื้นหลังโปร่งใส + text-shadow (ไม่เป็นกล่องดำ); HUD อื่น (CastBar ขณะเหวี่ยง, PromptHud, Admin panel) และ prompt `[G] จัดการเบ็ด` ยังปกติหลังโหลด bundle ใหม่
  - ถ้ามีคำถามหรือ test ใด fail โดยไม่คาดคิด ให้สอบถามผู้ใช้

## Notes

- Property 1 (Bug Condition → Expected Behavior หลัง rebuild + deploy) และ Property 2 (Preservation) ใช้ format `**Property N:**` เพื่อรองรับ hover status ตาม bug condition methodology
- exploration test (task 1) และ preservation test (task 2) เป็น standalone task และต้องอยู่ **ก่อน** implementation (task 3) เสมอ
- fix เป็น build + deploy เท่านั้น (ไม่แก้ source): rebuild `web/dist` จาก source → deploy ทับสำเนา → restart resource ตามขอบเขตใน bugfix.md/design.md
- บั๊กนี้เป็นเรื่อง build artifact — เทสต์จึงเป็นการ assert เนื้อหา/hash ของไฟล์ bundle ที่ deploy ไม่ใช่ unit test ของ logic
- แต่ละ task อ้างอิง Correctness Property (design.md) + acceptance criteria (bugfix.md) เพื่อ traceability

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1", "2"] },
    { "id": 1, "tasks": ["3.1"] },
    { "id": 2, "tasks": ["3.2"] },
    { "id": 3, "tasks": ["3.3"] },
    { "id": 4, "tasks": ["3.4", "3.5"] },
    { "id": 5, "tasks": ["4"] }
  ]
}
```
