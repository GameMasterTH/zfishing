# zfishing-standalone-fix Bugfix Design

## Overview

บั๊กนี้ทำให้ระบบตกปลา (`zfishing`) ใช้งานไม่ได้เลยบน QBCore + qb-inventory เมื่อ deploy ด้วยวิธีก๊อปโฟลเดอร์ทับ (`zfishing` + `zcore_lib`) โดยไม่มี zpm/Site Agent มา generate runtime profile ทับให้ อาการคือกดใช้เบ็ดแล้วขึ้น "Used" เฉย ๆ ไม่มี prop เบ็ด เริ่มตกปลาไม่ได้ และ `/fishrig` แจ้งว่า "ช่องนี้ไม่มีเบ็ด"

เอกสารนี้ **formalize hotfix ที่ทำไปแล้วและยืนยันว่าใช้งานได้จริง** (server console แสดง `runtime mode = enhanced-rig (qbcore + qb-inventory)` และ `usable rods registered via direct framework hook`) เป้าหมายไม่ใช่คิดวิธีใหม่ แต่คือทำให้ fix เดิม **robust และถาวร โดยไม่ต้องพึ่ง zpm เลย** โดยโฟกัสหลักที่ qbcore + qb-inventory ส่วน qbox/esx เป็น best-effort ที่มีอยู่ในโค้ดอยู่แล้ว

fix ประกอบด้วย 3 การเปลี่ยนแปลงที่มีอยู่จริงแล้วในโค้ด:

1. `zcore_lib/shared/runtime_profile.lua` — เปลี่ยนจาก placeholder `ZLib.RuntimeProfile = nil` เป็น local profile table ที่ `unlocked = true` (operator-owned config)
2. `zcore_lib/shared/runtime.lua` — เพิ่ม guarded bypass 3 จุด เฉพาะเมื่อ `profile.unlocked == true` (path zpm-locked เดิมไม่แตะ)
3. `zfishing/server/usable.lua` — ลงทะเบียนเบ็ดเป็น useable item โดยตรงกับ framework ด้วย local callback (ไม่ผ่าน bridge)

## Glossary

- **Bug_Condition (C)**: เงื่อนไขที่ทำให้เกิดบั๊ก แยกเป็น 2 จุดตาม root cause — `C_A` (profile ไม่พร้อมทั้งที่ operator ต้องการ standalone) และ `C_B` (เบ็ด useable แต่ไม่มี callback ผูกกับ framework)
- **Property (P)**: พฤติกรรมที่ถูกต้องเมื่อ bug condition เป็นจริง — `zcore_lib` พร้อมใช้งาน (fishing enabled) และกดเบ็ดแล้ว trigger การตกปลาจริง
- **Preservation**: พฤติกรรมเดิมที่ต้องคงไว้ — zpm-locked validation path, signatures ของ callback/event ใน zfishing, anti-cheat ใน session.lua, Prompt HUD, client `startRodUse`
- **F / F'**: โค้ดก่อนแก้ (placeholder profile + ไม่มี usable registration ที่ทำงาน) / โค้ดหลังแก้
- **unlocked profile**: `ZLib.RuntimeProfile` ที่ตั้ง `unlocked = true` เป็น operator opt-out จาก zpm lock (ข้าม digest/evidence/capability gates แต่ยังใช้ adapter operations ชุดเดียวกัน)
- **enhanced-rig**: โหมด `mode = 'enhanced-rig'` ที่ zfishing รองรับ metadata-aware rod assembly (ต้องการ inventory ที่เก็บ metadata ได้ เช่น qb-inventory)
- **bridge**: `exports.zcore_lib:*` — structured-envelope facade ที่ zfishing เรียกใช้สำหรับ read/write ops (GetProfile, HasItem, GetSlot, AddItem ฯลฯ)
- **direct framework hook**: การเรียก `CreateUseableItem`/`RegisterUsableItem` บน framework export โดยตรงจากภายใน zfishing โดยไม่ส่ง callback ข้าม resource boundary

