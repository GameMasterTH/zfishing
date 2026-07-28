# Fishing NUI Bundle Rebuild Fix — Bugfix Design

## Overview

บั๊กนี้คือปัญหา **stale build artifact + deploy** ไม่ใช่ข้อผิดพลาดของ source code จาก spec ก่อนหน้า (`fishing-rig-menu-hud-style-fix`) ได้แก้ CSS ของ Rig_Menu ใน `web/src/style.css` ให้พื้นหลังโปร่งใสและตัวอักษรสีขาวมี `text-shadow` เรียบร้อยและผ่านการทดสอบระดับ source (`vitest`) ครบแล้ว แต่ไม่เคยรัน `npm run build` ทำให้ artifact ที่ FiveM โหลดจริง (`web/dist/`) ยังเป็นเวอร์ชันเก่าก่อนแก้ CSS

`fxmanifest.lua` ประกาศ `ui_page 'web/dist/index.html'` ดังนั้นในเกมจะโหลด bundle ที่ build แล้วจาก `web/dist/assets/*` ไม่ใช่ source โดยตรง ปัจจุบัน `web/dist/index.html` ชี้ไปที่ `index-DLW4jjFM.css` / `index-zLgQY8bw.js` ซึ่งเป็น bundle เก่า และ CSS ในนั้นยังมี `.rig-menu{...background:var(--bg);border:...;box-shadow:...;backdrop-filter:blur(4px)}` ไม่ตรงกับ source ที่แก้แล้ว นอกจากนี้เซิร์ฟเวอร์รัน resource เป็น**สำเนา** ที่ deploy path แยก (`.../[zlab]/zfishing/`) ซึ่งถือ bundle hash เดียวกัน (`index-DLW4jjFM.css` / `index-zLgQY8bw.js`) จึงยังไม่ได้รับการแก้ไขเลย

แนวทางแก้: **regenerate bundle จาก source ปัจจุบัน** ด้วย `npm run build` ใน `web/` แล้ว **deploy `web/dist/` ที่ได้ใหม่ไปทับสำเนา** ที่เซิร์ฟเวอร์รันจริง โดย**ไม่แตะ source ใดๆ** (Lua, React, DOM structure, `web/src/*`)

## Glossary

- **Bug_Condition (C)**: สภาวะที่กระตุ้นบั๊ก — Rig_Menu ถูก render จาก bundle ใน `web/dist/` ที่เนื้อหา CSS `.rig-menu` ยังไม่ตรงกับ `web/src/style.css` (artifact ค้างเก่า)
- **Property (P)**: พฤติกรรมที่ต้องการ — bundle ใน `web/dist/` (ทั้ง source repo และ deploy copy) ต้องมีเนื้อหา CSS ที่ตรงกับ source ปัจจุบัน (พื้นหลังโปร่งใส + `text-shadow` + สีขาว)
- **Preservation**: พฤติกรรมเดิมที่ต้องคงไว้ — `web/src/*`, โค้ด Lua ฝั่ง server/client, DOM structure ของ NUI, HUD components อื่น (CastBar, PromptHud, Admin panel, catch card) และ prompt `[G] จัดการเบ็ด` ที่โหลดจาก `locales/*.json`
- **Source repo**: โปรเจกต์ต้นทางที่พัฒนา — `e:\Web\ZCore\zfishing\`
- **Deploy copy**: สำเนา resource ที่เซิร์ฟเวอร์รันจริง — `c:\Users\GameMaster\Desktop\FiveM Server\txData\QBCore_E66DFA.base\resources\[zlab]\zfishing\`
- **Bundle**: ไฟล์ที่ Vite สร้างใน `web/dist/` ได้แก่ `index.html`, `assets/index-*.css`, `assets/index-*.js`, ฟอนต์ `*.woff`/`*.woff2`
- **Bundle hash**: ส่วน hash ในชื่อไฟล์ (เช่น `index-DLW4jjFM.css`) ที่ Vite สร้างจาก content — ถ้าเนื้อหาเปลี่ยน hash จะเปลี่ยนตาม

## Bug Details

### Bug Condition

บั๊กเกิดขึ้นเมื่อผู้เล่นกด G เปิด Rig_Menu ในเกม แล้ว FiveM โหลด CSS จาก bundle ใน `web/dist/` ที่ **rule `.rig-menu` ยังไม่ตรงกับ `web/src/style.css`** ปัจจุบัน กล่าวคือ artifact ที่ deploy ยังเป็นเวอร์ชันก่อนการแก้ CSS (มี `background: var(--bg)`, `box-shadow`, `backdrop-filter: blur(4px)` และตัวอักษรไม่มี `text-shadow`)

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input ของ type DeployedBundle
         (bundle ที่ถูกโหลดจริงในเกม ณ deploy path)
  OUTPUT: boolean

  RETURN sourceStyleCss มี rule .rig-menu แบบ transparent + text-shadow (แก้แล้ว)
         AND deployedRigMenuCss(input) NOT EQUAL sourceRigMenuCss
         (bundle ที่ deploy ยังมี background:var(--bg)/box-shadow/backdrop-filter
          และ title/label ไม่มี text-shadow)
END FUNCTION
```

