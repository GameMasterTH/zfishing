# Rig Menu Icon Oversize Fix — Bugfix Design

## Overview

บั๊กนี้เกิดในเมนู NUI `Rig_Menu` ของ zfishing: รูป icon ของ item แต่ละแถวเรนเดอร์ที่ **ขนาดพิกเซลจริง (natural/intrinsic size)** ของไฟล์ PNG แทนที่จะย่อให้พอดีกล่อง `.rig-row__icon` ขนาดคงที่ `3.2vh × 3.2vh` ทำให้รูปล้นออกนอกกล่องไปทับข้อความ `.rig-row__label` / `.rig-row__owned` และทับแถวข้างเคียง ผู้เล่นจึงเห็นเป็นวงกลมใหญ่ซ้อนทับกันแทนรายการที่เรียงเป็นระเบียบ

**สาเหตุ (ยืนยันจาก source แล้ว):** ใน `web/src/style.css` กฎ `.rig-row__icon` เป็น `<div>` container ที่กำหนด `width: 3.2vh; height: 3.2vh; object-fit: contain;` แต่ `object-fit` มีผลเฉพาะกับ replaced element (เช่น `<img>`) ไม่มีผลกับ `<div>` และ **ไม่มีกฎ CSS ใด ๆ ที่กำหนดขนาดให้ `<img>` ภายใน `.rig-row__icon`** (ไม่มี `.rig-row__icon img { ... }`) เมื่อ `<img>` ไม่ถูกจำกัดขนาดและ container ไม่มี `overflow: hidden` รูปจึงเรนเดอร์ที่ขนาด PNG จริงและล้นออกไปทับส่วนอื่น (ยืนยันจาก `RigMenu.tsx` ว่า DOM คือ `<div className="rig-row__icon"><img .../></div>`)

**กลยุทธ์การแก้:** แก้ **CSS ที่ source เท่านั้น** — เพิ่มกฎ `.rig-row__icon img` ให้ `width:100%; height:100%; object-fit:contain; display:block` และเพิ่ม `overflow:hidden` ให้ container `.rig-row__icon` เพื่อกันการล้นในทุกกรณี จากนั้นทำกระบวนการ deploy ให้ครบ (rebuild bundle → deploy `web/dist/` → restart resource) เพราะ FiveM โหลด bundle ที่ build แล้ว ไม่ใช่ source โดยตรง **ไม่แตะ** DOM (`RigMenu.tsx`), Lua, หรือ `fxmanifest.lua`

## Glossary

- **Bug_Condition (C)**: เงื่อนไขที่กระตุ้นบั๊ก — เมื่อ `Rig_Menu` เรนเดอร์แถว item ที่โหลดรูป icon สำเร็จ (`iconFailed === false`) ทำให้มี `<img>` อยู่ภายใน `.rig-row__icon` แต่ `<img>` นั้นไม่มีกฎ CSS จำกัดขนาด จึงเรนเดอร์ล้นกล่อง `3.2vh × 3.2vh`
- **Property (P)**: พฤติกรรมที่ถูกต้อง — `<img>` ถูกย่อให้พอดี (fit) ภายในกล่อง `.rig-row__icon` ขนาดคงที่ ไม่ล้น ไม่ทับข้อความหรือแถวอื่น
- **Preservation**: พฤติกรรมเดิมที่ต้องคงไว้ — กล่อง icon ขนาดคงที่เมื่อโหลดรูปไม่สำเร็จ, พื้นหลังโปร่งใส/text-shadow ของเมนู, การจางแถวเมื่อ `owned === 0`, HUD components อื่นใน bundle เดียวกัน และ DOM/Lua/fxmanifest ที่ไม่ถูกแตะ
- **`.rig-row__icon`**: กล่อง `<div>` container ขนาดคงที่ใน `web/src/style.css` ที่ห่อ `<img>` ของ icon แต่ละแถว
- **`RigRowItem`**: component ใน `web/src/components/RigMenu.tsx` ที่เรนเดอร์แต่ละแถว โดยใส่ `<img src="nui://zfishing/assets/items/{name}.png">` ไว้ภายใน `.rig-row__icon` เมื่อ `iconFailed === false`
- **`web/dist/`**: bundle ที่ build แล้วซึ่ง FiveM โหลดจริงตอน runtime (ไม่ใช่ `web/src/`)

## Bug Details

### Bug Condition

