# Fishing Rig Menu HUD Style Fix — Bugfix Design

## Overview

บั๊กนี้เป็น follow-up จากสองสเปคที่ implement ไปแล้ว (`fishing-rig-menu-nui` และ `fishing-prompt-hud`) มี 2 อาการที่ต้องแก้ในฝั่งการนำเสนอ (presentation layer) เท่านั้น — **ไม่มีการแก้ไขฝั่ง server และไม่แตะ logic การเปิด/ปิดเมนูหรือ lifecycle การตกปลา**:

1. **Rig_Menu (NUI)** ถูกเรนเดอร์เป็นกล่องพื้นหลังทึบสีเข้ม (`background: var(--bg)` + `border` + `border-left` accent + `box-shadow` + `backdrop-filter: blur`) ทำให้ไม่กลมกลืนกับ HUD ตกปลา ต้องเปลี่ยนเป็นเมนูแบบ HUD โปร่งใสทั้งหมด ตัวอักษรสีขาวมี text-shadow (หัวข้อตัวใหญ่, บรรทัดคำใบ้ "กด ESC เพื่อปิด", แต่ละแถว = icon + ชื่อ + จำนวน บนพื้นหลังโปร่งใส)
2. **Prompt_HUD** ช่วง equip standby แสดง subtitle `[E] เริ่มตกปลา · [X] เก็บเบ็ด` แต่ขาดคำใบ้ `[G] จัดการเบ็ด` (en: `[G] Manage Rod`) ต้องเพิ่มคำใบ้ปุ่ม G ต่อท้าย

กลยุทธ์การแก้:
- อาการ 1 เป็น **CSS-only fix** ใน `web/src/style.css` (คลาส `.rig-menu`, `.rig-menu__*`, `.rig-row*`) — เอา solid background / border box / box-shadow / backdrop blur ออก และเพิ่ม `text-shadow` ให้ตัวอักษร โครงสร้าง DOM ของ `RigMenu.tsx` ไม่เปลี่ยน
- อาการ 2 เป็น **locale-value fix** — อัปเดตค่า `equip_hint` ใน `locales/th.json` + `locales/en.json` (ครอบทั้ง NUI `getLocale` และ TextUI fallback) และอัปเดตตาราง `FALLBACK` ใน `web/src/promptText.ts` เพื่อให้ `resolvePromptText('equip_hint')` มีคำใบ้ `[G]` เสมอแม้ dict ว่าง (test/นอก FiveM)

## Glossary

- **Bug_Condition (C)**: เงื่อนไขที่ทำให้บั๊กปรากฏ — RenderContext ที่ surface เป็น `rig_menu` (เมนูถูกเรนเดอร์) หรือ surface เป็น `prompt_hud` และ phase เป็น `equip_standby`
- **Property (P)**: พฤติกรรมที่ถูกต้องเมื่อเข้าเงื่อนไขบั๊ก — Rig_Menu โปร่งใส + text-shadow และ subtitle ช่วง equip standby มีคำใบ้ `[G]`
- **Preservation (¬C)**: พฤติกรรมเดิมของ input ที่ไม่ใช่เงื่อนไขบั๊ก (เปิด/ปิดเมนู G/ESC, attach/detach, server callbacks, HUD ช่วง cancel/reeling, locale fallback, TextUI fallback) ที่ต้องคงเดิมทุกประการ
- **F / F'**: โค้ดก่อนแก้ (Rig_Menu กล่องทึบ, subtitle ไม่มี `[G]`) / โค้ดหลังแก้ (Rig_Menu โปร่งใส + text-shadow, subtitle มี `[G]`)
- **RigMenu (`web/src/components/RigMenu.tsx`)**: NUI component ที่เรนเดอร์เมนูจัดการเบ็ด — โครงสร้าง header (title + hint + locale-error) และ list ของ `RigRowItem` (icon + label + owned)
- **PromptHud (`web/src/components/PromptHud.tsx`)**: NUI component ที่เรนเดอร์ prompt กลางล่างจอเป็น title + subtitle จาก locale key
- **resolvePromptText (`web/src/promptText.ts`)**: ฟังก์ชันคืนค่าข้อความ prompt จาก dict ผ่าน `tOr(key, fallback)` ถ้าไม่ว่างหลัง trim มิฉะนั้นคืน `FALLBACK[key]`
- **showPrompt / PROMPT_HUD (`client/main.lua`)**: เมื่อ `Config.PromptHud` เป็น true ส่ง `SendNUIMessage({ action='prompt', titleKey, subtitleKey })`; เมื่อ false เรียก `lib.showTextUI(locale(subtitleKey))` — ทั้งคู่ใช้ subtitle key `equip_hint`
- **equip_standby**: ช่วงที่ผู้เล่นถือเบ็ดพร้อมแล้วแต่ยังไม่ขว้าง (`ZClient.standby == true`) — เป็นช่วงเดียวที่ปุ่ม G เปิด Rig_Menu ได้