### Examples

- **ในเกมจริง (บั๊ก)**: ผู้เล่นกด G → Rig_Menu แสดงเป็นกล่องพื้นหลังทึบสีดำ มีขอบ เงา และ blur / คาดหวัง = พื้นหลังโปร่งใส ตัวอักษรขาวมี text-shadow
- **`web/dist/assets/index-DLW4jjFM.css` (source repo)**: rule `.rig-menu{...background:var(--bg);border:1px solid var(--border);...box-shadow...backdrop-filter:blur(4px)}` / คาดหวัง = `background:transparent` และไม่มี `box-shadow`/`backdrop-filter`
- **Deploy copy `.../[zlab]/zfishing/web/dist/assets/`**: bundle hash `index-DLW4jjFM.css` + `index-zLgQY8bw.js` ตรงกับ artifact เก่าใน source repo (ยังไม่ได้รับ bundle ใหม่) / คาดหวัง = hash + เนื้อหาตรงกับ `web/dist` ที่ rebuild แล้ว
- **`web/src/style.css` (edge/อ้างอิง)**: `.rig-menu__title`, `.rig-menu__hint`, `.rig-menu__empty` มี `color: #fff` + `text-shadow` แล้ว — เป็น source of truth ที่ bundle ต้องสะท้อนออกมา

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- `web/src/*` ทั้งหมด (รวม `style.css`, `App.tsx`, components, hooks) ต้องไม่ถูกแก้ไข — source ถูกต้องแล้ว งานคือ regenerate artifact + deploy เท่านั้น
- HUD components อื่นที่อยู่ใน bundle เดียวกัน (CastBar, PromptHud, Admin panel, catch card ฯลฯ) ต้องแสดงผลและทำงานเหมือนเดิม
- prompt กลางล่าง `[G] จัดการเบ็ด` ที่โหลดจาก `locales/*.json` โดยตรง ต้องแสดงถูกต้องเหมือนเดิม
- โค้ดฝั่ง server Lua, client Lua และ DOM structure ของ NUI components ต้องไม่ถูกแตะต้อง
- `fxmanifest.lua` (`ui_page`, `files`) ต้องไม่ถูกแก้ไข — path bundle ยังเป็น `web/dist/` เหมือนเดิม

**Scope:**
ทุกสิ่งที่ไม่ใช่ "เนื้อหาของ compiled bundle ใน `web/dist/`" ต้องไม่ได้รับผลกระทบจากการแก้ครั้งนี้ ได้แก่:
- Source files ทั้งหมด (`web/src/*`, Lua, config, locales)
- โครงสร้าง/พฤติกรรมของ HUD components อื่นใน NUI
- การประกาศใน `fxmanifest.lua`

_หมายเหตุ:_ พฤติกรรมที่ถูกต้องที่ต้องการนิยามไว้ใน Correctness Properties (Property 1) ส่วนนี้เน้นว่าสิ่งใดต้อง **ไม่เปลี่ยน**

## Hypothesized Root Cause

จากการวิเคราะห์และตรวจสอบไฟล์จริง สาเหตุที่เป็นไปได้เรียงตามความมั่นใจ:

1. **Stale build artifact (สาเหตุหลัก — ยืนยันแล้ว)**: spec ก่อนหน้าแก้ `web/src/style.css` แต่ไม่รัน `npm run build` ทำให้ `web/dist/assets/index-DLW4jjFM.css` ยังเป็นเวอร์ชันเก่า
   - ยืนยัน: source `.rig-menu` = transparent + `#fff` + text-shadow แต่ dist `.rig-menu` = `background:var(--bg)` + `box-shadow` + `backdrop-filter:blur(4px)`
   - `web/dist/index.html` ยังชี้ไปที่ `index-DLW4jjFM.css` / `index-zLgQY8bw.js`

