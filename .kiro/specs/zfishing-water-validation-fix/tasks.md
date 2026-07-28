# Implementation Plan: zfishing-water-validation-fix

## Overview

แผนงานนี้แก้ bug ที่ผู้เล่นสามารถขว้างเบ็ด/เริ่ม session ตกปลาได้ทั้งที่ไม่ได้อยู่ใกล้น้ำจริง โดยใช้ bug condition methodology ตามลำดับ: เขียน exploration test (Property 1) ยืนยันว่า bug มีจริงบนโค้ดที่ยังไม่แก้ → เขียน preservation test (Property 2) จับ baseline behavior → apply fix ใน `startFishing()` (re-check `nearWater()` ณ จังหวะ cast) → ยืนยัน Property 1 pass และ Property 2 ไม่ regress → checkpoint

**หมายเหตุด้านการทดสอบ:** โค้ดนี้เป็น FiveM client Lua ที่พึ่ง natives (`TestProbeAgainstWater`, `GetEntityCoords` ฯลฯ) ตาม Testing Strategy ใน design ต้อง **แยก decision logic ออกจาก natives** โดย mock/stub ค่า `nearWater()` และ state `ZClient` เพื่อทดสอบ decision gate ได้แบบ deterministic ส่วนการตรวจ integration ในเกมจริงทำแบบ manual (task 4)

## Tasks

- [x] 1. เขียน bug condition exploration test (ก่อนแก้โค้ด)
  - **Property 1: Bug Condition** - ปฏิเสธการ cast เมื่อไม่ได้อยู่ใกล้น้ำจริง
  - **CRITICAL**: test นี้ต้อง FAIL บนโค้ดที่ยังไม่แก้ — การ fail ยืนยันว่า bug มีอยู่จริง
  - **DO NOT attempt to fix the test or the code when it fails** — ปล่อยให้มัน fail เพื่อยืนยัน root cause
  - **NOTE**: test นี้ encode พฤติกรรมที่คาดหวังไว้ — เมื่อมัน pass หลังแก้ จะเป็นตัว validate การแก้ไข
  - **GOAL**: สร้าง counterexample ที่แสดงว่า bug เกิดจริง (cast callback `zfishing:cast` ถูกเรียกทั้งที่ `nearWater() == false`)
  - **Scoped PBT Approach**: เนื่องจากเป็น decision gate แบบ deterministic ให้ scope property ไปที่ case ที่ชัดเจน — สำหรับทุกค่า power ที่ valid เมื่อ `active=true`, `castAttempt=true`, และ `nearWater(ณ cast)=false` ผลลัพธ์ต้องคือ "ปฏิเสธการ cast"
  - แยก decision logic ออกจาก natives โดย mock/stub ค่า `nearWater()` และ state `ZClient` เพื่อให้ทดสอบได้แบบ deterministic (ไม่ต้องรันในเกมจริง)
  - จำลอง input ตาม `isBugCondition(input)` จาก design: `playerState.active == true` AND `castAttempt == true` AND `playerState.nearWater == false` (ผ่าน gate `startRodUse` มาแล้วเพราะตอนหยิบเบ็ด near=true)
  - assertion ต้องตรงกับ Expected Behavior (Property 1): `castCallbackInvoked == false`, `sessionStarted == false`, `notified == 'need_water'`, `stateClean == true` (`ZClient.active == false`)
  - Test Cases จาก design: (1) ยืนบนบกใน zone แล้วขว้าง, (2) หันหน้าออกจากน้ำก่อนขว้าง, (3) เดินออกไประหว่าง standby แล้วขว้าง, (4) edge — ยืนคาบเส้นขอบน้ำ
  - รัน test บนโค้ดที่ยังไม่แก้
  - **EXPECTED OUTCOME**: Test FAILS (ถูกต้อง — พิสูจน์ว่า bug มีอยู่จริง เพราะ `startFishing()` ยิง cast callback ทั้งที่ `nearWater()==false`)
  - Document counterexamples ที่พบเพื่อเข้าใจ root cause (เช่น "cast callback ถูกเรียกเมื่อ active=true, nearWater(cast)=false, power=valid")
  - ทำเครื่องหมาย task เสร็จเมื่อ test ถูกเขียน, รัน, และ documented การ fail แล้ว
  - _Requirements: 1.1, 1.2, 2.1, 2.2_