บั๊กปรากฏเมื่อ `Rig_Menu` เปิดอยู่และมีแถว item อย่างน้อยหนึ่งแถวที่โหลดรูป icon PNG ได้สำเร็จ ทำให้ browser engine ของ NUI เรนเดอร์ `<img>` ภายใน `.rig-row__icon` ที่ **ขนาดพิกเซลจริงของไฟล์** เพราะไม่มีกฎ CSS จำกัดขนาดของ `<img>` และ container ไม่มี `overflow: hidden`

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input of type RigIconRenderState
         { menuOpen: boolean,
           iconFailed: boolean,       // สถานะ onError ของ <img>
           imgNaturalPx: number,      // ขนาดพิกเซลจริงของ PNG
           boxPx: number,             // ขนาดกล่อง .rig-row__icon (3.2vh -> px)
           hasImgSizingRule: boolean, // มีกฎ .rig-row__icon img จำกัดขนาดหรือไม่
           containerClipsOverflow: boolean } // container มี overflow:hidden หรือไม่
  OUTPUT: boolean

  RETURN input.menuOpen == true
         AND input.iconFailed == false            // รูปโหลดสำเร็จ -> มี <img> จริง
         AND input.hasImgSizingRule == false       // ไม่มีกฎจำกัดขนาด <img>
         AND (input.imgNaturalPx > input.boxPx)    // PNG ใหญ่กว่ากล่อง -> ล้น
         AND input.containerClipsOverflow == false  // ไม่มี overflow:hidden -> ทับส่วนอื่น