2. **Deploy copy ไม่ได้รับ bundle ใหม่ (สาเหตุร่วม — ยืนยันแล้ว)**: เซิร์ฟเวอร์รันสำเนาที่ deploy path แยก ซึ่งถือ bundle hash เดียวกัน (`index-DLW4jjFM.css` / `index-zLgQY8bw.js`) ต่อให้ rebuild source repo แต่ไม่ deploy ก็ยังเห็นบั๊ก

3. **NUI/asset cache ฝั่ง client (สาเหตุรอง)**: หลัง deploy อาจต้อง restart resource / refresh NUI เพื่อให้ FiveM โหลด bundle ใหม่ (โดยเฉพาะเมื่อ hash เปลี่ยน filename จะเปลี่ยน จึงเลี่ยง cache ระดับ filename ได้)

## Correctness Properties

Property 1: Bug Condition — Rebuilt bundle สะท้อน CSS ที่แก้แล้ว

_For any_ สภาวะที่ bug condition เป็นจริง (bundle ที่ deploy ยังมี `.rig-menu` แบบเก่า) หลัง rebuild `web/dist` จาก source ปัจจุบันและ deploy ไปยัง deploy copy แล้ว ระบบ SHALL ทำให้ bundle ที่โหลดจริงมี rule `.rig-menu` เป็น `background: transparent` (ไม่มี `box-shadow`/`backdrop-filter`/`var(--bg)` ใน rule นั้น) และ `.rig-menu__title`/`.rig-menu__hint`/`.rig-menu__empty`/`.rig-row__label`/`.rig-row__owned` มี `text-shadow` + ตัวอักษรสีขาว (`#fff`) ตรงกับ `web/src/style.css` ส่งผลให้ผู้เล่นกด G เห็นเมนูพื้นหลังโปร่งใสพร้อม text-shadow

**Validates: Requirements 2.1, 2.2, 2.3, 2.4**

Property 2: Preservation — Source และ component อื่นไม่เปลี่ยน

_For any_ สิ่งที่ bug condition ไม่ครอบคลุม (ทุกอย่างที่ไม่ใช่เนื้อหา compiled bundle ของ Rig_Menu) ระบบ SHALL คงพฤติกรรมเดิมทั้งหมด ได้แก่ `web/src/*`, โค้ด Lua ฝั่ง server/client, DOM structure ของ NUI, HUD components อื่นใน bundle เดียวกัน (CastBar, PromptHud, Admin panel, catch card), prompt `[G] จัดการเบ็ด` จาก `locales/*.json` และการประกาศใน `fxmanifest.lua`

**Validates: Requirements 3.1, 3.2, 3.3, 3.4**

## Fix Implementation

### Changes Required

การแก้ทั้งหมดเป็น **build + deploy operations ไม่มีการแก้ source code**

**ขั้นตอนที่ 1 — Rebuild bundle จาก source (Source repo)**

- **Path**: `e:\Web\ZCore\zfishing\web\`
- **คำสั่ง**: `npm run build` (เท่ากับ `tsc && vite build`)
- **ผลลัพธ์คาดหวัง**:
  1. Vite regenerate `web/dist/index.html` + `web/dist/assets/index-*.css` + `web/dist/assets/index-*.js` ใหม่ (`emptyOutDir: true` จะล้าง dist เก่าก่อน)
  2. เนื่องจาก content เปลี่ยน (CSS มีการแก้) **bundle hash จะเปลี่ยน** จาก `index-DLW4jjFM.css` เป็น hash ใหม่ และ `index.html` จะชี้ไปที่ไฟล์ hash ใหม่โดยอัตโนมัติ
  3. CSS ใหม่ต้องมี `.rig-menu{...background:transparent...}` (ไม่มี `box-shadow`/`backdrop-filter`/`var(--bg)` ใน `.rig-menu`) และ selector ข้อความมี `text-shadow` + `#fff`

**ขั้นตอนที่ 2 — Deploy bundle ไปยัง resource ที่รันจริง (Deploy copy)**

