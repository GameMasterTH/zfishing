# zfishing Water Validation Fix — Bugfix Design

## Overview

Bug นี้ทำให้ผู้เล่นสามารถขว้างเบ็ด/เริ่ม session ตกปลาได้ทั้งที่ไม่ได้อยู่ใกล้น้ำจริง สาเหตุคือฟังก์ชัน `nearWater()` ถูกเรียกตรวจสอบ **ครั้งเดียว** ตอนหยิบเบ็ดขึ้นมาใช้ (`startRodUse` ใน `client/main.lua`) เท่านั้น หลังจากผ่าน gate นั้นแล้วผู้เล่นสามารถเดินออกจากน้ำไปยืนบนพื้นดินที่ยังอยู่ภายใน zone radius (แบบ 2D) แล้วกดขว้างเบ็ดได้ตามปกติ เพราะไม่มีการตรวจซ้ำ ณ จังหวะ cast

แนวทางแก้ไขคือ **client-side gate เพิ่มเติม**: เรียก `nearWater()` ซ้ำอีกครั้ง ณ จังหวะก่อนเริ่ม cast จริง หาก return `false` ให้แจ้งเตือนด้วยข้อความ `need_water` และยกเลิกการทำงานอย่างสะอาด (ผ่าน `cleanup`) โดย **ไม่แตะ logic ฝั่ง server** และ **ไม่ทำ real-time re-check** ระหว่างรอปลากิน/สู้ปลา

ขอบเขตการแก้ไขนี้เป็น minimal fix — เพิ่มการตรวจสอบเพียงจุดเดียวในเส้นทาง cast โดยใช้ฟังก์ชัน `nearWater()` และข้อความ notify เดิมที่มีอยู่แล้ว เพื่อไม่ให้กระทบพฤติกรรมส่วนอื่น

## Glossary

- **Bug_Condition (C)**: เงื่อนไขที่ทำให้เกิด bug — ผู้เล่นถือเบ็ดอยู่ในสถานะ active, พยายามขว้างเบ็ด (cast) แต่ตำแหน่ง ณ จังหวะนั้น `nearWater()` = `false` (ไม่ได้อยู่ใกล้น้ำจริง) ทว่ายังอยู่ใน zone radius จึงผ่าน gate ตอนหยิบเบ็ดมาแล้ว
- **Property (P)**: พฤติกรรมที่ถูกต้องเมื่อเข้าเงื่อนไข C — ระบบต้องปฏิเสธการ cast, ไม่เริ่ม session, แจ้งเตือน `need_water` และคืนสถานะอย่างสะอาด (ไม่ค้างในสถานะถือเบ็ด)
- **Preservation**: พฤติกรรมเดิมที่ต้องคงไว้ไม่ให้พัง — การขว้างเบ็ดเมื่ออยู่ใกล้น้ำจริง, gate ตอนหยิบเบ็ด (`need_water` / `no_fish_here`), กลไก charge/spawn float/bite/reel และการ cancel (X)
- **nearWater()**: ฟังก์ชันใน `client/main.lua` ที่ยิง `TestProbeAgainstWater` ไปข้างหน้า ped 6.0 หน่วย เพื่อตรวจว่ามีน้ำจริงอยู่ใกล้หรือไม่ คืนค่า boolean
- **startRodUse(data, slot)**: entry point เมื่อผู้เล่น "ใช้" ไอเทมเบ็ด — เป็นจุดที่ตรวจ `nearWater()` และ `currentZone()` ครั้งแรกก่อนเรียก `startFishing()`
- **startFishing()**: ฟังก์ชันที่ดำเนินลำดับ standby → charge → cast callback → waiting เป็นจุดที่จะเพิ่มการตรวจ `nearWater()` ซ้ำ
- **Casting.Charge()**: ฟังก์ชันที่รับ input การกด/ปล่อยเพื่อคำนวณ power ของการขว้าง คืนค่า power (number) หรือ `nil` ถ้าไม่ได้เริ่มขว้าง
- **cleanup(msgKey, msgType)**: ฟังก์ชันคืนสถานะทั้งหมด (reset `ZClient.active`, หยุด anim, ปลด freeze, ซ่อน UI) และ notify ตาม key ที่ส่งเข้าไป
- **zone radius (2D)**: ระยะแนวนอนของ fishing zone ที่ตรวจโดย `currentZone()` — เป็นคนละเงื่อนไขกับความใกล้น้ำจริง จึงเป็นเหตุให้ยืนบนบกใน zone แล้วยัง cast ได้

