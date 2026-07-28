# Implementation Plan: rig-menu-icon-oversize-fix

## Overview

แผนงานนี้แก้บั๊ก icon ของ item ใน `Rig_Menu` ที่เรนเดอร์ใหญ่เกินกล่อง โดยใช้ bug condition methodology ตามลำดับ: เขียน exploration test (Property 1) ยืนยันว่าบั๊กมีจริงบนโค้ดที่ยังไม่แก้ → เขียน preservation test (Property 2) จับ baseline behavior → apply fix (เพิ่มกฎ CSS `.rig-row__icon img` + `overflow:hidden` ให้ container) → rebuild + deploy bundle → ยืนยัน Property 1 pass และ Property 2 ไม่ regress → checkpoint

**หมายเหตุด้านขอบเขต:** การแก้เป็น **CSS-only ที่ source** (`web/src/style.css`) แล้วตามด้วยกระบวนการ deploy (rebuild `web/dist/` → คัดลอกไปยัง resource ที่รันจริง → restart) โดย **ไม่แตะ** DOM ของ `RigMenu.tsx`, โค้ด Lua ฝั่ง server/client และ `fxmanifest.lua` ตามที่ระบุใน bugfix.md/design.md

## Tasks

- [x] 1. เขียน bug condition exploration test (ก่อนแก้ไข)
  - **Property 1: Bug Condition** - Icon ล้นกล่องเมื่อโหลดรูปสำเร็จ
  - **CRITICAL**: test นี้ต้อง FAIL บนโค้ดที่ยังไม่แก้ (unfixed) — การ fail ยืนยันว่าบั๊กมีอยู่จริง
  - **DO NOT attempt to fix the test or the code when it fails** — เป้าหมายคือ surface counterexample เท่านั้น
  - **NOTE**: test นี้ encode พฤติกรรมที่คาดหวังไว้ — จะใช้ validate การแก้เมื่อ test ผ่านหลัง implement
  - **GOAL**: surface counterexample ที่แสดงว่า `<img>` ล้นกล่อง `.rig-row__icon`
  - **Scoped PBT Approach**: สุ่ม `imgNaturalPx` หลายค่าที่ `> boxPx` ร่วมกับสถานะ `menuOpen === true`, `iconFailed === false`, ไม่มีกฎ `.rig-row__icon img`, ไม่มี `overflow:hidden` (ตรงกับ `isBugCondition` ใน design)
  - เรนเดอร์ `RigRowItem`/`RigMenu` โดยโหลด `web/src/style.css` ปัจจุบัน จำลอง `<img>` ที่มี `naturalWidth/naturalHeight` ใหญ่กว่ากล่อง แล้ววัดขนาดที่เรนเดอร์จริงของ `<img>` เทียบกับ `.rig-row__icon`
  - assert `img.renderedWidth <= box.width` และ `img.renderedHeight <= box.height` และ `NOT overlaps(img, label/owned)` (ตรงกับ Expected Behavior Properties ใน design)
  - รัน test บนโค้ด UNFIXED
  - **EXPECTED OUTCOME**: Test FAILS (ถูกต้อง — พิสูจน์ว่าบั๊กมีอยู่จริง)
  - Document counterexample ที่พบ (เช่น "PNG 128×128 เรนเดอร์ที่ 128px ในกล่อง ~35px ล้นทับ label") เพื่อเข้าใจ root cause
  - ทำเครื่องหมาย task เสร็จเมื่อ test ถูกเขียน, รัน, และ documented การ fail แล้ว
  - _Requirements: 1.1, 1.2, 1.3, 1.4_

- [x] 2. เขียน preservation property tests (ก่อนแก้ไข)
  - **Property 2: Preservation** - Input นอกเงื่อนไขบั๊กไม่เปลี่ยนแปลง
  - **IMPORTANT**: ใช้ observation-first methodology — สังเกตพฤติกรรมบนโค้ด UNFIXED ก่อน แล้วเขียน test จับพฤติกรรมนั้น
  - สังเกตบนโค้ดที่ยังไม่แก้สำหรับ input ที่ `isBugCondition` คืนค่า false:
    - `iconFailed === true` → ไม่มี `<img>` ในกล่อง กล่อง `.rig-row__icon` ยังคงขนาดคงที่ แถวไม่เลื่อน (จดค่าที่ observe)
    - `owned === 0` → แถว `opacity` ≤ 0.5
    - `.rig-menu`/`.rig-row__label`/`.rig-row__owned` มีพื้นหลังโปร่งใส + text-shadow ตามเดิม
    - HUD อื่นใน bundle เดียวกัน (CastBar, PromptHud, Admin panel, catch card) render ปกติ
  - เขียน property-based test สุ่มสถานะแถวที่ **ไม่เข้า** Bug Condition (`iconFailed`, `owned`, จำนวนแถว, element อื่นที่ไม่ใช่ `<img>` ใน `.rig-row__icon`) → verify ผลลัพธ์ตรงกับพฤติกรรมที่สังเกตไว้ (จาก Preservation Requirements ใน design)
  - property-based testing generate test case จำนวนมากอัตโนมัติเพื่อการรับประกันที่แข็งแรงว่าพฤติกรรมไม่เปลี่ยนสำหรับทุก input นอกเงื่อนไขบั๊ก
  - รัน tests บนโค้ด UNFIXED
  - **EXPECTED OUTCOME**: Tests PASS (ยืนยัน baseline behavior ที่ต้องคงไว้)
  - ทำเครื่องหมาย task เสร็จเมื่อ tests ถูกเขียน, รัน, และ pass บนโค้ดที่ยังไม่แก้แล้ว
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_