## Bug Details

### Bug Condition

บั๊กมาจาก 2 root cause ที่แยกกันชัดเจน จึงมี 2 bug condition:

**Root cause A — `zcore_lib` fail-closed เพราะไม่มี runtime profile:** `runtime_profile.lua` เดิมเป็น placeholder `ZLib.RuntimeProfile = nil` ที่ zpm ต้อง generate ทับตอน deploy การก๊อปโฟลเดอร์ dev ทับทำให้ profile หาย → `validateProfile` คืน `PROFILE_UNAVAILABLE` → startup health check fail → facade ปิดตัวเอง fail-closed → `Zfishing.Blocked()` เป็น true → ตกปลาไม่ได้และ `/fishrig` อ่านช่องเบ็ดไม่ได้

**Root cause B — usable rod ไม่ถูกลงทะเบียน (callback หายข้าม resource boundary):** เบ็ดตั้ง `useable = true`/`client.export` แต่ฝั่ง framework-native ยังต้องมี `CreateUseableItem(name, callback)` การลงทะเบียนผ่าน bridge `exports.zcore_lib:RegisterUsableItem(name, callback)` ล้มเหลวเพราะ FiveM exports ไม่ preserve function reference ข้าม resource — `_registerUsable` เห็น `type(callback) ~= 'function'` แล้วคืน `UNSUPPORTED_FIELD`

**Formal Specification:**
```
FUNCTION isBugConditionA(profile)
  INPUT: profile of type RuntimeProfile (ค่าใน ZLib.RuntimeProfile)
  OUTPUT: boolean

  // buggy เมื่อ operator ตั้งใจใช้ standalone แต่ profile หาย/ไม่ครบ
  // ทำให้ระบบ fail-closed ทั้งที่ควรทำงานได้
  RETURN (profile = nil)
      OR (profile.unlocked = true AND profileFieldsIncomplete(profile))
END FUNCTION

FUNCTION isBugConditionB(rodName)
  INPUT: rodName of type string (คีย์ใน Config.Equipment.rods)
  OUTPUT: boolean

  // buggy เมื่อเบ็ด useable แต่ไม่มี useable-item callback ผูกกับ framework
  RETURN NOT frameworkHasUsableCallback(rodName)
END FUNCTION
```

### Examples

- **A:** `runtime_profile.lua` เป็น `ZLib.RuntimeProfile = nil` → log `[zcore_lib] STARTUP HEALTH FAILED [PROFILE_UNAVAILABLE]` + `[zfishing] runtime profile unavailable [STARTUP_HEALTH_FAILED] ... fishing disabled` (คาดหวัง: profile พร้อม, `runtime mode = enhanced-rig (qbcore + qb-inventory)`)
- **A:** profile `unlocked = true` แต่ขาด `framework.resource` → `PROFILE_INVALID` (คาดหวัง: `PROFILE_INVALID` ถูกต้อง เพราะ fields ไม่ครบจริง — ต้องเติมให้ครบ ไม่ใช่ bypass มั่ว)
- **B:** ผู้เล่นกดใช้ `fishing_rod_common` → ขึ้น "Used" แต่ไม่มีอะไรเกิดขึ้น (คาดหวัง: trigger `zfishing:client:useRod` → prop เบ็ดออก + เริ่มตกปลา)
- **B:** zfishing เรียก `exports.zcore_lib:RegisterUsableItem(name, callback)` → `[UNSUPPORTED_FIELD] item and callback are required` (คาดหวัง: ลงทะเบียนผ่าน direct framework hook สำเร็จ, log `usable rods registered via direct framework hook`)
- **Edge (A):** profile `unlocked = true` ครบทุก field แต่ `qb-core` ยังไม่ `started` → คาดหวัง fail-closed ด้วย `RUNTIME_PROFILE_MISMATCH` (ไม่ silently no-op)

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors (ต้องคงไว้เป๊ะ):**
- zpm-locked validation path เดิม (`unlocked` ไม่ได้เป็น true) ต้องบังคับ lock digest / evidence-version / capability-verification gates ครบทุกจุดตามเดิม
- signature และ lifecycle ของ server callback/event ของ zfishing (`zfishing:cast`, `zfishing:cancel`, `zfishing:sellAll`, `zfishing:reportWeather`) ต้องไม่เปลี่ยน
- server-side validation / anti-cheat ใน `session.lua` (server-side roll, timing plausibility, rate limit) ต้องไม่ถูกแก้
- bridge read/write ops (HasItem, ItemCount, Search, GetSlot, SetSlotMeta, AddItem, RemoveItem, AddMoney, Notify) ต้องคืน structured envelope เดิมและทำงานกับ qb-inventory ตามปกติ
- Prompt HUD (spec `fishing-prompt-hud`) ต้องทำงานได้ตามเดิม
- client `startRodUse` + `exports('useRod', ...)` + `RegisterNetEvent('zfishing:client:useRod', ...)` ต้องไม่ถูกแตะ