## Bug Details

### Bug Condition

Bug เกิดเมื่อผู้เล่นอยู่ในสถานะถือเบ็ด (`ZClient.active == true`) แล้วพยายามขว้างเบ็ด (เข้าสู่ขั้น charge/cast) ในตำแหน่งที่ `nearWater()` คืนค่า `false` แต่ยังอยู่ภายใน zone radius จึงเคยผ่าน gate ของ `startRodUse` มาก่อนหน้านี้ ระบบปัจจุบัน **ไม่ตรวจ `nearWater()` ซ้ำ** ณ จังหวะ cast จึงยอมให้ cast สำเร็จ

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input ประกอบด้วย { playerState, castAttempt }
         - playerState.active   : boolean  (กำลังถือเบ็ด/อยู่ในลำดับ startFishing)
         - playerState.nearWater : boolean (ณ จังหวะ cast มีน้ำจริงอยู่ใกล้หรือไม่)
         - castAttempt          : boolean  (ผู้เล่นกดเริ่มขว้างเบ็ด)
  OUTPUT: boolean

  RETURN playerState.active == true
         AND castAttempt == true
         AND playerState.nearWater == false
END FUNCTION
```

### Examples

- **ยืนบนบกใน zone แล้วขว้าง (buggy):** ผู้เล่นหยิบเบ็ดริมน้ำ (ผ่าน gate) เดินขึ้นมายืนบนถนนที่ยังอยู่ใน zone radius แล้วกด E ขว้างเบ็ด — คาดหวัง: ถูกปฏิเสธพร้อม `need_water` / จริง: cast สำเร็จ เริ่ม session ตกปลาได้
- **ยืนบนโขดหินสูงใน zone (buggy):** ผู้เล่นเดินขึ้นไปบนโขดหิน/ท่าเรือสูงที่ probe ไม่โดนน้ำ แต่ยังอยู่ใน zone — คาดหวัง: ถูกปฏิเสธ / จริง: cast ได้
- **หันหน้าออกจากน้ำ (buggy):** ผู้เล่นยืนใกล้น้ำแต่หันหน้าเข้าฝั่งจน probe 6.0 หน่วยข้างหน้าไม่โดนน้ำ — คาดหวัง: ถูกปฏิเสธ / จริง: cast ได้ (ถ้ายังอยู่ใน zone)
- **อยู่ใกล้น้ำจริงแล้วขว้าง (ไม่ใช่ bug — ต้องผ่าน):** ผู้เล่นยืนริมน้ำ หันหน้าเข้าน้ำ กด E ขว้าง — คาดหวังและจริง: cast สำเร็จตามปกติ (เงื่อนไข C ไม่เป็นจริงเพราะ `nearWater == true`)

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- การขว้างเบ็ดเมื่อ **อยู่ใกล้น้ำจริงและอยู่ใน zone ที่มีปลา** ต้องเริ่ม session และ cast ได้ตามปกติ (bugfix.md 3.1)
- gate ตอนหยิบเบ็ด: ถ้าไม่อยู่ใกล้น้ำ ต้องปฏิเสธพร้อม `need_water` เหมือนเดิม (bugfix.md 3.2)
- gate ตอนหยิบเบ็ด: ถ้าไม่อยู่ใน zone ใด (และ `Config.RequireZone` เปิด) ต้องปฏิเสธพร้อม `no_fish_here` เหมือนเดิม (bugfix.md 3.3)
- กลไกหลังขว้างเบ็ดสำเร็จ: การคำนวณ power, `Casting.SpawnFloat`, และลำดับ bite/hook/reel ต้องทำงานเหมือนเดิม (bugfix.md 3.4)
- การกด cancel (X) ในทุกเฟส ต้องยกเลิกและคืนสถานะได้ตามปกติ (bugfix.md 3.5)

**Scope:**
input ทั้งหมดที่ **ไม่เข้าเงื่อนไข C** (ไม่ได้อยู่ในจังหวะ cast ทั้งที่ห่างน้ำ) จะต้องไม่ได้รับผลกระทบจากการแก้ไขนี้เลย ครอบคลุม:
- การขว้างเบ็ดขณะอยู่ใกล้น้ำจริง (`nearWater() == true`)
- การหยิบเบ็ดขึ้นมาใช้ (`startRodUse` gate ทั้งสองแบบ)
- กลไกหลัง cast สำเร็จ (charge/float/bite/reel)
- การ cancel และ cleanup ทุกเฟส
- การขายปลาที่ NPC และ logic ฝั่ง server (ไม่ถูกแตะต้อง)

**หมายเหตุ:** พฤติกรรมที่ถูกต้อง (correct behavior) เมื่อเข้าเงื่อนไข C ถูกกำหนดไว้ใน Correctness Properties (Property 1) ส่วนนี้เน้นสิ่งที่ **ต้องไม่เปลี่ยน**

## Hypothesized Root Cause

จากการวิเคราะห์ bug และอ่าน `client/main.lua` สาเหตุที่เป็นไปได้มากที่สุดคือ:

1. **การตรวจน้ำครั้งเดียวที่ผิดจังหวะ (สาเหตุหลัก)**: `nearWater()` ถูกเรียกเฉพาะใน `startRodUse` ณ ตอนหยิบเบ็ด แต่ระหว่างช่วง standby (`showPrompt('equip_title', ...)` รอกด E) และช่วง `Casting.Charge()` ผู้เล่นสามารถเดินเปลี่ยนตำแหน่งได้ ทำให้ตำแหน่ง ณ จังหวะ cast จริงต่างจากตอนตรวจ

2. **เงื่อนไข gate สองอย่างเป็นคนละมิติ**: `nearWater()` ตรวจน้ำจริงแบบ 3D (probe แนวดิ่ง) ส่วน `currentZone()` ตรวจแค่ระยะแนวนอน 2D ทำให้พื้นที่ "อยู่ใน zone แต่ไม่ใกล้น้ำ" มีอยู่จริงและกว้าง

3. **ไม่มี re-validation ในเส้นทาง `startFishing()`**: ลำดับ standby → charge → `lib.callback.await('zfishing:cast')` ไม่มีจุดใดเรียก `nearWater()` ซ้ำก่อนยิง cast callback

4. **server ไม่ได้ (และตรวจน้ำ authoritative ได้ยาก)**: `TestProbeAgainstWater` เป็น client-side native เป็นหลัก server จึง re-validate zone ได้แต่ตรวจน้ำจริงไม่ได้ ทำให้ต้องพึ่ง client-side gate (เป็นข้อจำกัดที่รับทราบและอยู่นอกขอบเขต bugfix นี้)

การแก้ที่ตรงจุดที่สุดคือเพิ่มการเรียก `nearWater()` ซ้ำในเส้นทาง `startFishing()` ก่อนที่จะดำเนินการ cast จริง

## Correctness Properties

Property 1: Bug Condition — ปฏิเสธการ cast เมื่อไม่ได้อยู่ใกล้น้ำจริง

_For any_ input ที่เข้าเงื่อนไข bug (isBugCondition คืนค่า true — ผู้เล่นถือเบ็ด, พยายามขว้าง, และ `nearWater() == false`) ฟังก์ชันที่แก้ไขแล้ว SHALL ปฏิเสธการ cast, ไม่เริ่ม fishing session, แจ้งเตือนด้วยข้อความ `need_water`, และคืนสถานะอย่างสะอาดผ่าน `cleanup` (ไม่ค้างในสถานะถือเบ็ด)

**Validates: Requirements 2.1, 2.2**

Property 2: Preservation — พฤติกรรมของ input ที่ไม่เข้าเงื่อนไข bug ต้องไม่เปลี่ยน

_For any_ input ที่ **ไม่เข้า** เงื่อนไข bug (isBugCondition คืนค่า false — เช่น อยู่ใกล้น้ำจริงขณะ cast, กำลังหยิบเบ็ด, อยู่ในเฟส bite/reel, หรือกด cancel) โค้ดที่แก้ไขแล้ว SHALL ให้ผลลัพธ์เหมือนกับโค้ดเดิมทุกประการ โดยคงพฤติกรรมการขว้างเบ็ดปกติ, gate ตอนหยิบเบ็ด, กลไก charge/float/bite/reel และการ cancel ไว้ครบถ้วน

**Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5**

## Fix Implementation

### Changes Required

สมมติว่าการวิเคราะห์ root cause ถูกต้อง จะแก้ที่จุดเดียวในเส้นทาง cast:

**File**: `client/main.lua`

**Function**: `startFishing()`

**Specific Changes**:
1. **เพิ่มการ re-check `nearWater()` ก่อนเริ่ม cast**: หลังจากผู้เล่นกด E ออกจาก standby และก่อน (หรือหลัง) `Casting.Charge()` แต่ต้องก่อนยิง `lib.callback.await('zfishing:cast', ...)` ให้เรียก `nearWater()` อีกครั้ง
   - ตำแหน่งที่แนะนำ: หลัง `Casting.Charge()` คืน power ที่ valid แล้ว และก่อนเรียก cast callback — เพื่อให้ตรวจตำแหน่งจริง ณ จังหวะที่ผู้เล่นตั้งใจขว้างจริง
   - เหตุผล: ระหว่าง charge ผู้เล่นอาจยังขยับตำแหน่ง การตรวจให้ใกล้จังหวะ cast จริงที่สุดจะแม่นยำที่สุด

2. **ปฏิเสธและ cleanup เมื่อไม่ผ่าน**: ถ้า `nearWater() == false` ให้เรียก `cleanup('need_water', 'error')` แล้ว `return` ออกจาก `startFishing()` ทันที ไม่ยิง cast callback
   - ใช้ `cleanup` (ไม่ใช่แค่ notify) เพื่อคืนสถานะ `ZClient.active`, หยุด anim, ปลด freeze, ซ่อน UI ให้สะอาด ป้องกันสถานะค้าง

3. **ใช้ข้อความ notify เดิม**: ใช้ locale key `need_water` ที่มีอยู่แล้ว (เดียวกับ gate ใน `startRodUse`) ไม่เพิ่ม key ใหม่ เพื่อความสอดคล้องและ minimal change

4. **ไม่แตะ logic อื่น**: ไม่แก้ `nearWater()`, `currentZone()`, `startRodUse`, cast callback ฝั่ง server, กลไก bite/reel หรือ cancel ใด ๆ

**ตัวอย่างจุดแทรก (pseudocode):**
```
-- ภายใน startFishing() หลังจาก Casting.Charge() คืน power ที่ valid
local power = Casting.Charge()
if not ZClient.active then return end
if power == nil then return cleanup('cancelled') end