- **Source**: `e:\Web\ZCore\zfishing\web\dist\`
- **Destination**: `c:\Users\GameMaster\Desktop\FiveM Server\txData\QBCore_E66DFA.base\resources\[zlab]\zfishing\web\dist\`
- **วิธี**: คัดลอกทับทั้งโฟลเดอร์ `web/dist/` (แนะนำลบ dist เดิมใน deploy copy ก่อน copy เพื่อไม่ให้ไฟล์ hash เก่าค้างอยู่ เพราะ Vite ตั้ง filename ตาม hash — ไฟล์เก่าจะไม่ถูกเขียนทับโดยไฟล์ใหม่)
- **ผลลัพธ์คาดหวัง**: deploy copy มี `web/dist/` ที่มีเนื้อหาและ hash ตรงกับ source repo ทุกไฟล์

**ขั้นตอนที่ 3 — Reload resource เพื่อให้ FiveM โหลด bundle ใหม่**

- restart resource `zfishing` บนเซิร์ฟเวอร์ (เช่น `ensure zfishing` / `restart zfishing`) หรือให้ผู้ใช้ทำใน server console
- **ผลลัพธ์คาดหวัง**: FiveM โหลด `ui_page` จาก bundle ใหม่ ผู้เล่นกด G เห็นเมนูโปร่งใส

**ข้อควรระวัง (สิ่งที่ห้ามทำ):**
- ห้ามแก้ไฟล์ใน `web/src/*`
- ห้ามแก้ `fxmanifest.lua`
- ห้ามแก้ Lua ฝั่ง server/client หรือ DOM structure ของ component

## Testing Strategy

### Validation Approach

กลยุทธ์การทดสอบใช้สองเฟส: เฟสแรก surface counterexample ที่พิสูจน์บั๊กบน artifact เก่า (ก่อน rebuild) เพื่อยืนยัน root cause จากนั้นเฟสสอง verify ว่า bundle ที่ rebuild + deploy แล้วถูกต้องและ preserve ทุกอย่างที่ไม่เกี่ยวข้อง เนื่องจากบั๊กนี้เป็นเรื่อง build artifact การทดสอบจึงเป็นการ **assert เนื้อหาไฟล์ที่ deploy** (content/hash diffing) เป็นหลัก ไม่ใช่ unit test ของ logic

### Exploratory Bug Condition Checking

**Goal**: Surface counterexample ที่แสดงบั๊กก่อนแก้ ยืนยันว่า artifact เก่ามีเนื้อหาไม่ตรง source (ถ้าพบว่าตรงกันอยู่แล้ว ต้อง re-hypothesize เพราะ root cause อาจอยู่ที่ cache หรือ path อื่น)

**Test Plan**: ตรวจเนื้อหา `.rig-menu` ใน bundle CSS ที่ deploy จริง เทียบกับ `web/src/style.css` บน artifact ที่ยังไม่ rebuild เพื่อสังเกต mismatch

**Test Cases**:
1. **Source vs Dist CSS diff (source repo)**: อ่าน `.rig-menu` จาก `web/dist/assets/index-DLW4jjFM.css` แล้ว assert ว่ามี `background:var(--bg)`/`box-shadow`/`backdrop-filter` (จะพบ mismatch บน artifact เก่า — พิสูจน์บั๊ก)
2. **Deploy copy stale hash**: assert ว่า deploy copy มีไฟล์ `index-DLW4jjFM.css` / `index-zLgQY8bw.js` (hash เก่า) อยู่ (จะพบบน artifact เก่า — พิสูจน์บั๊ก)
3. **Title/label text-shadow absence**: assert ว่า dist CSS เก่า `.rig-menu__title`/`.rig-menu__empty` ไม่มี `text-shadow` (จะพบบน artifact เก่า)

**Expected Counterexamples**:
- dist CSS `.rig-menu` = `background:var(--bg);...box-shadow...backdrop-filter:blur(4px)` ในขณะที่ source = transparent
- Possible causes: ไม่ได้รัน `npm run build`, ไม่ได้ deploy ไป copy, หรือ NUI cache

### Fix Checking

**Goal**: ยืนยันว่าสำหรับสภาวะที่ bug condition เป็นจริง หลัง rebuild + deploy แล้ว bundle ให้พฤติกรรมที่ถูกต้อง

**Pseudocode:**
```
FOR ALL bundle WHERE isBugCondition(bundle) DO
  runBuild()          // npm run build ใน web/
  deployToCopy()      // copy web/dist -> deploy path
  result := loadDeployedBundle()
  ASSERT expectedBehavior(result)
    // .rig-menu ใน deployed CSS = transparent, ไม่มี box-shadow/backdrop-filter/var(--bg)
    // .rig-menu__title/__hint/__empty/.rig-row__label/.rig-row__owned มี text-shadow + #fff
    // deploy copy hash == source repo dist hash
END FOR
```

**Test Cases (หลัง rebuild + deploy)**:
1. **Rebuilt CSS transparent**: assert `.rig-menu` ใน `web/dist/assets/index-*.css` (repo) มี `background:transparent` และไม่มี `box-shadow`/`backdrop-filter`/`var(--bg)` ใน rule
2. **Rebuilt CSS text-shadow**: assert `.rig-menu__title`/`.rig-menu__hint`/`.rig-menu__empty`/`.rig-row__label`/`.rig-row__owned` มี `text-shadow` + `#fff`
3. **index.html points to new hash**: assert `web/dist/index.html` อ้าง filename hash ใหม่ (ไม่ใช่ `index-DLW4jjFM.css`/`index-zLgQY8bw.js`)
4. **Deploy parity**: assert รายชื่อไฟล์ + เนื้อหาใน deploy copy `web/dist/` ตรงกับ source repo `web/dist/` (hash match)

### Preservation Checking

**Goal**: ยืนยันว่าสำหรับสิ่งที่ bug condition ไม่ครอบคลุม bundle ใหม่ให้ผลเหมือนเดิม

**Pseudocode:**
```
FOR ALL artifact WHERE NOT isBugCondition(artifact) DO
  ASSERT original(artifact) = rebuilt(artifact)
    // web/src/* ไม่เปลี่ยน
    // Lua/DOM/fxmanifest ไม่เปลี่ยน
    // CSS ของ CastBar/PromptHud/Admin/catch card ไม่เปลี่ยนเชิงพฤติกรรม
END FOR
```

**Testing Approach**: property-based testing เหมาะกับ preservation เพราะสามารถ generate หลายกรณีข้าม input domain และจับ edge case ที่ manual test พลาด — ในที่นี้คือ generate/ตรวจหลาย CSS selector ของ component อื่นเพื่อยืนยันว่าไม่เปลี่ยน โดยสังเกตพฤติกรรมบน artifact เดิมก่อน แล้วเขียน test จับพฤติกรรมนั้น

**Test Cases**:
1. **Source untouched**: สังเกตว่า `web/src/*` ไม่ถูกแก้ระหว่างงานนี้ (git diff = ว่างสำหรับ `web/src`, Lua, `fxmanifest.lua`) แล้ว assert
2. **Other HUD components preserved**: สังเกต CSS/DOM ของ CastBar, PromptHud, Admin panel, catch card ใน bundle เดิมทำงานถูก แล้ว assert ว่าใน bundle ใหม่ selector/พฤติกรรมยังเหมือนเดิม
3. **Prompt from locales preserved**: สังเกต prompt `[G] จัดการเบ็ด` โหลดจาก `locales/*.json` ถูกต้องบนโค้ดเดิม แล้ว assert ว่ายังถูกต้องหลัง rebuild (ไม่เกี่ยวกับ bundle)
4. **fxmanifest unchanged**: assert `ui_page` และ `files` ใน `fxmanifest.lua` ไม่เปลี่ยน

### Unit Tests

- Assert เนื้อหา `.rig-menu` (transparent, ไม่มี box-shadow/backdrop-filter) ใน rebuilt dist CSS
- Assert เนื้อหา text-shadow ของ title/hint/empty/row labels ใน rebuilt dist CSS
- Assert `web/dist/index.html` ชี้ไป bundle hash ใหม่
- Assert deploy copy `web/dist/` มีไฟล์และเนื้อหาตรงกับ source repo (hash parity)

### Property-Based Tests

- Generate รายการ CSS selector ของ HUD components อื่น (CastBar/PromptHud/Admin/catch card) แล้วยืนยันว่า declaration ใน bundle ใหม่ตรงกับ bundle เดิม (preservation)
- Generate/ตรวจทุกไฟล์ใน `web/dist/assets/` ยืนยันว่าชุดไฟล์ใน deploy copy = source repo (ไม่มีไฟล์ hash เก่าค้าง, ไม่มีไฟล์ขาด)

### Integration Tests

- ทดสอบ full flow ในเกม: กด G เปิด Rig_Menu → เห็นพื้นหลังโปร่งใส + text-shadow (ไม่เป็นกล่องดำ) หลัง rebuild + deploy + restart resource
- ทดสอบว่า HUD อื่น (CastBar ขณะเหวี่ยง, PromptHud, Admin panel) ยังแสดงผลปกติหลังโหลด bundle ใหม่
- ทดสอบ prompt `[G] จัดการเบ็ด` ยังแสดงถูกต้องในเกม
