# Bugfix Requirements Document

## Introduction

หลังจาก spec ก่อนหน้า `fishing-rig-menu-hud-style-fix` ได้แก้ไข CSS ของเมนูประกอบเบ็ด (Rig_Menu) ให้แสดงพื้นหลังโปร่งใสพร้อม text-shadow และผ่านการทดสอบระดับ source ครบแล้ว แต่ในเกมจริง ผู้เล่นที่กด G เปิด Rig_Menu ยังเห็นเมนูเป็น**กล่องพื้นหลังทึบสีดำ** (มีขอบ เงา และ blur) ไม่มี text-shadow เหมือนเดิม

สาเหตุคือ FiveM โหลด NUI จาก **bundle ที่ build แล้ว** (`web/dist/`) ตามที่ประกาศใน `fxmanifest.lua` (`ui_page 'web/dist/index.html'`) ไม่ใช่จาก `web/src/` โดยตรง การแก้ไขครั้งก่อนแก้เฉพาะ source และรันแค่ `vitest` (ทดสอบกับ source) จึง**ไม่เคยรัน `npm run build`** ทำให้ `web/dist/` ยังเป็น artifact เวอร์ชันเก่าก่อนการแก้ CSS นอกจากนี้ resource ที่เซิร์ฟเวอร์รันจริงยังเป็น**สำเนา**ที่ deploy path แยกต่างหาก ซึ่งก็ถือ bundle เก่าชุดเดียวกัน (bundle hash `index-DLW4jjFM.css` / `index-zLgQY8bw.js`)

บั๊กนี้เป็นปัญหาเรื่อง **artifact ที่ค้างเก่า (stale build artifact) + การ deploy** ไม่ใช่ความผิดพลาดของ source code งานคือ regenerate NUI bundle จาก source ปัจจุบันและ deploy ไปยัง resource ที่รันจริง โดยไม่แตะ source

## Bug Analysis

### Current Behavior (Defect)

พฤติกรรมที่เกิดขึ้นจริงในเกมเมื่อบั๊กถูกกระตุ้น (bundle ที่โหลดจริงยังเป็นเวอร์ชันเก่า)

1.1 WHEN ผู้เล่นกด G เปิด Rig_Menu ในเกม THEN ระบบแสดงเมนูเป็นกล่องพื้นหลังทึบ (`background: var(--bg)`) พร้อมขอบ เงา (`box-shadow`) และ `backdrop-filter: blur(4px)` แทนที่จะโปร่งใส
1.2 WHEN Rig_Menu แสดงหัวข้อและข้อความในเกม THEN ตัวอักษรไม่มี `text-shadow` (ใช้สี `var(--text)`/`var(--muted)`) ตามเวอร์ชัน CSS เก่า
1.3 WHEN ตรวจไฟล์ `web/dist/assets/*.css` ที่เกมโหลดจริง THEN rule `.rig-menu` ยังคงมี `background: var(--bg)`, `box-shadow`, `backdrop-filter: blur(4px)` และ `.rig-menu__title`/`.rig-menu__label` ไม่มี `text-shadow` — ไม่ตรงกับ `web/src/style.css` ที่แก้ไว้แล้ว
1.4 WHEN ตรวจ bundle ในสำเนา resource ที่เซิร์ฟเวอร์รันจริง (deploy path) THEN bundle มี hash เดิม (`index-DLW4jjFM.css` / `index-zLgQY8bw.js`) ตรงกับ artifact เก่าใน source repo — ยังไม่ได้รับ bundle ใหม่

### Expected Behavior (Correct)

พฤติกรรมที่ถูกต้องหลัง rebuild bundle จาก source ปัจจุบันและ deploy ไปยัง resource ที่รันจริง

2.1 WHEN rebuild `web/dist` จาก source ปัจจุบัน (`npm run build` ใน `web/`) THEN ระบบ SHALL regenerate `web/dist/assets/*.css` ให้ rule `.rig-menu` มี `background: transparent` และไม่มี `box-shadow`/`backdrop-filter`/`var(--bg)` ใน rule นั้น
2.2 WHEN rebuild `web/dist` เสร็จ THEN ระบบ SHALL regenerate CSS ให้ `.rig-menu__title`, `.rig-menu__hint`, `.rig-menu__empty`, `.rig-row__label`, `.rig-row__owned` มี `text-shadow` และตัวอักษรสีขาว (`#fff`) ตรงกับ `web/src/style.css`
2.3 WHEN deploy `web/dist` ที่ regenerate แล้ว ไปยัง resource สำเนาที่เซิร์ฟเวอร์รันจริง THEN ระบบ SHALL ทำให้สำเนามี bundle ชุดใหม่ที่มีเนื้อหา (และ hash) ตรงกับ `web/dist` ของ source repo
2.4 WHEN ผู้เล่นกด G เปิด Rig_Menu ในเกมหลัง rebuild + deploy THEN ระบบ SHALL แสดงเมนูพื้นหลังโปร่งใสพร้อม text-shadow ตามที่แก้ไว้ใน source (ไม่เป็นกล่องดำทึบอีก)

### Unchanged Behavior (Regression Prevention)

พฤติกรรมที่ต้องคงเดิมหลังการ rebuild + deploy

3.1 WHEN ทำงานในบั๊กนี้ THEN ระบบ SHALL CONTINUE TO ใช้ `web/src/*` เดิมทั้งหมดโดยไม่แก้ไข (source ถูกต้องแล้วจาก spec ก่อนหน้า) — งานคือ regenerate artifact + deploy เท่านั้น
3.2 WHEN โหลด NUI bundle ที่ rebuild ใหม่ THEN HUD components อื่นที่อยู่ใน bundle เดียวกัน (CastBar, PromptHud, Admin panel, catch card ฯลฯ) SHALL CONTINUE TO แสดงผลและทำงานเหมือนเดิม
3.3 WHEN ผู้เล่นอยู่ในเกม THEN prompt กลางล่าง `[G] จัดการเบ็ด` ที่โหลดจาก `locales/*.json` โดยตรง SHALL CONTINUE TO แสดงถูกต้องเหมือนเดิม
3.4 WHEN ทำงานในบั๊กนี้ THEN โค้ดฝั่ง server, client Lua และ DOM structure ของ NUI components SHALL CONTINUE TO ไม่ถูกแตะต้อง