-- [NEW] re-check ความใกล้น้ำ ณ จังหวะ cast
if not nearWater() then
    return cleanup('need_water', 'error')
end

local res = lib.callback.await('zfishing:cast', false, power, ZClient.rodSlot)
...
```

## Testing Strategy

### Validation Approach

กลยุทธ์การทดสอบเป็นสองเฟส: เฟสแรกสร้าง counterexample ที่แสดงว่า bug เกิดจริงบนโค้ดที่ **ยังไม่แก้** เพื่อยืนยัน root cause จากนั้นเฟสสองยืนยันว่าการแก้ทำงานถูกต้อง (fix checking) และไม่ทำพฤติกรรมเดิมพัง (preservation checking)

หมายเหตุด้านเทคนิค: โค้ดนี้เป็น FiveM client Lua ที่พึ่ง natives (`TestProbeAgainstWater`, `GetEntityCoords` ฯลฯ) การทดสอบจึงต้อง **แยก decision logic ออกจาก natives** โดย mock/stub ค่า `nearWater()` และสถานะ `ZClient` เพื่อให้ทดสอบ decision gate ได้แบบ deterministic โดยไม่ต้องรันในเกมจริง ส่วนการตรวจ integration ในเกมจริงทำแบบ manual

### Exploratory Bug Condition Checking

**Goal**: สร้าง counterexample ที่แสดง bug บนโค้ดที่ยังไม่แก้ เพื่อยืนยันหรือหักล้าง root cause ถ้าหักล้างต้องกลับไป re-hypothesize

**Test Plan**: จำลองสถานการณ์ที่ผู้เล่นผ่าน gate ตอนหยิบเบ็ด (`nearWater()` = true ตอน `startRodUse`) แล้ว `nearWater()` เปลี่ยนเป็น false ณ จังหวะ cast จากนั้น assert ว่า cast callback **ถูกเรียก** (พฤติกรรมผิด) รันบนโค้ดที่ยังไม่แก้เพื่อดูว่า assert นี้ผ่าน (ยืนยัน bug)

**Test Cases**:
1. **ยืนบนบกใน zone แล้วขว้าง**: `startRodUse` ผ่าน (near=true, zone ok) → เปลี่ยน `nearWater` เป็น false → เข้า cast → คาดว่าบนโค้ดไม่แก้ cast callback ถูกเรียก (will fail after fix / demonstrates bug now)
2. **หันหน้าออกจากน้ำก่อนขว้าง**: จำลอง `nearWater` = false ณ จังหวะ charge เสร็จ → คาดว่าบนโค้ดไม่แก้ยัง cast ได้ (demonstrates bug)
3. **เดินออกไประหว่าง standby**: ผ่าน gate → ระหว่างรอกด E เดินออกจากน้ำ → กด E ขว้าง → คาดว่าบนโค้ดไม่แก้ยัง cast ได้ (demonstrates bug)
4. **Edge — ยืนคาบเส้นขอบน้ำ**: `nearWater` = false แบบ marginal → ตรวจว่าเข้าเงื่อนไข C และควรถูกปฏิเสธ (may pass/fail depending on probe)

**Expected Counterexamples**:
- cast callback (`zfishing:cast`) ถูกเรียกทั้งที่ `nearWater()` = false ณ จังหวะ cast
- สาเหตุที่เป็นไปได้: ไม่มี re-check ใน `startFishing()`, gate ตรวจครั้งเดียวใน `startRodUse`, zone (2D) กับ water (3D) เป็นคนละเงื่อนไข

### Fix Checking

**Goal**: ยืนยันว่าสำหรับทุก input ที่เข้าเงื่อนไข bug ฟังก์ชันที่แก้แล้วให้พฤติกรรมที่ถูกต้อง (Property 1)

**Pseudocode:**
```
FOR ALL input WHERE isBugCondition(input) DO
  result := startFishing_fixed(input)
  ASSERT result.castCallbackInvoked == false     -- ไม่ยิง cast
  ASSERT result.sessionStarted == false           -- ไม่เริ่ม session
  ASSERT result.notified == 'need_water'           -- แจ้งเตือนถูก key
  ASSERT result.stateClean == true                 -- ZClient.active == false, ไม่ค้าง