- [x] 3. Fix สำหรับ icon oversize ใน Rig_Menu (CSS-only ที่ source + deploy)

  - [x] 3.1 แก้ CSS ที่ source `web/src/style.css`
    - เพิ่ม selector ใหม่ `.rig-row__icon img { width:100%; height:100%; object-fit:contain; display:block; }` เพื่อบังคับให้ `<img>` ย่อพอดีกล่องและรักษาสัดส่วน
    - เพิ่ม `overflow:hidden` ให้ container `.rig-row__icon` เป็น defense-in-depth กันการล้นในทุกกรณี
    - (ทางเลือก) ลบ `object-fit: contain` ที่อยู่บน `.rig-row__icon` (div) ซึ่งไม่มีผล — surgical change เท่านั้น ไม่กระทบ property อื่นของ selector นี้
    - **ไม่แตะ** DOM (`RigMenu.tsx`), Lua, หรือ `fxmanifest.lua`
    - _Bug_Condition: isBugCondition(input) — menuOpen && !iconFailed && !hasImgSizingRule && imgNaturalPx > boxPx && !containerClipsOverflow (จาก design)_
    - _Expected_Behavior: expectedBehavior(result) — `<img>` renderedWidth/Height <= box และไม่ overlap label/owned (Property 1 จาก design)_
    - _Preservation: Preservation Requirements — icon failed คงกล่อง, dimmed row, พื้นหลัง/text-shadow, HUD อื่น (จาก design)_
    - _Requirements: 2.1, 2.2, 2.3_

  - [x] 3.2 Rebuild bundle และ deploy (จำเป็น — FiveM โหลด bundle ที่ build แล้ว)
    - รัน `npm run build` ใน `web/` เพื่อสร้าง `web/dist/` ใหม่ (ผู้ใช้รันเองใน terminal)
    - ลบ `dist` เก่าในสำเนา resource ที่เซิร์ฟเวอร์รันจริง (`[zlab]\zfishing\web\dist`) ก่อนเพื่อเลี่ยงไฟล์ hash ค้าง แล้วคัดลอก `web/dist/` ใหม่ไปแทน
    - `restart zfishing` บนเซิร์ฟเวอร์เพื่อให้ผู้เล่นเห็นผลจริง
    - _Requirements: 2.4_

  - [x] 3.3 ยืนยันว่า bug condition exploration test ผ่านแล้ว
    - **Property 1: Expected Behavior** - Icon ย่อพอดีกล่องขนาดคงที่
    - **IMPORTANT**: รัน test เดิมจาก task 1 ซ้ำ — ห้ามเขียน test ใหม่
    - test จาก task 1 encode พฤติกรรมที่คาดหวังไว้ — เมื่อ test ผ่าน แสดงว่า Expected Behavior ถูกต้อง
    - รัน bug condition exploration test จาก task 1
    - **EXPECTED OUTCOME**: Test PASSES (ยืนยันว่า icon ไม่ล้นกล่องแล้ว)
    - _Requirements: 2.1, 2.2, 2.3_

  - [x] 3.4 ยืนยันว่า preservation tests ยัง pass
    - **Property 2: Preservation** - Input นอกเงื่อนไขบั๊กไม่เปลี่ยนแปลง
    - **IMPORTANT**: รัน tests เดิมจาก task 2 ซ้ำ — ห้ามเขียน tests ใหม่
    - รัน preservation property tests จาก task 2
    - **EXPECTED OUTCOME**: Tests PASS (ยืนยันว่าไม่มี regression)
    - ยืนยันว่า icon failed คงกล่อง, dimmed row, พื้นหลัง/text-shadow, และ HUD อื่นยังทำงานเหมือนเดิมหลังแก้
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_

- [x] 4. Checkpoint - ยืนยันว่า tests ทั้งหมดผ่าน
  - รัน test suite ทั้งหมด (`npx vitest --run`) และยืนยันว่า Property 1 (Bug Condition/Expected Behavior) และ Property 2 (Preservation) ผ่านทั้งหมด
  - (Manual in-game) ยืนยันด้วยตาใน NUI จริงหลัง rebuild + deploy: เปิด `Rig_Menu` → icon เล็กสม่ำเสมอเรียงหน้าข้อความ ไม่ล้น ไม่ทับ label/owned หรือแถวข้างเคียง
  - สลับสถานะ (มีของ/ไม่มีของ/รูปโหลดไม่ได้) → layout คงเสถียร แถวไม่เลื่อน; ยืนยัน HUD อื่นใน bundle เดียวกันยังแสดงถูกต้อง
  - ถ้ามีคำถามหรือ test ใด fail โดยไม่คาดคิด ให้สอบถามผู้ใช้

## Notes

- Property 1 (Bug Condition → Expected Behavior หลังแก้) และ Property 2 (Preservation) ใช้ format `**Property N:**` เพื่อรองรับ hover status ตาม bug condition methodology
- exploration test (task 1) และ preservation test (task 2) เป็น standalone task และต้องอยู่ **ก่อน** implementation (task 3) เสมอ
- fix เป็น CSS-only ที่ source (`web/src/style.css`) ตามด้วยกระบวนการ deploy (rebuild → deploy `web/dist/` → restart) — ไม่แตะ DOM ของ `RigMenu.tsx`, Lua และ `fxmanifest.lua` ตามขอบเขตใน bugfix.md/design.md
- task 3.2 (rebuild + deploy) จำเป็นเพราะ FiveM โหลด bundle ที่ build แล้วจาก `web/dist/` ไม่ใช่ source โดยตรง (บทเรียนจาก spec `fishing-nui-bundle-rebuild-fix`)
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