- [x] 2. เขียน preservation property tests (ก่อนแก้โค้ด)
  - **Property 2: Preservation** - พฤติกรรมของ input ที่ไม่เข้าเงื่อนไข bug ต้องไม่เปลี่ยน
  - **IMPORTANT**: ใช้ observation-first methodology — สังเกตพฤติกรรมโค้ดเดิมก่อน แล้วจึงเขียน test จับพฤติกรรมนั้น
  - สังเกตบนโค้ดที่ยังไม่แก้สำหรับ input ที่ `isBugCondition` คืนค่า false:
    - `nearWater(ณ cast) == true` → `startFishing()` ยิง cast callback และเริ่ม session ได้ตามปกติ
    - `startRodUse` gate: ไม่ใกล้น้ำ → ปฏิเสธด้วย `need_water`; ไม่อยู่ใน zone (Config.RequireZone เปิด) → ปฏิเสธด้วย `no_fish_here`
    - หลัง cast สำเร็จ: การคำนวณ power, `Casting.SpawnFloat`, ลำดับ bite/hook/reel ทำงานเหมือนเดิม
    - กด cancel (X) ทุกเฟส → ยกเลิกและ cleanup ได้ปกติ
  - เขียน property-based test จับพฤติกรรมที่สังเกตได้จาก Preservation Requirements: สำหรับทุก input ที่ NOT `isBugCondition(input)` ผลลัพธ์ของโค้ดที่แก้แล้ว SHALL เท่ากับโค้ดเดิม
  - property-based testing generate test case จำนวนมากอัตโนมัติ (สุ่ม `active`, `nearWater ณ startRodUse`, `nearWater ณ cast`, `inZone`, เฟส) เพื่อการรับประกันที่แข็งแรง และครอบคลุม false-positive check (ไม่มี input ที่ `nearWater ณ cast == true` แต่ถูกปฏิเสธผิดพลาด)
  - รัน tests บนโค้ดที่ยังไม่แก้
  - **EXPECTED OUTCOME**: Tests PASS (ยืนยัน baseline behavior ที่ต้องคงไว้)
  - ทำเครื่องหมาย task เสร็จเมื่อ tests ถูกเขียน, รัน, และ pass บนโค้ดที่ยังไม่แก้แล้ว
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_

