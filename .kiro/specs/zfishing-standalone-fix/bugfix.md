# Bugfix Requirements Document — zfishing-standalone-fix

## Introduction

บน QBCore + qb-inventory ระบบตกปลา (`zfishing`) ใช้งานไม่ได้เลยหลังจากติดตั้ง/อัปเดตด้วยวิธี "ก๊อปโฟลเดอร์ทับ" (`zfishing` + `zcore_lib`) อาการที่ผู้เล่นเจอคือ กดใช้เบ็ด (rod) แล้วขึ้นข้อความ "Used" แต่ไม่มี prop เบ็ดออกมาและเริ่มตกปลาไม่ได้ ส่วนเมนู Manage Rod (`/fishrig`) แจ้งว่า "ช่องนี้ไม่มีเบ็ด"

จากการอ่าน source ร่วมกับ log จริงบนเซิร์ฟเวอร์ พบสาเหตุราก 2 จุดที่แยกกันชัดเจน:

- **Root cause A — `zcore_lib` fail-closed เพราะไม่มี zpm-generated runtime profile:** ไฟล์ `zcore_lib/shared/runtime_profile.lua` เดิมเป็น placeholder (`ZLib.RuntimeProfile = nil`) ที่ zpm/Site Agent ต้อง generate ทับตอน deploy การก๊อปโฟลเดอร์ dev ทับทำให้ profile จริงหายไป ทำให้ health check ล้มเหลว (`[PROFILE_UNAVAILABLE]`) `zcore_lib` ปิดตัวเองแบบ fail-closed และ `zfishing` ถูก block ทั้งหมด
- **Root cause B — usable rod ไม่ถูกลงทะเบียน (callback หายข้าม resource boundary):** เบ็ดตั้ง `useable = true` ใน items แต่ไม่มีโค้ดใดเรียก `CreateUseableItem` จริง การพยายามลงทะเบียนผ่าน bridge `exports.zcore_lib:RegisterUsableItem(name, callback)` ล้มเหลวเพราะ FiveM exports ไม่ preserve function reference ข้าม resource ทำให้ฝั่ง `zcore_lib` เห็น callback เป็น non-function และคืน error `[UNSUPPORTED_FIELD]`

เอกสารนี้กำหนดพฤติกรรมที่ถูกต้องสำหรับกรณี operator ที่เลือกใช้งานแบบ standalone (โหมด `unlocked`, opt-out จาก zpm) พร้อมทั้งระบุพฤติกรรมเดิมที่ต้องคงไว้ (regression prevention) เป้าหมายคือทำให้ hotfix ที่ทำไปแล้วเป็นทางการและครอบคลุมทุกเงื่อนไข

## Bug Analysis

### Current Behavior (Defect)

พฤติกรรมที่เกิดขึ้นจริง ณ ตอนนี้เมื่อ deploy โดยก๊อปโฟลเดอร์ทับบน QBCore + qb-inventory:

1.1 WHEN `zcore_lib/shared/runtime_profile.lua` เป็น placeholder ที่ `ZLib.RuntimeProfile = nil` (ไม่มี zpm lock) THEN the system รัน startup health check ไม่ผ่านและ log `[zcore_lib] STARTUP HEALTH FAILED [PROFILE_UNAVAILABLE]`

1.2 WHEN `runtime_profile` ไม่พร้อมใช้งาน THEN the system ทำให้ `exports.zcore_lib:GetProfile()` คืนผลลัพธ์ที่ `ok = false` ส่งผลให้ `Zfishing.Blocked()` เป็น true และ log `[zfishing] runtime profile unavailable [STARTUP_HEALTH_FAILED] ... fishing disabled`

1.3 WHEN `Zfishing.Blocked()` เป็น true THEN the system ทำให้ callback `zfishing:cast` (และ path ที่พึ่ง profile เช่น rig lookup) คืน `{ ok = false, reason = 'unavailable' }` ทำให้เริ่มตกปลาไม่ได้

1.4 WHEN ผู้เล่นเปิดเมนู Manage Rod (`/fishrig`) ในสถานะ blocked THEN the system แจ้งว่า "ช่องนี้ไม่มีเบ็ด" แทนที่จะแสดงเบ็ดที่ผู้เล่นถืออยู่จริง