## Bug Details

### Bug Condition

บั๊กปรากฏเมื่อ (1) Rig_Menu ถูกเรนเดอร์ ทำให้เห็นกล่องพื้นหลังทึบ + ตัวอักษรไม่มี text-shadow หรือ (2) Prompt_HUD อยู่ช่วง equip standby ทำให้ subtitle ไม่มีคำใบ้ปุ่ม G สาเหตุอยู่ที่ CSS ของ `.rig-menu` ที่ยังยึด panel theme เดิม และค่า locale `equip_hint` ที่ยังไม่มี `[G]`

**Formal Specification:**
```
FUNCTION isBugCondition(X)
  INPUT: X of type RenderContext
  OUTPUT: boolean

  RETURN (X.surface = 'rig_menu')
      OR (X.surface = 'prompt_hud' AND X.phase = 'equip_standby')
END FUNCTION
```

### Examples

- **Rig_Menu**: ผู้เล่นกด G ในช่วง equip standby → เมนูเปิดเป็นกล่องทึบสีเข้ม (`background: var(--bg)`, `border`, `box-shadow`, `backdrop-filter: blur`) — ที่ถูกต้องคือ พื้นหลังโปร่งใสทั้งหมด ตัวอักษรขาวมี text-shadow
- **Rig_Menu title/hint**: หัวข้อ "จัดการเบ็ด" และคำใบ้ "กด ESC เพื่อปิด" แสดงโดยไม่มี text-shadow — ที่ถูกต้องคือ มี text-shadow ให้อ่านได้บนพื้นหลังเกม
- **Prompt_HUD equip standby**: subtitle แสดง `[E] เริ่มตกปลา   ·   [X] เก็บเบ็ด` — ที่ถูกต้องคือ `[E] เริ่มตกปลา   ·   [X] เก็บเบ็ด   ·   [G] จัดการเบ็ด`
- **Edge case (dict ว่าง / นอก FiveM)**: `resolvePromptText('equip_hint')` คืนค่าจาก `FALLBACK` — ต้องมี `[G] Manage Rod` ด้วยเช่นกัน

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- การเปิด/ปิดเมนูด้วยปุ่ม G (toggle ในช่วง equip standby) และ ESC ยังทำงานเหมือนเดิม (`rigCommand`, `closeMenu`, `SetNuiFocus`)
- การ attach/detach ชิ้นส่วนผ่าน NUI callback `rigAction` → server callbacks `zfishing:rig:attach` / `zfishing:rig:detach` (args ไม่เปลี่ยน) และการ refresh view ผ่าน `zfishing:rig:get`
- โครงสร้าง/ลำดับแถวจาก `buildRigRows`, การ dim แถวที่ owned = 0, กล่อง icon ขนาดคงที่เมื่อรูปโหลดไม่ได้, ข้อความ empty/locale-error
- HUD ช่วง cancel/reeling (`cancel_title` / `cancel_hint`), title `equip_title` (`การตกปลา`) และคำสั่ง `[E]` / `[X]` เดิม พร้อม layout กลางล่างจอ
- locale fallback ไทย/อังกฤษ และเมื่อ `getLocale` โหลดไม่สำเร็จ (dict ว่าง → ใช้ FALLBACK)
- TextUI fallback เมื่อ `Config.PromptHud = false` (`lib.showTextUI(locale('equip_hint'))`)

