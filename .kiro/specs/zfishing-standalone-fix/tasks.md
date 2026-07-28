# Implementation Plan: zfishing-standalone-fix

## Overview

> **บริบทสำคัญ:** การเปลี่ยนแปลง 3 จุดตาม design.md (`zcore_lib/shared/runtime_profile.lua`, guarded bypass ใน `zcore_lib/shared/runtime.lua`, `zfishing/server/usable.lua` + `fxmanifest.lua`) **ถูก apply ไปแล้วและยืนยันว่าทำงานจริงในเกม** ทั้งฝั่ง dev (`e:\Web\ZCore`) และ deployed server งานในไฟล์นี้จึงเป็นการ **verify / formalize / อุดช่องว่าง / ตรวจ regression** ไม่ใช่ implement ใหม่จากศูนย์ ทุก task ที่การแก้มีอยู่แล้ว = ตรวจว่าตรง design และ complete/robust ไม่ใช่เขียนทับ

แผนงานนี้ยืนยัน hotfix ที่ทำไปแล้วให้ **robust และถาวรโดยไม่ต้องพึ่ง zpm** ตามลำดับ: เริ่มจาก structural verification ของ Bug Condition (Property 1) และ Preservation (Property 2) เป็น baseline → verify/finalize การแก้ทั้ง 3 ไฟล์ (พร้อมยืนยัน deployed copy ตรง dev) → re-check property → regression structural check → in-game smoke test → documentation operator note → checkpoint

**หมายเหตุการทดสอบ:** FiveM/Lua ไม่มี test runner ที่รันในสภาพแวดล้อมนี้ได้ (ต้องมี game/server runtime) ดังนั้น "property" ทั้งหมดในไฟล์นี้ยืนยันด้วย **structural / example verification (อ่านโค้ด) + in-game smoke test** ไม่ใช่ automated unit/property test — **ห้ามสร้าง Lua test harness ขึ้นมาใหม่** โฟกัสหลักที่ qbcore + qb-inventory; qbox/esx เป็น best-effort ที่มีในโค้ดแล้ว

## Tasks