**Scope:**
ทุก input ที่ **ไม่เข้า** `isBugConditionA` หรือ `isBugConditionB` ต้องไม่ถูกกระทบจาก fix นี้เลย ได้แก่:
- profile ที่เป็น zpm-locked จริง (locked path)
- server callback/event ทุกตัวของ zfishing (เส้นทางการตกปลาหลัง profile พร้อม)
- inventory operations ทั้งหมดที่วิ่งผ่าน bridge

## Hypothesized Root Cause

Root cause ยืนยันแล้วจาก source + log จริง (hotfix ทำงานได้) แยกเป็น 2 จุด:

1. **Profile availability (A)**: `runtime_profile.lua` เป็น placeholder `nil` ที่ออกแบบมาให้ zpm generate ทับ เมื่อ deploy แบบก๊อปโฟลเดอร์โดยไม่มี zpm จึงไม่มี profile → `validateProfile` คืน `PROFILE_UNAVAILABLE` → `_checkHealth` fail → `_requireReady` ปิด facade → `Zfishing.Blocked()` true
   - เส้นทางเดิมออกแบบให้ fail-closed อย่างตั้งใจ (safety) แต่ไม่มีทาง opt-out สำหรับ operator ที่ต้องการ standalone

2. **Usable callback cross-resource (B)**: `_registerUsable` ตรวจ `type(callback) ~= 'function'` และคืน `UNSUPPORTED_FIELD` เพราะ FiveM exports ส่ง function reference ข้าม resource ไม่ได้ — bridge ใช้ได้กับ read ops (string เข้า / table ออก) แต่ไม่เหมาะกับ register-callback
   - แก้โดยลงทะเบียน callback ภายใน resource เดียวกัน (zfishing) ตรงกับ framework export

## Correctness Properties

Property 1: Bug Condition A — Standalone profile ทำให้ระบบพร้อมใช้งาน

_For any_ profile ที่ `unlocked = true` และมี `mode`, `framework.id`, `framework.resource`, `inventory.id` (และ `inventory.resource` เมื่อ inventory ไม่ใช่ `esx-native`) ครบถ้วน และ framework resource อยู่ในสถานะ `started` — fixed `_checkHealth`/`validateProfile` SHALL ผ่าน health check (`health.ok = true`) โดยข้าม lock digest / evidence-version / capability-verification gates และ `Zfishing.Blocked()` SHALL เป็น false ทำให้ callback `zfishing:cast` และ lifecycle การตกปลาทำงานได้ รวมถึง `/fishrig` อ่านช่องเบ็ดจริงได้

**Validates: Requirements 2.1, 2.2, 2.3, 2.4**

Property 2: Bug Condition B — เบ็ดทุกตัวมี useable callback ผูกกับ framework โดยตรง