END FOR
```

### Preservation Checking

**Goal**: ยืนยันว่าสำหรับทุก input ที่ **ไม่เข้า** เงื่อนไข bug ฟังก์ชันที่แก้แล้วให้ผลลัพธ์เหมือนฟังก์ชันเดิม (Property 2)

**Pseudocode:**
```
FOR ALL input WHERE NOT isBugCondition(input) DO
  ASSERT startFishing_original(input) == startFishing_fixed(input)
END FOR
```

**Testing Approach**: property-based testing เหมาะกับ preservation checking เพราะ:
- generate test case จำนวนมากอัตโนมัติครอบคลุม input domain (สถานะ active/inactive, near/far water, เฟสต่าง ๆ, การกด cancel)
- จับ edge case ที่ unit test แบบเขียนมือมองข้าม
- ให้การรับประกันที่แข็งแรงว่าพฤติกรรมสำหรับ input ที่ไม่ใช่ bug ไม่เปลี่ยน

**Test Plan**: สังเกตพฤติกรรมบนโค้ดที่ยังไม่แก้สำหรับ input ที่ไม่ใช่ bug ก่อน (near water = true ขณะ cast, การหยิบเบ็ด, การ cancel) แล้วเขียน property-based test จับพฤติกรรมนั้นไว้ ยืนยันว่ายังเหมือนเดิมหลังแก้

**Test Cases**:
1. **Preservation — ขว้างเบ็ดใกล้น้ำจริง**: สังเกตว่าเมื่อ `nearWater()` = true ณ จังหวะ cast โค้ดเดิมยิง cast callback และเริ่ม session ได้ → เขียน test ยืนยันว่าหลังแก้ยังทำได้เหมือนเดิม
2. **Preservation — gate ตอนหยิบเบ็ด**: ยืนยันว่า `startRodUse` ยังปฏิเสธด้วย `need_water` (ไม่ใกล้น้ำ) และ `no_fish_here` (ไม่อยู่ใน zone) เหมือนเดิม ไม่ถูกกระทบ
3. **Preservation — กลไกหลัง cast**: ยืนยันว่าเมื่อ cast สำเร็จ การคำนวณ power, `SpawnFloat`, และลำดับ bite/reel ยังทำงานเหมือนเดิม
4. **Preservation — cancel ทุกเฟส**: ยืนยันว่า `zfishing_cancel` (X) ยังยกเลิกและ cleanup ได้ในทุกเฟส

### Unit Tests

- ทดสอบ decision gate ของ cast: given `active=true, nearWater=false, castAttempt=true` → ต้องปฏิเสธ + notify `need_water` + cleanup
- ทดสอบ path ปกติ: given `active=true, nearWater=true` → ต้องยิง cast callback ตามเดิม
- ทดสอบ edge: `power == nil` (timeout) ยังคืน `cleanup('cancelled')` เหมือนเดิม, X ระหว่าง standby ยัง return เงียบ ๆ
- ทดสอบว่า `startRodUse` gate เดิม (`need_water` / `no_fish_here` / `error_busy`) ไม่เปลี่ยน

### Property-Based Tests

- generate สถานะสุ่ม (`active`, `nearWater` ณ startRodUse, `nearWater` ณ cast, `inZone`) แล้วยืนยันว่า: ถ้า `nearWater` ณ cast = false → ไม่มีทาง cast สำเร็จ (Property 1)
- generate input ที่ไม่เข้าเงื่อนไข bug จำนวนมาก แล้วยืนยันผลลัพธ์เท่ากับโค้ดเดิม (Property 2)
- ทดสอบว่าไม่มี input ใดที่ `nearWater` ณ cast = true แต่ถูกปฏิเสธผิดพลาด (ไม่มี false positive)

### Integration Tests (Manual in-game)

- **Full flow ปกติ**: ยืนริมน้ำ → หยิบเบ็ด → กด E → ขว้าง → เริ่ม session ได้ (ต้องผ่าน)
- **Bug scenario**: หยิบเบ็ดริมน้ำ → เดินขึ้นบกใน zone → กด E ขว้าง → ต้องถูกปฏิเสธพร้อม `need_water` และคืนสถานะสะอาด
- **Context/visual feedback**: ตรวจว่าเมื่อถูกปฏิเสธ ณ cast แล้ว prompt/HUD ถูกซ่อน, ped ไม่ freeze ค้าง, และสามารถหยิบเบ็ดใหม่ได้ทันที
- **Cancel**: ตรวจว่ากด X ระหว่างเฟสต่าง ๆ ยังยกเลิกได้ตามปกติ