- [x] 3. Fix สำหรับ bug: ตรวจ `nearWater()` ซ้ำ ณ จังหวะ cast

  - [x] 3.1 Implement the fix ใน `startFishing()`
    - แก้ที่ไฟล์ `client/main.lua` ฟังก์ชัน `startFishing()`
    - เพิ่มการ re-check `nearWater()` หลังจาก `Casting.Charge()` คืน power ที่ valid แล้ว และ **ก่อน** ยิง `lib.callback.await('zfishing:cast', ...)`
    - ถ้า `nearWater() == false` ให้เรียก `cleanup('need_water', 'error')` แล้ว `return` ออกจาก `startFishing()` ทันที (ไม่ยิง cast callback)
    - ใช้ locale key เดิม `need_water` (เดียวกับ gate ใน `startRodUse`) ไม่เพิ่ม key ใหม่
    - ใช้ `cleanup` (ไม่ใช่แค่ notify) เพื่อคืนสถานะ `ZClient.active`, หยุด anim, ปลด freeze, ซ่อน UI ให้สะอาด ป้องกันสถานะค้าง
    - ไม่แตะ `nearWater()`, `currentZone()`, `startRodUse`, cast callback ฝั่ง server, กลไก bite/reel หรือ cancel
    - _Bug_Condition: isBugCondition(input) where playerState.active==true AND castAttempt==true AND playerState.nearWater==false (จาก design)_
    - _Expected_Behavior: expectedBehavior(result) — ปฏิเสธ cast, ไม่เริ่ม session, notify 'need_water', คืนสถานะสะอาดผ่าน cleanup (จาก design)_
    - _Preservation: Preservation Requirements จาก design (คงพฤติกรรมขว้างเบ็ดใกล้น้ำ, gate ตอนหยิบเบ็ด, charge/float/bite/reel, cancel)_
    - _Requirements: 2.1, 2.2, 3.1, 3.2, 3.3, 3.4, 3.5_

  - [x] 3.2 ยืนยันว่า bug condition exploration test ผ่านแล้ว
    - **Property 1: Expected Behavior** - ปฏิเสธการ cast เมื่อไม่ได้อยู่ใกล้น้ำจริง
    - **IMPORTANT**: รัน test เดิมจาก task 1 ซ้ำ — ห้ามเขียน test ใหม่
    - test จาก task 1 encode พฤติกรรมที่คาดหวังไว้ เมื่อมัน pass แสดงว่า Expected Behavior ถูกต้อง
    - รัน bug condition exploration test จาก task 1
    - **EXPECTED OUTCOME**: Test PASSES (ยืนยันว่า bug ถูกแก้แล้ว)
    - _Requirements: 2.1, 2.2_

  - [x] 3.3 ยืนยันว่า preservation tests ยัง pass
    - **Property 2: Preservation** - พฤติกรรมของ input ที่ไม่เข้าเงื่อนไข bug ต้องไม่เปลี่ยน
    - **IMPORTANT**: รัน tests เดิมจาก task 2 ซ้ำ — ห้ามเขียน tests ใหม่
    - รัน preservation property tests จาก task 2
    - **EXPECTED OUTCOME**: Tests PASS (ยืนยันว่าไม่มี regression)
    - ยืนยันว่า tests ทั้งหมดยัง pass หลังแก้ (ไม่มี regression)
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_

- [x] 4. Checkpoint - ยืนยันว่า tests ทั้งหมดผ่าน
  - รัน test suite ทั้งหมด ยืนยันว่า Property 1 (Bug Condition/Expected Behavior) และ Property 2 (Preservation) ผ่านทั้งหมด
  - (Manual in-game) integration test ตาม design: full flow ปกติต้องผ่าน, bug scenario (หยิบเบ็ดริมน้ำ → เดินขึ้นบกใน zone → ขว้าง) ต้องถูกปฏิเสธพร้อม `need_water` และคืนสถานะสะอาด, ตรวจ prompt/HUD ถูกซ่อนและ ped ไม่ freeze ค้าง, cancel ทุกเฟสยังทำงาน
  - ถ้ามีคำถามหรือ test ใด fail โดยไม่คาดคิด ให้สอบถามผู้ใช้

## Notes

- Property 1 (Bug Condition → Expected Behavior หลังแก้) และ Property 2 (Preservation) ใช้ format `**Property N:**` เพื่อรองรับ hover status ตาม bug condition methodology
- exploration test (task 1) และ preservation test (task 2) เป็น standalone task และต้องอยู่ **ก่อน** implementation (task 3) เสมอ
- FiveM client Lua พึ่ง natives — ตาม design ต้อง mock/stub `nearWater()` และ `ZClient` เพื่อทดสอบ decision gate แบบ deterministic; integration ในเกมจริงทำ manual ที่ task 4
- fix เป็น minimal client-side gate จุดเดียวใน `startFishing()` ไม่แตะ logic ฝั่ง server ตามขอบเขตที่ยืนยันใน bugfix.md
- แต่ละ task อ้างอิง Correctness Property (design.md) + acceptance criteria (bugfix.md) เพื่อ traceability

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1", "2"] },
    { "id": 1, "tasks": ["3.1"] },
    { "id": 2, "tasks": ["3.2", "3.3"] },
    { "id": 3, "tasks": ["4"] }
  ]
}
```