1.5 WHEN ผู้เล่นกดใช้เบ็ดจาก inventory THEN the system แสดงข้อความ "Used" แต่ไม่ trigger การเริ่มตกปลา เพราะไม่มี useable-item callback ผูกกับชื่อเบ็ด

1.6 WHEN `zfishing` พยายามลงทะเบียนเบ็ดผ่าน bridge `exports.zcore_lib:RegisterUsableItem(name, callback)` THEN the system คืน error `[UNSUPPORTED_FIELD] item and callback are required` เพราะ function reference ไม่ถูก preserve ข้าม resource boundary

### Expected Behavior (Correct)

พฤติกรรมที่ถูกต้องสำหรับแต่ละเงื่อนไขข้างต้น (คู่กันแบบ X.Y):

2.1 WHEN `runtime_profile` เป็น local profile ที่ `unlocked = true` และระบุ `framework`, `inventory`, `mode` ครบ THEN the system SHALL ผ่าน startup health check โดยข้าม lock digest / evidence-version / capability-verification gates แต่ยังตรวจว่า framework (และ inventory ที่ไม่ใช่ `esx-native`) อยู่ในสถานะ `started`

2.2 WHEN profile เป็น `unlocked` ที่ถูกต้อง THEN the system SHALL ทำให้ `exports.zcore_lib:GetProfile()` คืน `ok = true` พร้อม `mode` และ `framework`/`inventory` เพื่อให้ `Zfishing.Blocked()` เป็น nil/false

2.3 WHEN `Zfishing.Blocked()` เป็น false THEN the system SHALL ทำให้ callback `zfishing:cast` และ lifecycle การตกปลาทำงานตามปกติ (ผ่าน validation เดิมของ session)

2.4 WHEN ผู้เล่นเปิด Manage Rod (`/fishrig`) และถือเบ็ดอยู่ในช่องจริง THEN the system SHALL อ่านและแสดงเบ็ดพร้อมส่วนประกอบ (components) ของเบ็ดในช่องนั้นได้ถูกต้อง

2.5 WHEN ผู้เล่นกดใช้เบ็ดจาก inventory THEN the system SHALL trigger event `zfishing:client:useRod` พร้อมส่ง item (รวม slot) ไปยัง client เพื่อเริ่มขั้นตอนตกปลา

2.6 WHEN `zfishing` ลงทะเบียนเบ็ดเป็น useable item THEN the system SHALL ลงทะเบียนผ่าน framework โดยตรงด้วย local callback ในตัว `zfishing` เอง (QBCore: `CreateUseableItem`, QBox: `qbx_core:CreateUseableItem`, ESX: `RegisterUsableItem`) และ log ยืนยันความสำเร็จ (`usable rods registered via direct framework hook`) โดยการ probe bridge ล้มเหลวต้องไม่ทำให้การลงทะเบียนล้มทั้งหมด

### Unchanged Behavior (Regression Prevention)

พฤติกรรมเดิมที่ต้องไม่เปลี่ยนแปลงหลังแก้บั๊ก:

3.1 WHEN มี zpm-generated locked profile จริง (`unlocked` ไม่ได้เป็น true) THEN the system SHALL CONTINUE TO บังคับ lock digest / evidence-version / capability-verification gates ตามเดิมทุกจุด (validateProfile, `_checkHealth`, capabilityVerified)

3.2 WHEN profile เป็น `unlocked` แต่ framework หรือ inventory resource ไม่ได้ `started` THEN the system SHALL CONTINUE TO fail-closed พร้อม error `RUNTIME_PROFILE_MISMATCH` (ไม่ silently no-op)

3.3 WHEN มีการเรียก server callback/event ของ zfishing (`zfishing:cast`, `zfishing:cancel`, `zfishing:sellAll`, `zfishing:reportWeather`) THEN the system SHALL CONTINUE TO ใช้ signature และ lifecycle การตกปลาเดิมโดยไม่เปลี่ยนแปลง

3.4 WHEN มีการตกปลา, hook, claim, reel THEN the system SHALL CONTINUE TO รัน server-side validation / anti-cheat logic ใน `session.lua` เดิมทั้งหมด (server-side roll, timing plausibility, rate limit) โดยไม่ถูกแก้ไข