END FUNCTION
```

### Examples

- **แถวเดียว icon ใหญ่**: PNG ขนาด 128×128 px แสดงในกล่อง `3.2vh` (~35px ที่จอ 1080p) → คาดหวัง: ย่อพอดี ~35×35px; จริง: เรนเดอร์ 128×128px ล้นทับ label/owned ของแถวเดียวกัน
- **หลายแถวเรียงกัน**: มี 4 แถว icon แต่ละอันล้นลงไปทับแถวถัดไป → คาดหวัง: icon เล็กสม่ำเสมอเรียงหน้าข้อความ; จริง: วงกลมใหญ่ซ้อนทับกัน อ่านรายการไม่ออก
- **รูปโหลดไม่สำเร็จ (edge case, ¬C)**: `onError` ทำงาน `iconFailed === true` → ไม่มี `<img>` ในกล่อง → ไม่มีการล้น (บั๊กไม่ถูกกระตุ้น) กล่องยังคงขนาดคงที่ตามพฤติกรรมเดิม
- **PNG เล็กกว่าหรือเท่ากล่อง (edge case)**: `imgNaturalPx <= boxPx` → ไม่ล้น (บั๊กไม่ถูกกระตุ้นในทางปฏิบัติ) แต่หลังแก้จะยังคงถูกจัด fit ให้พอดีสม่ำเสมอ

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors (ต้องคงเดิมหลังแก้):**
- เมื่อ icon โหลดไม่สำเร็จ (`onError`/`iconFailed === true`) → ซ่อนรูปแต่คงกล่อง `.rig-row__icon` ขนาดคงที่ไว้ ไม่ให้แถวเลื่อนตำแหน่ง (R2.7 เดิม / bugfix R3.1)
- พื้นหลังโปร่งใสและ text-shadow ของ `.rig-menu` / `.rig-row__label` / `.rig-row__owned` ที่แก้ไว้ใน spec ก่อนหน้า (R3.2)
- แถวที่ `owned === 0` ยังคงจางลง (`opacity` ≤ 0.5) ตามพฤติกรรมเดิม (R3.3)
- HUD components อื่นใน bundle เดียวกัน (CastBar, PromptHud, Admin panel, catch card) ยังแสดงผลและทำงานเหมือนเดิม (R3.4)

**Scope:**
input ใด ๆ ที่ **ไม่เข้า** Bug Condition ต้องไม่ได้รับผลกระทบจากการแก้นี้ ได้แก่:
- แถวที่ icon โหลดไม่สำเร็จ (ไม่มี `<img>` ในกล่อง)
- Styling ของ element อื่นทั้งหมดที่ไม่ใช่ `<img>` ภายใน `.rig-row__icon`
- DOM structure ของ `RigMenu.tsx`, โค้ด Lua ฝั่ง server/client, `fxmanifest.lua`, และ prompt `[G] จัดการเบ็ด` จาก locales (R3.5)

**หมายเหตุ:** พฤติกรรมที่ถูกต้องที่คาดหวัง (icon ย่อพอดีกล่อง) นิยามไว้ใน section "Correctness Properties" (Property 1) — section นี้เน้นสิ่งที่ต้อง **ไม่เปลี่ยน**

## Hypothesized Root Cause

จากการวิเคราะห์บั๊กและยืนยันจาก source (`web/src/style.css` + `web/src/components/RigMenu.tsx`) สาเหตุที่เป็นไปได้เรียงตามความน่าจะเป็น:

1. **ไม่มีกฎ CSS จำกัดขนาด `<img>` (สาเหตุหลัก — ยืนยันแล้ว)**: ไม่มี selector `.rig-row__icon img { ... }` อยู่ที่ใดใน `style.css` ทำให้ `<img>` เรนเดอร์ตามขนาด intrinsic ของ PNG
   - `.rig-row__icon` กำหนดขนาดกล่อง `3.2vh × 3.2vh` ไว้ที่ตัว `<div>` container เท่านั้น
   - ตัว `<img>` ที่เป็น child ไม่ได้ inherit ขนาดนั้น

2. **`object-fit: contain` ถูกวางผิดที่ (ยืนยันแล้ว)**: กฎ `object-fit: contain` อยู่บน `.rig-row__icon` ซึ่งเป็น `<div>` — `object-fit` มีผลเฉพาะกับ replaced element (`<img>`, `<video>`) ไม่มีผลกับ `<div>` จึงไม่ทำงานตามที่ตั้งใจ

3. **Container ไม่มี `overflow: hidden` (ยืนยันแล้ว)**: `.rig-row__icon` ไม่มี `overflow: hidden` ทำให้แม้ `<img>` จะใหญ่เกิน ก็ยังล้นทะลุออกไปทับ element อื่นแทนที่จะถูกตัด (clip)

4. **Bundle ค้าง (สาเหตุด้าน deploy)**: แม้แก้ source แล้ว ถ้าไม่ rebuild + deploy `web/dist/` + restart resource ผู้เล่นจะยังเห็น bundle เดิม (บทเรียนจาก spec `fishing-nui-bundle-rebuild-fix`)

## Correctness Properties

Property 1: Bug Condition - Icon ย่อพอดีกล่องขนาดคงที่

_For any_ input ที่เข้า Bug Condition (`isBugCondition` คืน `true` — เมนูเปิด, icon โหลดสำเร็จ, PNG ใหญ่กว่ากล่อง) หลังแก้ CSS แล้ว ระบบ SHALL เรนเดอร์ `<img>` ให้ย่อพอดี (fit) ภายในกล่อง `.rig-row__icon` ขนาดคงที่ `3.2vh × 3.2vh` โดยขนาดที่เรนเดอร์จริง (rendered width/height) SHALL ไม่เกินขนาดกล่อง และ SHALL ไม่ล้นไปทับ `.rig-row__label`, `.rig-row__owned` หรือแถวข้างเคียง

**Validates: Requirements 2.1, 2.2, 2.3**

Property 2: Preservation - พฤติกรรมของ input ที่ไม่เข้า Bug Condition คงเดิม

_For any_ input ที่ **ไม่เข้า** Bug Condition (`isBugCondition` คืน `false` — เช่น icon โหลดไม่สำเร็จ, element อื่นที่ไม่ใช่ `<img>` ใน `.rig-row__icon`, การจางแถว `owned === 0`, พื้นหลัง/text-shadow ของเมนู, HUD อื่นใน bundle) ระบบ SHALL ให้ผลลัพธ์เหมือนเดิมทุกประการกับก่อนแก้ โดยคงกล่อง icon ขนาดคงที่, พื้นหลังโปร่งใส/text-shadow, การจางแถว และการทำงานของ HUD อื่นไว้ไม่เปลี่ยนแปลง

**Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5**

## Fix Implementation

### Changes Required

สมมติว่าการวิเคราะห์ root cause ถูกต้อง การแก้เป็น **CSS-only ที่ source** แล้วตามด้วยกระบวนการ deploy

**File**: `e:\Web\ZCore\zfishing\web\src\style.css`

**Selector ที่เกี่ยวข้อง**: `.rig-row__icon` และเพิ่ม `.rig-row__icon img` ใหม่

**Specific Changes**:
1. **เพิ่มกฎขนาดให้ `<img>` ภายใน `.rig-row__icon`**: เพิ่ม selector ใหม่
   ```css
   .rig-row__icon img {
     width: 100%;
     height: 100%;
     object-fit: contain;
     display: block;
   }
   ```
   - `width/height: 100%` → บังคับให้ `<img>` เท่าขนาดกล่อง `3.2vh`
   - `object-fit: contain` → ย่อรักษาสัดส่วนภาพให้พอดีกล่อง (คราวนี้อยู่บน `<img>` จึงมีผลจริง)
   - `display: block` → กัน whitespace ใต้ inline image

2. **เพิ่ม `overflow: hidden` ให้ container `.rig-row__icon`**: เป็น defense-in-depth กันการล้นในทุกกรณีแม้สัดส่วนภาพผิดปกติ
   ```css
   .rig-row__icon {
     /* ...คงคุณสมบัติเดิม (flex, width, height, background)... */
     overflow: hidden;
   }
   ```

3. **(ทางเลือก) ลบ `object-fit: contain` ที่อยู่บน `.rig-row__icon` (div)**: เนื่องจากไม่มีผลกับ `<div>` — ลบเพื่อความสะอาดของโค้ด แต่ **ไม่บังคับ** และต้องไม่กระทบ property อื่นของ selector นี้ (แนวทาง surgical change)

### Deploy Process (จำเป็น — bundle ค้าง)

4. **Rebuild bundle**: รัน `npm run build` ใน `web/` เพื่อสร้าง `web/dist/` ใหม่ (ผู้ใช้รันเองใน terminal)
5. **Deploy `web/dist/`**: ลบ `dist` เก่าในสำเนา resource ที่เซิร์ฟเวอร์รันจริง (`[zlab]\zfishing\web\dist`) ก่อนเพื่อเลี่ยงไฟล์ hash ค้าง แล้วคัดลอก `web/dist/` ใหม่ไปแทน
6. **Restart resource**: `restart zfishing` บนเซิร์ฟเวอร์เพื่อให้ผู้เล่นเห็นผลจริง

## Testing Strategy

### Validation Approach

ใช้แนวทางสองเฟส: เฟสแรก surface counterexample ที่แสดงบั๊กบนโค้ด **ก่อนแก้** เพื่อยืนยัน root cause จากนั้นเฟสสองยืนยันว่าการแก้ทำงานถูกต้อง (fix checking) และไม่ทำ regression (preservation checking) เนื่องจากบั๊กเป็นเรื่อง CSS layout การทดสอบเน้นการวัดขนาดที่เรนเดอร์จริง (computed/rendered size) ของ `<img>` เทียบกับกล่อง

### Exploratory Bug Condition Checking

**Goal**: Surface counterexample ที่แสดงบั๊กบนโค้ด **ก่อนแก้** เพื่อยืนยันหรือหักล้าง root cause ถ้าหักล้างต้อง re-hypothesize

**Test Plan**: เรนเดอร์ `RigMenu` (หรือ `RigRowItem`) ในสภาพแวดล้อมทดสอบ DOM (jsdom/happy-dom หรือ integration ใน CEF/browser) โหลด `style.css` ปัจจุบัน จำลอง `<img>` ที่มี `naturalWidth/naturalHeight` ใหญ่กว่ากล่อง แล้ววัดขนาดที่เรนเดอร์จริงของ `<img>` เทียบกับ `.rig-row__icon` รันบนโค้ด **ที่ยังไม่แก้** เพื่อดูว่าล้น

**Test Cases**:
1. **Single Icon Overflow Test**: แถวเดียว icon PNG ใหญ่ → assert `img.rendered <= box` (จะ fail บนโค้ดที่ยังไม่แก้)
2. **No Img Sizing Rule Test**: ตรวจว่าไม่มีกฎ `.rig-row__icon img` ที่จำกัดขนาด → ยืนยัน root cause (จะสะท้อนสภาพก่อนแก้)
3. **Overflow Not Clipped Test**: ตรวจว่า `.rig-row__icon` ไม่มี `overflow: hidden` และรูปล้นทับพื้นที่ label (จะ fail บนโค้ดที่ยังไม่แก้)
4. **Multi-Row Overlap Test (edge)**: หลายแถว → icon แถวบนล้นไปทับพื้นที่แถวล่าง (อาจ fail บนโค้ดที่ยังไม่แก้)

**Expected Counterexamples**:
- ขนาดที่เรนเดอร์ของ `<img>` เท่ากับ `naturalWidth/naturalHeight` ของ PNG (ไม่ถูกย่อ) และเกินขนาดกล่อง
- สาเหตุที่เป็นไปได้: ไม่มีกฎ `.rig-row__icon img`, `object-fit` วางผิดที่บน `<div>`, ไม่มี `overflow: hidden`

### Fix Checking

**Goal**: ยืนยันว่าสำหรับทุก input ที่เข้า Bug Condition โค้ดที่แก้แล้วให้พฤติกรรมที่คาดหวัง (icon ย่อพอดีกล่อง ไม่ล้น)

**Pseudocode:**
```
FOR ALL input WHERE isBugCondition(input) DO
  render := renderRigRowWithFixedCss(input)
  ASSERT render.img.renderedWidth  <= render.box.width
  ASSERT render.img.renderedHeight <= render.box.height
  ASSERT NOT overlaps(render.img, render.label)
  ASSERT NOT overlaps(render.img, render.ownedText)
