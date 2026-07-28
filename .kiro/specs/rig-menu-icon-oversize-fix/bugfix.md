# Bugfix Requirements Document

## Introduction

ในเมนู NUI ของ zfishing ที่ชื่อ Rig_Menu (จัดการเบ็ด) รูป icon ของ item แสดงผล **ใหญ่เกินไป** โดยเรนเดอร์ตามขนาดพิกเซลจริง (natural/intrinsic size) ของไฟล์ PNG ทำให้ล้นออกนอกกล่อง `.rig-row__icon` ที่มีขนาดคงที่ และไปทับกับข้อความชื่อ/จำนวนที่ถือ (label/owned) รวมถึงทับแถวข้างเคียง ผู้เล่นจึงเห็นเป็นวงกลมใหญ่ซ้อนทับกันแทนที่จะเป็น icon เล็ก ๆ วางเรียงหน้าข้อความของแต่ละแถวอย่างเป็นระเบียบ

**Root cause (ยืนยันจาก source แล้ว):** ใน `web/src/style.css` กฎ `.rig-row__icon` (ซึ่งเป็น `<div>` container) กำหนด `width: 3.2vh; height: 3.2vh; object-fit: contain;` แต่ `object-fit` มีผลเฉพาะกับ replaced element เช่น `<img>` ไม่มีผลกับ `<div>` และ **ไม่มีกฎ CSS สำหรับ `<img>` ที่อยู่ภายใน `.rig-row__icon`** (ไม่มี `.rig-row__icon img { ... }` อยู่ที่ใดใน style.css) ทำให้ `<img>` เรนเดอร์ที่ขนาด PNG จริง และเพราะ container ไม่มี `overflow: hidden` รูปจึงล้นออกไปทับข้อความ/แถว

การแก้เป็นการปรับ **CSS ที่ source (`web/src/style.css`) เท่านั้น** — เพิ่มกฎกำหนดขนาดให้ `<img>` ภายใน `.rig-row__icon` (เช่น `width:100%; height:100%; object-fit:contain; display:block`) และอาจเพิ่ม `overflow:hidden` ให้ container โดยไม่แตะ DOM/Lua/fxmanifest

**หมายเหตุสำคัญเรื่องการ deploy (บทเรียนจาก spec `fishing-nui-bundle-rebuild-fix`):** FiveM โหลด bundle ที่ build แล้วจาก `web/dist/` ไม่ใช่ source ดังนั้นการแก้ต้องครบทั้งกระบวนการ: (1) แก้ `web/src/style.css`, (2) `npm run build` ใน `web/` เพื่อ rebuild bundle, (3) deploy `web/dist/` ไปยังสำเนา resource ที่เซิร์ฟเวอร์รันจริง (ลบ dist เก่าก่อนเพื่อเลี่ยงไฟล์ hash ค้าง), (4) restart resource `zfishing` — ผู้เล่นจึงจะเห็นผล

## Bug Analysis

### Current Behavior (Defect)

พฤติกรรมที่เกิดขึ้นจริงในเกมเมื่อบั๊กถูกกระตุ้น (ยังใช้ CSS/bundle ที่ไม่มีกฎขนาดของ `<img>`)

1.1 WHEN Rig_Menu แสดงแถว item ที่โหลดรูป icon ได้สำเร็จ THEN ระบบเรนเดอร์ `<img>` ภายใน `.rig-row__icon` ที่ขนาดพิกเซลจริงของไฟล์ PNG แทนที่จะย่อให้พอดีกล่อง `3.2vh × 3.2vh`
1.2 WHEN icon เรนเดอร์ใหญ่เกินกล่อง THEN ระบบปล่อยให้รูปล้นออกนอก `.rig-row__icon` (ไม่มี `overflow: hidden`) ไปทับข้อความ `.rig-row__label` และ `.rig-row__owned` ของแถวเดียวกัน
1.3 WHEN มีหลายแถวเรียงกันในเมนู THEN icon ที่ล้นออกไปทับแถวข้างเคียง ทำให้เห็นเป็นวงกลมใหญ่ซ้อนทับกันแทนรายการที่เรียงเป็นระเบียบ
1.4 WHEN ตรวจ `web/src/style.css` THEN กฎ `.rig-row__icon` ใช้ `object-fit: contain` บน `<div>` (ไม่มีผลกับ container) และไม่มีกฎ `.rig-row__icon img { ... }` สำหรับกำหนดขนาดของ `<img>` เลย

### Expected Behavior (Correct)

พฤติกรรมที่ถูกต้องหลังแก้ CSS + rebuild + deploy

2.1 WHEN Rig_Menu แสดงแถว item ที่โหลดรูป icon ได้สำเร็จ THEN ระบบ SHALL ย่อ `<img>` ให้พอดีภายในกล่อง `.rig-row__icon` (`3.2vh × 3.2vh`) ด้วยกฎ `<img>` เช่น `width:100%; height:100%; object-fit:contain; display:block`
2.2 WHEN icon ถูกเรนเดอร์ THEN ระบบ SHALL ไม่ให้รูปล้นออกนอกกล่อง `.rig-row__icon` และ SHALL ไม่ทับข้อความ `.rig-row__label`/`.rig-row__owned` หรือแถวข้างเคียง
2.3 WHEN มีหลายแถวในเมนู THEN ระบบ SHALL แสดง icon เป็นภาพเล็กขนาดสม่ำเสมอ วางหน้า/ทางซ้ายของข้อความแต่ละแถว เรียงเป็นรายการแนวตั้งที่เป็นระเบียบ
2.4 WHEN แก้ `web/src/style.css` เสร็จ THEN ระบบ SHALL rebuild bundle ด้วย `npm run build` ใน `web/`, deploy `web/dist/` (ลบ dist เก่าก่อน) ไปยังสำเนา resource ที่เซิร์ฟเวอร์รันจริง แล้ว restart resource `zfishing` เพื่อให้ผู้เล่นเห็นผลจริง

### Unchanged Behavior (Regression Prevention)

พฤติกรรมที่ต้องคงเดิมหลังการแก้

3.1 WHEN icon ของ item โหลดไม่สำเร็จ (`onError` ทำงาน) THEN ระบบ SHALL CONTINUE TO ซ่อนรูปแต่คงกล่อง `.rig-row__icon` ขนาดคงที่ไว้ ไม่ให้แถวเลื่อนตำแหน่ง (พฤติกรรมเดิมตาม R2.7)
3.2 WHEN แสดง Rig_Menu THEN ระบบ SHALL CONTINUE TO ใช้พื้นหลังโปร่งใสและ text-shadow ของเมนู (ที่แก้ไว้ใน spec ก่อนหน้า) โดยไม่เปลี่ยนแปลง
3.3 WHEN แถว item มี `owned === 0` THEN ระบบ SHALL CONTINUE TO ทำให้แถวจางลง (opacity ≤ 0.5) ตามพฤติกรรมเดิม
3.4 WHEN โหลด NUI bundle ที่ rebuild ใหม่ THEN HUD components อื่นใน bundle เดียวกัน (CastBar, PromptHud, Admin panel, catch card) SHALL CONTINUE TO แสดงผลและทำงานเหมือนเดิม
3.5 WHEN ทำงานในบั๊กนี้ THEN DOM structure ของ RigMenu.tsx, โค้ด Lua ฝั่ง server/client, `fxmanifest.lua` และ prompt `[G] จัดการเบ็ด` จาก locales SHALL CONTINUE TO ไม่ถูกแตะต้อง