3.5 WHEN ใช้งานอินเวนทอรีผ่าน bridge (HasItem, AddItem, RemoveItem, Search, SetSlotMeta, Notify ฯลฯ) THEN the system SHALL CONTINUE TO คืน structured envelope เดิมและทำงานกับ qb-inventory ตามปกติ

3.6 WHEN feature Prompt HUD (spec `fishing-prompt-hud`) ทำงานอยู่ THEN the system SHALL CONTINUE TO ทำงานได้ตามเดิมโดยไม่ถูกกระทบจากการแก้ครั้งนี้

3.7 WHEN operator deploy ด้วยการก๊อปโฟลเดอร์ THEN the system SHALL CONTINUE TO เก็บไฟล์ `runtime_profile.lua` เป็นไฟล์ที่ operator ต้องคงไว้ (ไม่ถูกทับโดยไม่ตั้งใจ) พร้อมเอกสาร/คำเตือนกำกับ

### Bug Condition Derivation (Methodology)

นิยาม bug condition และ property เพื่อใช้ตรวจสอบการแก้ (fix checking) และการคงพฤติกรรม (preservation checking) มี 2 bug condition แยกตาม root cause

**Root cause A — profile availability**

```pascal
FUNCTION isBugConditionA(profile)
  INPUT: profile of type RuntimeProfile (ค่าใน ZLib.RuntimeProfile)
  OUTPUT: boolean

  // buggy เมื่อ operator ตั้งใจใช้ standalone (unlocked) แต่ profile หาย/เป็น nil
  // ทำให้ระบบ fail-closed ทั้งที่ควรทำงานได้
  RETURN (profile = nil)
      OR (profile.unlocked = true AND profileFieldsIncomplete(profile))
END FUNCTION
```

```pascal
// Property: Fix Checking — standalone profile ต้องทำให้ระบบพร้อมใช้งาน
FOR ALL profile WHERE (profile.unlocked = true
                       AND profile.framework.id, profile.framework.resource,
                           profile.inventory.id, profile.mode ครบถ้วน
                       AND frameworkStarted(profile.framework.resource)) DO
  health ← healthCheck'(profile)
  ASSERT health.ok = true
  ASSERT Zfishing.Blocked'() = false
END FOR
```

**Root cause B — usable rod registration**

```pascal
FUNCTION isBugConditionB(rodName)
  INPUT: rodName of type string (คีย์ใน Config.Equipment.rods)
  OUTPUT: boolean

  // buggy เมื่อเบ็ด useable แต่ไม่มี useable-item callback ผูกกับ framework
  RETURN NOT frameworkHasUsableCallback(rodName)
END FUNCTION
```

```pascal
// Property: Fix Checking — เบ็ดทุกตัวต้องมี useable callback ผูกกับ framework โดยตรง
FOR ALL rodName WHERE rodName IN keys(Config.Equipment.rods) DO
  registerUsableRods'()   // F' หลังแก้
  ASSERT frameworkHasUsableCallback(rodName) = true
  onUse ← simulateUse(rodName, slot)
  ASSERT triggeredClientEvent(onUse) = 'zfishing:client:useRod' WITH item(slot)
END FOR
```

**Preservation (ทั้ง A และ B)**

```pascal
// Property: Preservation Checking
FOR ALL profile WHERE NOT isBugConditionA(profile) DO
  ASSERT healthCheck(profile) = healthCheck'(profile)   // locked path เดิมไม่เปลี่ยน
END FOR

FOR ALL request WHERE request IN {cast, cancel, sellAll, reportWeather, hook, claim} DO
  ASSERT F(request) = F'(request)   // signature + lifecycle + anti-cheat เดิมไม่เปลี่ยน
END FOR
```

**คำนิยาม:**
- **F**: โค้ดก่อนแก้ (มี placeholder profile และไม่มี usable registration ที่ทำงาน)
- **F'**: โค้ดหลังแก้ (local unlocked profile + bypass 3 จุดใน runtime.lua + direct framework usable hook ใน `server/usable.lua`)