END FOR
```

### Preservation Checking

**Goal**: ยืนยันว่าสำหรับทุก input ที่ **ไม่เข้า** Bug Condition โค้ดที่แก้แล้วให้ผลลัพธ์เหมือนกับโค้ดเดิม

**Pseudocode:**
```
FOR ALL input WHERE NOT isBugCondition(input) DO
  ASSERT renderOriginal(input) == renderFixed(input)
END FOR
```

**Testing Approach**: แนะนำ property-based testing สำหรับ preservation checking เพราะ:
- สร้าง test case จำนวนมากอัตโนมัติครอบคลุม input domain (สถานะ `iconFailed`, `owned`, จำนวนแถว, styling อื่น)
- จับ edge case ที่ unit test เขียนมืออาจพลาด
- ให้การรับประกันที่แข็งแรงว่าพฤติกรรมของ input ที่ไม่ใช่บั๊กไม่เปลี่ยน

**Test Plan**: สังเกตพฤติกรรมบนโค้ด **ก่อนแก้** สำหรับ input ที่ไม่ใช่บั๊ก (icon โหลดไม่สำเร็จ, การจางแถว, พื้นหลัง/text-shadow, HUD อื่น) แล้วเขียน property-based test จับพฤติกรรมนั้นไว้เทียบก่อน/หลังแก้

**Test Cases**:
1. **Icon Failed Preservation**: `iconFailed === true` → กล่อง `.rig-row__icon` ยังคงขนาดคงที่ ไม่มี `<img>` แถวไม่เลื่อน — เหมือนเดิม
2. **Dimmed Row Preservation**: `owned === 0` → แถว `opacity` ≤ 0.5 — เหมือนเดิม
3. **Menu Style Preservation**: พื้นหลังโปร่งใส + text-shadow ของ `.rig-menu`/label/owned — เหมือนเดิม
4. **Other HUD Preservation**: CastBar, PromptHud, catch card, Admin panel ใน bundle เดียวกัน — render และทำงานเหมือนเดิม

### Unit Tests

- ทดสอบว่ากฎ `.rig-row__icon img` ทำให้ `<img>` ที่ intrinsic ใหญ่ถูกย่อ `<= 3.2vh`
- ทดสอบ edge case: `iconFailed === true` (ไม่มี `<img>`), PNG เล็กกว่ากล่อง
- ทดสอบว่ากล่อง `.rig-row__icon` มี `overflow: hidden` หลังแก้

### Property-Based Tests

- สุ่ม `naturalWidth/naturalHeight` ของ PNG หลากหลายค่า → verify ขนาดที่เรนเดอร์ของ `<img>` ไม่เกินกล่องเสมอ (Property 1)
- สุ่มสถานะแถว (`owned`, `iconFailed`, จำนวนแถว) ที่ไม่เข้า Bug Condition → verify ผลลัพธ์เหมือนโค้ดเดิม (Property 2)
- สุ่มชุด item หลายแถว → verify ไม่มีการทับซ้อน (overlap) ระหว่าง icon กับ label/owned/แถวข้างเคียง

### Integration Tests

- เปิด `Rig_Menu` เต็ม flow ในสภาพแวดล้อม NUI จริง (หลัง rebuild + deploy) → icon เล็กสม่ำเสมอเรียงหน้าข้อความ
- สลับสถานะ (มีของ/ไม่มีของ/รูปโหลดไม่ได้) → layout คงเสถียร แถวไม่เลื่อน
- ยืนยันว่า HUD components อื่นใน bundle เดียวกันยังแสดงผลถูกต้องหลัง rebuild