- [x] 1. ตรวจ Bug Condition (structural verification บน F เทียบ F')
  - **Property 1: Bug Condition** - Standalone profile พร้อมใช้งาน + เบ็ดมี useable callback
  - **CONTEXT**: fix ถูก apply แล้ว งานนี้คือยืนยันว่า counterexample เดิม (บน F) ถูกแก้จริงบน F' ด้วยการอ่านโค้ด ไม่ใช่รัน automated test
  - **GOAL**: บันทึก counterexample ที่พิสูจน์บั๊กเดิม แล้วยืนยันว่า F' แก้ครบทั้ง 2 root cause
  - **Root cause A (`isBugConditionA`)**: บน F `ZLib.RuntimeProfile = nil` → `validateProfile` คืน `PROFILE_UNAVAILABLE` → `_checkHealth` fail → facade fail-closed → `Zfishing.Blocked()` = true (counterexample: server log `[zcore_lib] STARTUP HEALTH FAILED [PROFILE_UNAVAILABLE]`, `[zfishing] ... fishing disabled`)
  - **Root cause B (`isBugConditionB`)**: บน F เบ็ด `useable = true` แต่ไม่มี `CreateUseableItem` callback ผูก framework → กดเบ็ดขึ้น "Used" เฉย ๆ; register ผ่าน bridge คืน `[UNSUPPORTED_FIELD] item and callback are required` (function ref หายข้าม resource boundary)
  - ตรวจว่า F' แก้ A: `runtime_profile.lua` เป็น local profile `unlocked = true` + `validateProfile`/`_checkHealth` unlocked branch ผ่าน health check โดยข้าม lock/evidence/capability gates
  - ตรวจว่า F' แก้ B: `server/usable.lua` ลงทะเบียนเบ็ดทุกตัวจาก `Config.Equipment.rods` ผ่าน direct framework hook ด้วย local callback `onRodUsed` → `TriggerClientEvent('zfishing:client:useRod', source, item)`
  - **EXPECTED OUTCOME**: บน F ทั้ง 2 condition FAIL (พิสูจน์บั๊กมีจริง); บน F' ทั้ง 2 condition PASS (โครงสร้างโค้ดตรง Property 1/2 ของ design)
  - บันทึก counterexample ที่พบเพื่อ traceability
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6_

- [x] 2. ตรวจ Preservation (structural verification — ไม่มี diff นอก scope)
  - **Property 2: Preservation** - zpm-locked path + zfishing surface ไม่เปลี่ยน
  - **METHODOLOGY**: observation-first ด้วยการอ่านโค้ด — ยืนยันว่า guard `if profile.unlocked == true then ... end` ครอบเฉพาะ unlocked branch และ locked branch เดิมไม่มีบรรทัดใดถูกแก้
  - สังเกต locked path ใน `runtime.lua`: `validateProfile` (ส่วน schema/digest/adapter-SUPPORTED/evidence), `_checkHealth` (evidence-vs-live matching loop), `capabilityVerified` (locked → `state == 'verified'`) — ต้อง byte-for-byte เหมือนเดิมนอกเหนือจาก unlocked branch ที่เติมเข้าไปก่อน gate
  - สังเกต zfishing surface: server callback/event (`zfishing:cast`, `zfishing:cancel`, `zfishing:sellAll`, `zfishing:reportWeather`, hook/claim/reel), `session.lua` anti-cheat (server-side roll, timing plausibility, rate limit), bridge inventory ops (HasItem, ItemCount, Search, GetSlot, SetSlotMeta, AddItem, RemoveItem, AddMoney, Notify), Prompt HUD (spec `fishing-prompt-hud`), client `startRodUse`/`exports('useRod', ...)`/`RegisterNetEvent('zfishing:client:useRod', ...)` — ต้องไม่มี diff เลย
  - ยืนยันว่า fix แตะเฉพาะ: `runtime_profile.lua` (ทั้งไฟล์ = config), unlocked branch ใน `runtime.lua`, `server/usable.lua` (ไฟล์ใหม่), 1 บรรทัดใน `fxmanifest.lua`
  - **EXPECTED OUTCOME**: locked path + zfishing surface ทั้งหมดไม่เปลี่ยน (PASS) — pre-existing baseline คงไว้
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6_

- [x] 3. Verify/finalize การแก้ที่ apply แล้ว (formalize ให้ครบและถาวร)

  - [x] 3.1 Verify/finalize `zcore_lib/shared/runtime_profile.lua` (operator-owned config)
    - ยืนยัน field ครบตาม design File 1: `unlocked = true`, `mode = 'enhanced-rig'`, `framework = { id='qbcore', resource='qb-core', version='local' }`, `inventory = { id='qb-inventory', resource='qb-inventory', version='local' }`, และ cosmetic fields (`schema`, `digest`, `adapter{...}`, `capabilities={}`, `runtimeEvidence={resources={}}`)
    - ยืนยัน comment/คำเตือนหัวไฟล์ระบุว่าเป็น operator-owned + วิธี retarget framework/inventory (มีอยู่แล้ว — ตรวจว่าครบและชัด)
    - ยืนยัน field ทั้งหมดที่ `validateProfile` unlocked branch อ่านครบ (mode, framework.id, framework.resource, inventory.id, inventory.resource เมื่อ ≠ esx-native) — ไม่ให้เกิด `PROFILE_INVALID`
    - **ยืนยัน deployed copy ตรงกับ dev**: เทียบไฟล์ที่ deploy `zcore_lib` (`...\txData\...\resources\...`) ให้ field ตรง dev — ถ้าไม่ตรงคือช่องว่าง ต้อง sync
    - _Bug_Condition: isBugConditionA(profile) — profile=nil OR (unlocked=true AND profileFieldsIncomplete)_
    - _Expected_Behavior: validateProfile(unlocked) → nil เมื่อ field ครบ; GetProfile() → ok=true_
    - _Requirements: 2.1, 2.2_

  - [x] 3.2 Verify/finalize guarded bypass 3 จุดใน `zcore_lib/shared/runtime.lua`
    - ยืนยัน `validateProfile`: unlocked branch ตรวจแค่ mode/framework.id/framework.resource/inventory.id (+inventory.resource เมื่อ ≠ esx-native) แล้ว `return nil`; ข้าม schema/digest/adapter-SUPPORTED/evidence — และ locked path ด้านล่างไม่ถูกแตะ
    - ยืนยัน `_checkHealth`: unlocked branch ข้าม evidence-vs-live version matching แต่ยัง `getResourceState` framework (+non-esx inventory) resource; ไม่ `started` → `RUNTIME_PROFILE_MISMATCH` (fail-closed คงไว้); ครบ → `ready = true`
    - ยืนยัน `capabilityVerified`: unlocked → `return true`; locked → logic เดิม (`state == 'verified'` + `selectedProvider`)
    - ยืนยันว่า guard ทั้ง 3 จุด scope เฉพาะ `profile.unlocked == true` เท่านั้น (path ไม่ unlocked ไหลลง logic เดิมทุกบรรทัด — Property 3)
    - _Bug_Condition: isBugConditionA(profile)_
    - _Expected_Behavior: _checkHealth'(unlocked, frameworkStarted) → ok=true; ไม่ started → RUNTIME_PROFILE_MISMATCH_
    - _Preservation: locked path เดิมไม่เปลี่ยน (Property 3)_
    - _Requirements: 2.1, 2.3, 3.1, 3.2_

  - [x] 3.3 Verify/finalize `zfishing/server/usable.lua` + `fxmanifest.lua`
    - ยืนยัน `onRodUsed(source, item)` → `TriggerClientEvent('zfishing:client:useRod', source, item)` (ส่ง slot ให้ enhanced-rig อ่าน components)
    - ยืนยัน diagnostic probe ผ่าน bridge ครั้งเดียว (log error code จริง) แต่ **ไม่พึ่งพา** — bridge คืน `ok` ก็ใช้ต่อได้ (forward-compat)
    - ยืนยัน primary/fallback register: รอ framework `started` (poll ≤ 100×100ms) แล้ว `directRegister` ต่อ rod — QBCore `exports['qb-core']:GetCoreObject().Functions.CreateUseableItem`, QBox `exports.qbx_core:CreateUseableItem`, ESX `exports.es_extended:getSharedObject().RegisterUsableItem`
    - ยืนยัน `directRegister` ใช้ `pcall` (fail isolation ต่อ rod) และ log `usable rods registered via direct framework hook` เมื่อครบทุก rod
    - ยืนยัน `fxmanifest.lua` มี `'server/usable.lua'` ใน `server_scripts` หลัง `'server/session.lua'`
    - **ยืนยัน client ไม่ถูกแตะ**: `startRodUse` / `exports('useRod', ...)` / `RegisterNetEvent('zfishing:client:useRod', ...)` normalize ทั้ง slot table (ox) และ slot number (framework-native) อยู่แล้ว
    - **ยืนยัน deployed copy ตรงกับ dev**: เทียบ `...\resources\[zlab]\zfishing\server\usable.lua` + `fxmanifest.lua` กับ dev
    - _Bug_Condition: isBugConditionB(rodName) — NOT frameworkHasUsableCallback(rodName)_
    - _Expected_Behavior: ทุก rodName ใน Config.Equipment.rods → registered + ใช้แล้ว trigger 'zfishing:client:useRod' with item(slot); probe fail ไม่ทำให้ register ล้มทั้งหมด_
    - _Requirements: 2.4, 2.5, 2.6_

  - [x] 3.4 ยืนยัน Bug Condition ถูกแก้ (re-check Property 1)
    - **Property 1: Expected Behavior** - Standalone profile พร้อม + เบ็ด trigger การตกปลา
    - **IMPORTANT**: re-run structural check เดียวกับ task 1 บน F' — ไม่เขียน check ใหม่
    - ยืนยัน: unlocked profile ครบ field + `qb-core` started → `_checkHealth` `ok=true` → `Zfishing.Blocked()` false → `zfishing:cast` และ `/fishrig` ทำงาน
    - ยืนยัน: ทุก rod ใน `Config.Equipment.rods` มี direct framework callback → กดใช้ → `zfishing:client:useRod` with item(slot)
    - **EXPECTED OUTCOME**: Property 1 PASS (structural) — ยืนยัน in-game ใน task 5
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6_

  - [x] 3.5 ยืนยัน Preservation ยังคงอยู่ (re-check Property 2)
    - **Property 2: Preservation** - locked path + zfishing surface ไม่ regress
    - **IMPORTANT**: re-run structural check เดียวกับ task 2 — ไม่เขียน check ใหม่
    - ยืนยัน locked branch ใน `validateProfile`/`_checkHealth`/`capabilityVerified` ไม่มี diff, zfishing callbacks/`session.lua`/bridge ops/Prompt HUD/client ไม่มี diff
    - **EXPECTED OUTCOME**: Property 2 PASS (ไม่มี regression)
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6_

- [x] 4. Regression / structural verification (Property 4 — zfishing surface เดิม)
  - ยืนยัน signature + lifecycle ของ server callback/event: `zfishing:cast`, `zfishing:cancel`, `zfishing:sellAll`, `zfishing:reportWeather`, hook/claim/reel — ไม่เปลี่ยน
  - ยืนยัน `server/session.lua` anti-cheat (server-side roll, timing plausibility, rate limit) — ไม่ถูกแก้
  - ยืนยัน bridge inventory ops คืน structured envelope เดิมและทำงานกับ qb-inventory: HasItem, ItemCount, Search, GetSlot, SetSlotMeta, AddItem, RemoveItem, AddMoney, Notify
  - ยืนยัน Prompt HUD (spec `fishing-prompt-hud`) ไม่ถูกกระทบ
  - _Requirements: 3.3, 3.4, 3.5, 3.6_

- [x] 5. In-game smoke test checklist (QBCore + qb-inventory จริง)
  - **Log markers (server console)** ต้องเห็นทั้งสอง:
    - `[zfishing] runtime mode = enhanced-rig (qbcore + qb-inventory)`
    - `[zfishing] usable rods registered via direct framework hook`
  - **ใช้เบ็ด**: กดใช้เบ็ดจาก inventory → prop เบ็ดออก + เข้าสู่ standby/charge/cast (ตกปลาได้) — ทั้งทาง ox export และ framework-native event
  - **`/fishrig`**: เห็นเบ็ดในช่องจริงพร้อม components (ไม่ขึ้น "ช่องนี้ไม่มีเบ็ด")
  - **Regression in-game**: cancel (X), sell NPC, Prompt HUD แสดง/ซ่อน, weather report — ทำงานตามเดิม
  - **Fail-closed check**: ตั้ง framework/inventory resource ผิด (ไม่ `started`) → เห็น `RUNTIME_PROFILE_MISMATCH` (ไม่เงียบ ๆ ไม่ทำงาน)
  - _Requirements: 2.1, 2.3, 2.4, 2.5, 2.6, 3.2, 3.6_

- [x] 6. Documentation — operator note (README / deploy note)
  - บันทึกว่า `zcore_lib/shared/runtime_profile.lua` เป็น **operator-owned config** — เมื่ออัปเดตด้วยการก๊อปโฟลเดอร์ทับ **ต้องไม่ทับไฟล์นี้** (ไม่งั้นกลับไปเจอ Root cause A); แนะนำสำรองก่อนอัปเดตทุกครั้ง
  - บันทึกวิธี retarget: `framework.id` (`'qbcore'`|`'qbox'`|`'esx'`), `inventory.id` (`'qb-inventory'`|`'ox_inventory'`|`'esx-native'`); enhanced-rig ต้องใช้ inventory ที่เก็บ metadata ได้; `esx-native` ให้พิจารณา `mode = 'simple-fishing'`
  - ระบุว่า fix โฟกัส qbcore + qb-inventory; qbox/esx เป็น best-effort ที่มีในโค้ดแล้ว
  - _Requirements: 3.7_

- [x] 7. Checkpoint - ยืนยันการ verify ครบ
  - ยืนยัน Property 1–4 ผ่าน (structural), smoke test checklist ครบ, deployed copies ตรง dev, และเอกสาร operator note พร้อม
  - Ensure all checks pass, ask the user if questions arise.

## Notes

- FiveM/Lua ไม่มี test runner ในสภาพแวดล้อมนี้ — ทุก "Property" ยืนยันด้วย structural/example verification (อ่านโค้ด) + in-game smoke test เท่านั้น ห้ามสร้าง Lua test harness ใหม่
- fix ถูก apply แล้วและยืนยันในเกม — task ทั้งหมดเป็นการ verify/finalize ไม่ใช่ re-implement; ที่การแก้มีอยู่แล้วให้ตรวจความครบถ้วน/ตรง design ไม่ใช่เขียนทับ
- `runtime_profile.lua` เป็น operator-owned config: อย่าเขียนทับด้วยค่า generic; task 3.1 ต้องยืนยัน deployed copy ตรง dev
- Property 1 (Bug Condition/Expected Behavior) และ Property 2 (Preservation) ใช้ format `**Property N:**` เพื่อรองรับ hover status ตาม bug condition methodology
- แต่ละ task อ้างอิง Correctness Property (design.md) + acceptance criteria (bugfix.md) เพื่อ traceability

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1", "2"] },
    { "id": 1, "tasks": ["3.1", "3.2", "3.3"] },
    { "id": 2, "tasks": ["3.4", "3.5"] },
    { "id": 3, "tasks": ["4"] },
    { "id": 4, "tasks": ["5"] },
    { "id": 5, "tasks": ["6", "7"] }
  ]
}
```