**Scope:**
ทุก input ที่ไม่เข้าเงื่อนไขบั๊ก (surface ≠ `rig_menu` และไม่ใช่ `prompt_hud` ช่วง `equip_standby`) ต้องไม่ได้รับผลกระทบจากการแก้นี้ ได้แก่:
- Prompt_HUD ช่วง cancel/reeling
- CastBar, WaitingHud, TensionMinigame, CatchCard, FishingInfoCard (คอมโพเนนต์ HUD อื่น)
- Logic ฝั่ง server และ anti-cheat ทั้งหมด (ไม่มีการแก้ server)

_หมายเหตุ: พฤติกรรมที่ถูกต้องเมื่อเข้าเงื่อนไขบั๊ก ระบุไว้ใน Correctness Properties (Property 1) — ส่วนนี้เน้นสิ่งที่ต้อง **ไม่** เปลี่ยน_

## Hypothesized Root Cause

จากการอ่านโค้ดจริง สาเหตุที่เป็นไปได้มากที่สุดคือ:

1. **CSS ของ `.rig-menu` ยึด panel theme เดิม**: ใน `web/src/style.css` คลาส `.rig-menu` ประกาศ `background: var(--bg)`, `border: 1px solid var(--border)`, `border-left: 2px solid var(--accent)`, `box-shadow: var(--shadow)` และ `backdrop-filter: blur(4px)` ทำให้เกิดกล่องทึบ

2. **ตัวอักษรไม่มี text-shadow**: คลาส `.rig-menu__title`, `.rig-menu__hint`, `.rig-row__label`, `.rig-row__owned` ไม่ได้กำหนด `text-shadow` เมื่อพื้นหลังโปร่งใสจึงอ่านยากและไม่เข้าชุดกับ HUD ตกปลา

3. **ค่า locale `equip_hint` ยังไม่มีคำใบ้ G**: ทั้ง `locales/th.json` และ `locales/en.json` เก็บ `equip_hint` เป็น `[E] ... · [X] ...` โดยไม่มี `[G]` และตาราง `FALLBACK` ใน `web/src/promptText.ts` ก็ยังไม่มี `[G]` เช่นกัน

4. **แหล่งข้อความ prompt เป็น locale value เดียว**: เพราะทั้ง NUI (`resolvePromptText` → `getLocale` dict) และ TextUI fallback (`lib.showTextUI(locale('equip_hint'))`) อ่านจาก key `equip_hint` เดียวกัน การแก้ที่ค่า locale จึงครอบทั้งสอง path โดยไม่ต้องเพิ่ม logic

## Correctness Properties

Property 1: Bug Condition — Rig_Menu โปร่งใส + text-shadow