_For any_ `rodName` ที่เป็นคีย์ใน `Config.Equipment.rods` — หลังรัน registration ใน `server/usable.lua` (F') เบ็ดตัวนั้น SHALL ถูกลงทะเบียนเป็น useable item กับ framework ด้วย local callback และเมื่อผู้เล่นกดใช้เบ็ด SHALL trigger `TriggerClientEvent('zfishing:client:useRod', source, item)` โดยส่ง item (รวม slot) ไปยัง client โดยการ probe bridge ที่ล้มเหลว SHALL ไม่ทำให้การลงทะเบียนล้มทั้งหมด

**Validates: Requirements 2.5, 2.6**

Property 3: Preservation — zpm-locked path ไม่เปลี่ยน

_For any_ profile ที่ bug condition ไม่เป็นจริง (โดยเฉพาะ zpm-locked profile ที่ `unlocked` ไม่ได้เป็น true) — fixed code SHALL ให้ผลเหมือน original code ทุกประการ: บังคับ digest/evidence/capability gates เดิมใน `validateProfile`, `_checkHealth`, `capabilityVerified`; และเมื่อ profile `unlocked` แต่ framework/inventory resource ไม่ `started` ยังคง fail-closed ด้วย `RUNTIME_PROFILE_MISMATCH`

**Validates: Requirements 3.1, 3.2**

Property 4: Preservation — signature/lifecycle/anti-cheat/HUD/client ของ zfishing ไม่เปลี่ยน

_For any_ request ใน `{cast, cancel, sellAll, reportWeather, hook, claim, reel}` และการใช้ bridge inventory ops — fixed code SHALL ให้ผลเหมือน original code: signature + lifecycle เดิม, anti-cheat ใน session.lua เดิม, bridge envelope เดิม, Prompt HUD เดิม และ client `startRodUse`/exports/event เดิม

**Validates: Requirements 3.3, 3.4, 3.5, 3.6**

## Fix Implementation

### Changes Required

การแก้ยึดตาม hotfix ที่ทำไปแล้วและยืนยันว่าทำงาน — ส่วนนี้ formalize ให้ครบและถาวร

**File 1**: `zcore_lib/shared/runtime_profile.lua` (operator-owned config)

เปลี่ยนจาก `ZLib.RuntimeProfile = nil` เป็น local profile table:
1. **unlocked opt-out**: `unlocked = true` (สัญญาณให้ runtime.lua ข้าม zpm gates)
2. **feature mode**: `mode = 'enhanced-rig'` (zfishing รองรับ metadata-aware rod)
3. **framework**: `{ id = 'qbcore', resource = 'qb-core', version = 'local' }`
4. **inventory**: `{ id = 'qb-inventory', resource = 'qb-inventory', version = 'local' }`
5. **cosmetic fields**: `schema`, `digest`, `adapter{...}`, `capabilities = {}`, `runtimeEvidence = { resources = {} }` — ไม่ถูกใช้ตัดสินใจใน unlocked path แต่คงไว้ให้ shape สมบูรณ์และอ่านง่าย
- ไฟล์นี้เป็น **operator-owned config** ต้องคงไว้เมื่ออัปเดต (ดู Deployment Note)

**File 2**: `zcore_lib/shared/runtime.lua` (guarded bypass 3 จุด — path zpm-locked เดิมไม่แตะ)

เพิ่ม guard `if profile.unlocked == true then ...` ก่อน gate เดิมในแต่ละฟังก์ชัน โดย path ที่ไม่ unlocked ไหลลง logic เดิมทุกบรรทัด:
1. **`validateProfile`**: ถ้า unlocked → ตรวจแค่ `mode` (non-empty), `framework.id` + `framework.resource` (non-empty), `inventory.id` (non-empty), และ `inventory.resource` (non-empty เมื่อ inventory ไม่ใช่ `esx-native`) แล้ว `return nil`; ข้าม schema/digest/adapter-SUPPORTED/evidence checks ทั้งหมด
2. **`_checkHealth`**: ถ้า unlocked → ข้าม evidence-vs-live version matching แต่ยัง `getResourceState` ตรวจว่า framework resource (และ non-esx inventory resource) เป็น `started` — ถ้าไม่ `started` คืน `RUNTIME_PROFILE_MISMATCH` (คง fail-closed); ถ้าครบคืน success `ready = true`
3. **`capabilityVerified`**: ถ้า unlocked → `return true` (trust local detection: ทุก capability ที่ package ใช้พร้อมบน framework + inventory ที่ pin)

**File 3**: `zfishing/server/usable.lua` (ไฟล์ใหม่ + เพิ่มใน `fxmanifest.lua` server_scripts หลัง `server/session.lua`)

ลงทะเบียนเบ็ดเป็น useable item โดยตรงกับ framework:
1. **local callback**: `onRodUsed(source, item)` → `TriggerClientEvent('zfishing:client:useRod', source, item)` (ส่ง slot ให้ enhanced-rig อ่าน components ของเบ็ดตัวนั้น)
2. **diagnostic probe (ครั้งเดียว)**: เรียก `exports.zcore_lib:RegisterUsableItem(sample, onRodUsed)` เพื่อ log error code จริง (`UNSUPPORTED_FIELD`/ฯลฯ) แต่ **ไม่พึ่งพา** — ถ้า bridge บังเอิญคืน `ok` ก็ใช้ bridge ต่อได้ (best-effort forward-compat)
3. **primary/fallback register**: รอ framework `started` (poll ≤ 100×100ms) แล้ว `directRegister` ต่อ rod:
   - QBCore: `exports['qb-core']:GetCoreObject().Functions.CreateUseableItem(name, cb)`
   - QBox: `exports.qbx_core:CreateUseableItem(name, cb)`
   - ESX: `exports.es_extended:getSharedObject().RegisterUsableItem(name, cb)`
4. **log ยืนยัน**: ถ้าลงทะเบียนครบทุก rod โดยไม่มี error → print `usable rods registered via direct framework hook`
5. **fail isolation**: `directRegister` ใช้ `pcall` — rod ตัวใดล้มก็ log เฉพาะตัวนั้น ไม่ทำให้ทั้ง loop crash
- **client ไม่ต้องแก้**: `startRodUse` normalize ทั้ง slot table (ox export) และ slot number (framework-native event) อยู่แล้ว

## Testing Strategy

### Validation Approach

FiveM/Lua ไม่มี test runner ที่รันในสภาพแวดล้อมนี้ได้ (ต้องมี game/server runtime) จึงใช้สองแนวทางร่วมกัน: (1) **structural / example verification** อ่านโค้ดยืนยันว่า guard และ registration ตรงตาม property และ (2) **in-game smoke test** เทียบพฤติกรรมก่อน/หลัง พร้อมระบุ log markers ที่ยืนยันความสำเร็จ

### Exploratory Bug Condition Checking

**Goal**: ยืนยัน counterexample ที่แสดงบั๊กบนโค้ดก่อนแก้ และยืนยัน root cause A/B

**Test Plan**: บนโค้ด F (placeholder profile + ไม่มี usable registration ที่ทำงาน) สังเกต server console + พฤติกรรมในเกม

**Test Cases**:
1. **Profile unavailable (A)**: start server ด้วย `runtime_profile.lua = nil` → คาดเห็น `[zcore_lib] STARTUP HEALTH FAILED [PROFILE_UNAVAILABLE]` + `[zfishing] ... fishing disabled` (fail บน F)
2. **Cast blocked (A)**: เข้าเกม กดเบ็ด/พยายามตกปลา → `zfishing:cast` คืน `{ ok = false, reason = 'unavailable' }` (fail บน F)
3. **Manage Rod blocked (A)**: `/fishrig` → "ช่องนี้ไม่มีเบ็ด" ทั้งที่ถือเบ็ด (fail บน F)
4. **Used but nothing (B)**: กดใช้เบ็ด → "Used" แต่ไม่มี prop/ไม่เริ่มตกปลา (fail บน F)
5. **Bridge register fail (B)**: สังเกต log `[UNSUPPORTED_FIELD] item and callback are required` จาก bridge (fail บน F)

**Expected Counterexamples**:
- A: health check fail → facade closed → fishing disabled
- B: callback ไม่ถูกลงทะเบียน / `type(callback) ~= 'function'` ข้าม resource boundary

### Fix Checking

**Goal**: ยืนยันว่าทุก input ที่ bug condition เป็นจริง fixed function ให้พฤติกรรมที่ถูกต้อง

**Pseudocode:**
```
// Property 1 (A)
FOR ALL profile WHERE (profile.unlocked = true
                       AND profile.mode, framework.id, framework.resource, inventory.id ครบ
                       AND (inventory.id = 'esx-native' OR inventory.resource ครบ)
                       AND frameworkStarted(profile.framework.resource)) DO
  health := _checkHealth'(profile)
  ASSERT health.ok = true
  ASSERT Zfishing.Blocked'() = false
END FOR

// Property 2 (B)
FOR ALL rodName WHERE rodName IN keys(Config.Equipment.rods) DO
  registerUsableRods'()
  ASSERT frameworkHasUsableCallback(rodName) = true
  onUse := simulateUse(rodName, slot)
  ASSERT triggeredClientEvent(onUse) = 'zfishing:client:useRod' WITH item(slot)
END FOR
```

### Preservation Checking

**Goal**: ยืนยันว่าทุก input ที่ bug condition ไม่เป็นจริง fixed function ให้ผลเท่ากับ original

**Pseudocode:**
```
// Property 3 — zpm-locked path
FOR ALL profile WHERE NOT isBugConditionA(profile) DO
  ASSERT validateProfile(profile)   = validateProfile'(profile)
  ASSERT _checkHealth(profile)      = _checkHealth'(profile)
  ASSERT capabilityVerified(profile, cap) = capabilityVerified'(profile, cap)
END FOR

// Property 4 — zfishing surface
FOR ALL request WHERE request IN {cast, cancel, sellAll, reportWeather, hook, claim, reel}
                   OR request IN {HasItem, AddItem, RemoveItem, Search, GetSlot, SetSlotMeta, Notify} DO
  ASSERT F(request) = F'(request)
END FOR
```

**Testing Approach**: preservation ตรวจด้วย structural verification เป็นหลัก — ยืนยันว่า guard `if profile.unlocked == true` ครอบเฉพาะ unlocked branch และ locked branch เดิมไม่มีบรรทัดใดถูกแก้ ส่วน zfishing callbacks/session.lua/HUD/client ไม่มี diff เลย (fix แตะแค่ `server/usable.lua` ใหม่ + 1 บรรทัดใน fxmanifest)

**Test Cases**:
1. **Locked path unchanged**: จำลอง zpm-locked profile (unlocked ไม่ตั้ง) → gates ทั้งหมดยังบังคับเหมือนเดิม
2. **Unlocked + framework not started**: profile unlocked ครบ field แต่ `qb-core` ไม่ `started` → `RUNTIME_PROFILE_MISMATCH` (fail-closed คงเดิม)
3. **Fishing lifecycle**: หลัง profile พร้อม → cast/cancel/sellAll ทำงานตาม signature เดิม
4. **Bridge ops**: HasItem/AddItem/RemoveItem/Search กับ qb-inventory คืน envelope เดิม
5. **Prompt HUD**: prompt แสดง/ซ่อนตามเดิม (spec fishing-prompt-hud ไม่กระทบ)

### Unit Tests

- ตรวจ `validateProfile` unlocked branch: field ครบ → `nil`; ขาด field → `PROFILE_INVALID`
- ตรวจ `_checkHealth` unlocked branch: framework/inventory `started` → success; ไม่ `started` → `RUNTIME_PROFILE_MISMATCH`
- ตรวจ `capabilityVerified` unlocked → true; locked → logic เดิม
- ตรวจ `directRegister` เลือก branch framework ถูกตัว และ `pcall` isolate error

### Property-Based Tests

- Generate unlocked profile หลากหลาย (field ครบ/ขาด, inventory `esx-native` vs อื่น) → assert validateProfile/_checkHealth ตาม Property 1
- Generate rodName set ต่าง ๆ จาก `Config.Equipment.rods` → assert ทุกตัวถูกลงทะเบียน + trigger event ตาม Property 2
- Generate locked profile → assert ผลเท่า original ตาม Property 3
- หมายเหตุ: ในทางปฏิบัติ property tests เหล่านี้เป็น manual reasoning + structural check เพราะไม่มี test runner สำหรับ FiveM runtime

### Integration Tests (In-Game Smoke Test)

ทดสอบเต็ม flow บน QBCore + qb-inventory จริง เทียบก่อน/หลัง:
1. **ก่อนแก้ (F)**: ไม่มี zpm profile → server log `PROFILE_UNAVAILABLE` / fishing disabled; กดเบ็ด → "Used" เฉย ๆ; `/fishrig` → "ช่องนี้ไม่มีเบ็ด"
2. **หลังแก้ (F')**: server console แสดง log markers ยืนยัน:
   - `[zfishing] runtime mode = enhanced-rig (qbcore + qb-inventory)`
   - `[zfishing] usable rods registered via direct framework hook`
3. **กดใช้เบ็ด** → prop เบ็ดออก + เข้าสู่ standby/charge/cast (ตกปลาได้)
4. **`/fishrig`** → เห็นเบ็ดในช่องจริงพร้อม components
5. **Context switch / mouse use** → ใช้เบ็ดผ่านเมนู inventory (ox export) และผ่าน framework-native event ได้ทั้งสองทาง
6. **Regression**: cancel (X), sell NPC, Prompt HUD, weather report ทำงานตามเดิม

## Deployment / Operator Note

- **`runtime_profile.lua` เป็น operator-owned config**: เมื่ออัปเดต `zcore_lib` ด้วยการก๊อปโฟลเดอร์ทับ **ต้องไม่ทับ** `shared/runtime_profile.lua` (ไม่งั้นจะกลับไปเจอ Root cause A) แนะนำสำรองไฟล์นี้ไว้ก่อนอัปเดตทุกครั้ง และมี comment เตือนไว้หัวไฟล์แล้ว
- **วิธี retarget framework/inventory**: แก้ `framework.id`/`framework.resource` และ `inventory.id`/`inventory.resource` ให้ตรงกับเซิร์ฟเวอร์:
  - `framework.id`: `'qbcore'` | `'qbox'` | `'esx'`
  - `inventory.id`: `'qb-inventory'` | `'ox_inventory'` | `'esx-native'`
  - enhanced-rig (rod assembly) ต้องใช้ inventory ที่เก็บ metadata ได้ (qb-inventory / ox_inventory); ถ้าใช้ `esx-native` ให้พิจารณา `mode = 'simple-fishing'`
- **fail-closed ยังทำงาน**: ถ้าตั้ง framework/inventory ผิด (resource ไม่ `started`) ระบบจะคืน `RUNTIME_PROFILE_MISMATCH` พร้อม remediation ไม่ใช่เงียบ ๆ ไม่ทำงาน
- **ขอบเขต**: fix นี้โฟกัส qbcore + qb-inventory เป็นหลัก; qbox/esx เป็น best-effort ที่มีอยู่ในโค้ด adapter/registration แล้ว ไม่ได้ทดสอบ smoke test เชิงลึกในสเปคนี้