_For any_ RenderContext ที่เข้าเงื่อนไขบั๊กด้วย `surface = 'rig_menu'` (isBugCondition คืน true) เมนูที่แก้แล้ว (RigMenu') SHALL เรนเดอร์โดยไม่มีพื้นหลังทึบ (no solid background), ไม่มีเส้นขอบกล่อง (no box border), ไม่มี box-shadow และไม่มี backdrop blur ที่ทำให้เกิดกล่องทึบ พร้อมทั้งตัวอักษรมี text-shadow ในสไตล์เดียวกับ HUD ตกปลา

**Validates: Requirements 2.1, 2.2**

Property 2: Bug Condition — คำใบ้ปุ่ม G ในช่วง equip standby

_For any_ RenderContext ที่เข้าเงื่อนไขบั๊กด้วย `surface = 'prompt_hud'` และ `phase = 'equip_standby'` (isBugCondition คืน true) ค่า `resolvePromptText('equip_hint')` SHALL มีสตริง `[G]` และมีคำว่า `จัดการเบ็ด` (ไทย) หรือ `Manage Rod` (อังกฤษ) ต่อท้ายคำใบ้ `[E]` / `[X]` เดิม

**Validates: Requirements 2.3**

Property 3: Preservation — Input นอกเงื่อนไขบั๊กไม่เปลี่ยนแปลง

_For any_ input ที่ไม่เข้าเงื่อนไขบั๊ก (isBugCondition คืน false เช่น HUD ช่วง cancel/reeling, การเปิด/ปิดเมนู G/ESC, attach/detach, server callbacks, locale fallback, TextUI fallback) โค้ดที่แก้แล้ว (F') SHALL ให้ผลลัพธ์เหมือนโค้ดเดิม (F) ทุกประการ

**Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5**

## Fix Implementation

### Changes Required

สมมติว่าการวิเคราะห์ root cause ถูกต้อง การแก้แบ่งเป็น 3 ไฟล์ (ฝั่ง presentation เท่านั้น):

**File 1**: `web/src/style.css`

**Target**: คลาส `.rig-menu` และคลาสข้อความที่เกี่ยวข้อง

**Specific Changes**:
1. **ลบพื้นหลัง/ขอบ/เงา/blur ออกจาก `.rig-menu`**: เอา `background: var(--bg)`, `border`, `border-left`, `box-shadow`, `backdrop-filter: blur(4px)` ออก ให้ `background: transparent` เหลือไว้แต่ layout (position กึ่งกลางแนวตั้งฝั่งขวา, `pointer-events: auto`) — ยังต้องรับคลิกเมาส์เพื่อ attach/detach
2. **เพิ่ม text-shadow ให้ตัวอักษร**: เพิ่ม `text-shadow` (เช่น `0 1px 3px rgba(0,0,0,0.9)`) และปรับสีเป็นขาว (`color: #fff` / `var(--text)`) ให้กับ `.rig-menu__title`, `.rig-menu__hint`, `.rig-menu__empty`, `.rig-menu__locale-error`, `.rig-row__label`, `.rig-row__owned` ให้เข้าชุดกับ Prompt_HUD
3. **ปรับ `.rig-row` / `.rig-row__icon` ให้เข้าธีมโปร่งใส**: คง box icon ขนาดคงที่ (กันแถวเลื่อนเมื่อรูปโหลดไม่ได้ — R2.7 เดิม) แต่ให้พื้นหลัง/hover ไม่สร้างกล่องทึบ (คง `:hover` แบบ subtle หรือปรับตามสไตล์ HUD)
4. **หัวข้อตัวใหญ่ + บรรทัด "กด ESC เพื่อปิด"**: คงโครงสร้าง header เดิม (title ตัวใหญ่, hint ด้านล่าง) — ปรับขนาด/สไตล์ให้ล้อ Prompt_HUD (`.prompt-title` / `.prompt-subtitle`)

**File 2**: `locales/th.json` และ `locales/en.json`

**Target**: key `equip_hint`

**Specific Changes**:
5. **เพิ่มคำใบ้ปุ่ม G ต่อท้าย**:
   - th: `"equip_hint": "[E] เริ่มตกปลา   ·   [X] เก็บเบ็ด   ·   [G] จัดการเบ็ด"`
   - en: `"equip_hint": "[E] Start fishing   ·   [X] Pack up rod   ·   [G] Manage Rod"`
   - การแก้ที่ค่า locale นี้ครอบทั้ง NUI (`getLocale` → `resolvePromptText`) และ TextUI fallback (`lib.showTextUI(locale('equip_hint'))` เมื่อ `Config.PromptHud = false`) → ครอบ R3.5

**File 3**: `web/src/promptText.ts`

**Target**: ตาราง `FALLBACK`

**Specific Changes**:
6. **อัปเดต fallback ของ `equip_hint`** ให้ตรงกับ locale ใหม่ (มี `[G] Manage Rod`) เพื่อให้ `resolvePromptText('equip_hint')` มีคำใบ้ `[G]` เสมอ แม้ dict ว่าง (นอก FiveM / unit test / getLocale ล้มเหลว)
   - _หมายเหตุ_: ต้องอัปเดต `FALLBACK` ที่ hard-code ไว้ในไฟล์ test (`web/src/__tests__/promptText.test.ts`) ให้ตรงกันด้วย มิฉะนั้น property test เดิมจะ fail

**ห้ามแตะ:**
- `client/rig.lua` (logic เปิด/ปิด G/ESC, attach/detach, callbacks) — ไม่เปลี่ยน
- `client/main.lua` logic lifecycle และ `showPrompt`/`hidePrompt`/`PROMPT_HUD` — key ยังคงเป็น `equip_hint`
- โครงสร้าง DOM ใน `RigMenu.tsx` / `PromptHud.tsx`
- ฝั่ง server ทั้งหมด

## Testing Strategy

### Validation Approach

ทำสองเฟส: เฟสแรก surface counterexample ที่แสดงบั๊กบนโค้ดที่ยังไม่แก้ (unfixed) เพื่อยืนยัน root cause จากนั้นยืนยันว่าการแก้ทำงานถูกต้องและไม่ทำ regression กับพฤติกรรมเดิม

### Exploratory Bug Condition Checking

**Goal**: Surface counterexample ที่แสดงบั๊กก่อนแก้ เพื่อยืนยัน/หักล้าง root cause ถ้าหักล้างต้อง re-hypothesize

**Test Plan**: เขียน test render `RigMenu` และตรวจ computed style ของ `.rig-menu` รวมถึงตรวจค่า `resolvePromptText('equip_hint')` รันบนโค้ด **unfixed** เพื่อดูว่า fail ตามคาด

**Test Cases**:
1. **Rig_Menu solid background**: render `RigMenu` แล้ว assert ว่า `.rig-menu` ไม่มี solid background / box-shadow / border box (จะ fail บน unfixed เพราะยังมี `var(--bg)` + `box-shadow`)
2. **Rig_Menu text-shadow**: assert ว่า `.rig-menu__title` / `.rig-row__label` มี `text-shadow` (จะ fail บน unfixed)
3. **equip_hint มี [G]**: assert ว่า `resolvePromptText('equip_hint')` มี `[G]` และ `จัดการเบ็ด`/`Manage Rod` (จะ fail บน unfixed)
4. **Edge — dict ว่าง**: ตั้ง dict = {} แล้ว assert `resolvePromptText('equip_hint')` (FALLBACK) มี `[G]` (จะ fail บน unfixed)

**Expected Counterexamples**:
- `.rig-menu` มี background ทึบ + box-shadow + backdrop blur
- `resolvePromptText('equip_hint')` = `[E] ... · [X] ...` ไม่มี `[G]`
- สาเหตุที่เป็นไปได้: CSS panel theme เดิม, ค่า locale/FALLBACK เดิม

### Fix Checking

**Goal**: ยืนยันว่าสำหรับทุก input ที่เข้าเงื่อนไขบั๊ก ฟังก์ชันที่แก้แล้วให้พฤติกรรมที่คาดหวัง

**Pseudocode:**
```
// Rig_Menu โปร่งใส + text-shadow
FOR ALL X WHERE isBugCondition(X) AND X.surface = 'rig_menu' DO
  render := RigMenu'(X)
  ASSERT no_solid_background(render)
     AND no_box_border(render)
     AND no_box_shadow(render)
     AND has_text_shadow(render)
END FOR

// คำใบ้ปุ่ม G ใน equip standby
FOR ALL X WHERE isBugCondition(X) AND X.surface = 'prompt_hud' AND X.phase = 'equip_standby' DO
  subtitle := resolvePromptText('equip_hint')
  ASSERT contains(subtitle, '[G]')
     AND (contains(subtitle, 'จัดการเบ็ด') OR contains(subtitle, 'Manage Rod'))
END FOR
```

### Preservation Checking

**Goal**: ยืนยันว่าสำหรับทุก input ที่ไม่เข้าเงื่อนไขบั๊ก ฟังก์ชันที่แก้แล้วให้ผลเหมือนฟังก์ชันเดิม

**Pseudocode:**
```
FOR ALL X WHERE NOT isBugCondition(X) DO
  ASSERT F(X) = F'(X)
END FOR
```

**Testing Approach**: ใช้ property-based testing สำหรับ preservation เพราะ:
- generate test case จำนวนมากอัตโนมัติทั่ว input domain (locale key, dict states)
- จับ edge case ที่ unit test ตกหล่น
- ให้การรับประกันที่แข็งแรงว่าพฤติกรรมไม่เปลี่ยนสำหรับทุก input นอกเงื่อนไขบั๊ก

**Test Plan**: สังเกตพฤติกรรมบนโค้ด unfixed ของ input นอกเงื่อนไขบั๊กก่อน แล้วเขียน property test จับพฤติกรรมนั้น

**Test Cases**:
1. **cancel/reeling prompt ไม่เปลี่ยน**: `resolvePromptText('cancel_hint')` / `resolvePromptText('cancel_title')` / `resolvePromptText('equip_title')` คืนค่าเดิมทั้งก่อนและหลังแก้ (PBT: สุ่ม dict states)
2. **RigMenu DOM/logic เดิม**: จำนวนแถว, ลำดับจาก `buildRigRows`, การ dim owned = 0, empty state, locale-error, การ dispatch `rigClose` เมื่อกด ESC, การ dispatch `rigAction` (attach/detach) ยังเหมือนเดิม
3. **locale fallback เดิม**: เมื่อ dict ไม่มี key อื่น (ที่ไม่ใช่ `equip_hint`) `resolvePromptText`/`rigText` ยังคืน fallback/ไม่คืน raw key เหมือนเดิม (PBT)
4. **TextUI fallback**: เมื่อ `Config.PromptHud = false` path `lib.showTextUI(locale('equip_hint'))` ยังทำงาน (แสดงค่าใหม่ที่มี `[G]` ตาม R3.5) และ key ที่เรียกไม่เปลี่ยน

### Unit Tests

- render `RigMenu` แล้วตรวจ computed style: ไม่มี solid background / border box / box-shadow, มี text-shadow ที่ title และ row label
- `resolvePromptText('equip_hint')` มี `[G]` + `จัดการเบ็ด`/`Manage Rod` ทั้งกรณี dict มีค่า (จาก locale ใหม่) และ dict ว่าง (จาก FALLBACK)
- ESC ในเมนู → เรียก `fetchNui('rigClose')`; คลิกแถว → `fetchNui('rigAction', ...)` args เดิม

### Property-Based Tests

- **Fix (equip_hint)**: สำหรับ dict states ที่สุ่ม (มี key / ไม่มี key / ค่าว่าง) `resolvePromptText('equip_hint')` ต้องมี `[G]` เสมอ (จาก locale value หรือ FALLBACK)
- **Preservation (prompt keys อื่น)**: สำหรับทุก key ∈ {`equip_title`, `cancel_title`, `cancel_hint`} และ dict states ที่สุ่ม ผลของ `resolvePromptText` ต้องเท่ากับพฤติกรรมเดิม
- **Preservation (RigMenu rows)**: สุ่ม `view` + `catalog` แล้ว assert จำนวน/ลำดับแถวและการ dim ไม่เปลี่ยนจากเดิม

### Integration Tests

- Flow เต็ม: เข้า equip standby → Prompt_HUD แสดง `การตกปลา` + subtitle ที่มี `[E] · [X] · [G]` → กด G เปิด Rig_Menu (โปร่งใส + text-shadow) → attach/detach → กด ESC ปิด → prompt กลับมาแสดงเหมือนเดิม
- สลับภาษา th/en: subtitle และ Rig_Menu แสดงข้อความถูกภาษา และเมื่อ `getLocale` ล้มเหลว (dict ว่าง) ยัง fallback ได้พร้อมคำใบ้ `[G]`
- `Config.PromptHud = false`: TextUI แสดง `equip_hint` ที่มี `[G]` และ cancel path ยังทำงานเดิม
