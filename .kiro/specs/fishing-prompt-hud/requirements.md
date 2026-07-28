# Requirements Document

## Introduction

ปัจจุบันเมื่อผู้เล่นถือเบ็ดตกปลาและอยู่ที่จุดตกปลา ระบบจะแสดง prompt ผ่าน ox_lib TextUI ที่มุมขวาของจอ (`lib.showTextUI(locale('equip_hint'))` และ `lib.showTextUI(locale('cancel_hint'))` ใน `client/main.lua`) ฟีเจอร์นี้เปลี่ยน prompt สองจุดนั้น (ช่วง equip standby และช่วงหลังขว้างเบ็ด) ให้แสดงเป็น NUI HUD กลางจอด้านล่าง (bottom-center) ในรูปแบบ title (บรรทัดใหญ่) + subtitle (บรรทัดเล็ก) โดยใช้เทคโนโลยี NUI เดิมของ resource (React 18 + TypeScript + Vite, สื่อสารผ่าน `SendNUIMessage`/`useNuiEvent`)

ขอบเขตของฟีเจอร์ถูกจำกัดไว้เฉพาะฝั่งการนำเสนอ (client Lua + NUI) เท่านั้น:
- **อยู่ในขอบเขต:** ย้ายและเปลี่ยนสไตล์ prompt ช่วง equip standby และ cancel ให้เป็น HUD กลางจอล่าง, เพิ่ม config toggle เปิด/ปิด HUD, เพิ่ม locale key สำหรับ title
- **ไม่อยู่ในขอบเขต:** เมนู "Select a Bait" (เป็นเพียง mockup — ระบบเลือกเหยื่อยังใช้ `resolveBait()` อัตโนมัติเหมือนเดิม), prompt ของ NPC ขายปลา (คง ox_lib TextUI ไว้เหมือนเดิม), server logic และ anti-cheat validation (ไม่แตะต้อง)

## Glossary

- **Prompt_HUD**: NUI component ใหม่ที่แสดง prompt แบบ title + subtitle กลางจอด้านล่าง (bottom-center) แทนที่ ox_lib TextUI สำหรับ prompt ช่วงตกปลา
- **Fishing_Client**: สคริปต์ฝั่ง client ใน `client/main.lua` ที่ควบคุม lifecycle ของการตกปลาและส่งข้อความไป NUI
- **Equip_Standby_Phase**: ช่วงที่ผู้เล่นถือเบ็ดพร้อมแล้วแต่ยังไม่ขว้าง รอกด E เพื่อเริ่ม หรือ X เพื่อเก็บเบ็ด (เดิมใช้ `equip_hint`)
- **Cancel_Phase**: ช่วงหลังขว้างเบ็ดสำเร็จ (waiting/reeling) ที่ผู้เล่นกด X เพื่อเก็บเบ็ดได้ (เดิมใช้ `cancel_hint`)
- **Title_Text**: ข้อความบรรทัดหลักตัวใหญ่ของ Prompt_HUD (locale key ใหม่ `equip_title` / `cancel_title`)
- **Subtitle_Text**: ข้อความบรรทัดรองตัวเล็กของ Prompt_HUD (locale key เดิม `equip_hint` / `cancel_hint`)
- **Prompt_Hud_Enabled**: ค่า config (`Config.PromptHud`) ที่กำหนดว่าจะใช้ Prompt_HUD (`true`) หรือใช้ ox_lib TextUI แบบเดิม (`false`)
- **Locale_Dictionary**: ตาราง key/value ที่โหลดจาก `locales/{lang}.json` (en เป็นฐาน + ภาษา active overlay) และส่งให้ NUI ผ่าน NUI callback `getLocale`
- **Sell_Prompt**: prompt ที่ NPC ขายปลาแสดง (`locale('sell')`) — อยู่นอกขอบเขตของฟีเจอร์นี้และต้องคงพฤติกรรมเดิม

## Requirements

### Requirement 1: แสดง Prompt HUD กลางจอด้านล่าง

**User Story:** As a player, I want prompt ตอนตกปลาแสดงกลางจอด้านล่างแบบ title/subtitle, so that ฉันมองเห็นคำสั่งได้ชัดเจนขึ้นและกลมกลืนกับ HUD ตกปลาที่มีอยู่

#### Acceptance Criteria

1. WHERE Prompt_Hud_Enabled เป็น true, WHEN Fishing_Client สั่งแสดง prompt ช่วงตกปลา, THE Prompt_HUD SHALL แสดงองค์ประกอบโดยจัดกึ่งกลางแนวนอน (horizontal center) และวางชิดด้านล่างของหน้าจอโดยมีระยะห่างจากขอบล่าง 5% ถึง 10% ของความสูงหน้าจอ
2. THE Prompt_HUD SHALL แสดง Title_Text เป็นบรรทัดหลักโดยมีขนาดตัวอักษรมากกว่า Subtitle_Text อย่างน้อย 1.5 เท่า
3. THE Prompt_HUD SHALL แสดง Subtitle_Text เป็นบรรทัดรองที่วางอยู่ใต้ Title_Text ในแนวตั้ง
4. WHEN Fishing_Client สั่งซ่อน prompt, THE Prompt_HUD SHALL หยุดแสดงองค์ประกอบทั้งหมดของ prompt ภายใน 200 มิลลิวินาที
5. THE Prompt_HUD SHALL ไม่รับ pointer event (mouse focus) ทุกกรณี เพื่อไม่ให้รบกวนการควบคุมเกม
6. WHERE Prompt_Hud_Enabled เป็น false, WHEN Fishing_Client สั่งแสดง prompt ช่วงตกปลา, THE Prompt_HUD SHALL ไม่แสดงองค์ประกอบใด ๆ ของ prompt
7. IF Title_Text หรือ Subtitle_Text ที่ได้รับเป็นค่าว่าง (empty) หรือ null, THEN THE Prompt_HUD SHALL ไม่แสดงบรรทัดที่มีค่าว่างนั้น และคงแสดงเฉพาะบรรทัดที่มีข้อความ
8. WHEN Fishing_Client ส่งข้อความ prompt ที่มีความยาวเกิน 120 ตัวอักษรต่อบรรทัด, THE Prompt_HUD SHALL ตัดข้อความให้แสดงไม่เกิน 120 ตัวอักษรต่อบรรทัด

### Requirement 2: แสดง Prompt ในช่วง Equip Standby และ Cancel

**User Story:** As a player, I want prompt แสดงครบทุกช่วงที่เดิมใช้ TextUI ตอนตกปลา, so that ฉันรู้ว่ากดปุ่มใดได้บ้างในแต่ละช่วง

#### Acceptance Criteria

1. WHEN Fishing_Client เข้าสู่ Equip_Standby_Phase, THE Prompt_HUD SHALL แสดง Title_Text จาก locale key `equip_title` และ Subtitle_Text จาก locale key `equip_hint` ภายใน 100 มิลลิวินาที
2. WHEN ผู้เล่นออกจาก Equip_Standby_Phase โดยกด E เพื่อเริ่มขว้างเบ็ด, THE Prompt_HUD SHALL ซ่อน prompt ของ Equip_Standby_Phase ภายใน 100 มิลลิวินาที
3. WHEN Fishing_Client เข้าสู่ Cancel_Phase หลังขว้างเบ็ดสำเร็จ, THE Prompt_HUD SHALL แสดง Title_Text จาก locale key `cancel_title` และ Subtitle_Text จาก locale key `cancel_hint` ภายใน 100 มิลลิวินาที
4. WHEN Fishing_Client ทำ cleanup (สิ้นสุดหรือยกเลิกการตกปลา), THE Prompt_HUD SHALL ซ่อน prompt ทุกช่วงภายใน 100 มิลลิวินาที
5. WHILE Prompt_HUD ของ Cancel_Phase แสดงอยู่, THE Prompt_HUD SHALL แสดงพร้อมกับ HUD ข้อมูลการตกปลา (FishingInfoCard / WaitingHud) โดยพื้นที่ทับซ้อน (overlap) ระหว่าง bounding box ของทั้งสองเท่ากับ 0 พิกเซล
6. WHEN ผู้เล่นออกจาก Equip_Standby_Phase โดยกด X เพื่อยกเลิก/เก็บเบ็ด, THE Prompt_HUD SHALL ซ่อน prompt ของ Equip_Standby_Phase ภายใน 100 มิลลิวินาที
7. IF locale key ของ Title_Text หรือ Subtitle_Text ไม่พบหรือเป็นค่าว่าง, THEN THE Prompt_HUD SHALL แสดงข้อความ fallback แทน โดยไม่หยุดการแสดง prompt

### Requirement 3: Config Toggle เปิด/ปิด Prompt HUD

**User Story:** As a server owner, I want config สำหรับเปิดหรือปิด Prompt HUD, so that ฉันเลือกได้ว่าจะใช้ HUD กลางจอใหม่หรือ TextUI แบบเดิม

#### Acceptance Criteria

1. WHEN Fishing_Client เริ่มทำงาน (resource start), THE Fishing_Client SHALL อ่านค่า Prompt_Hud_Enabled จาก `Config.PromptHud` และเก็บเป็นค่า boolean ไว้ใช้ตลอด session
2. WHERE Prompt_Hud_Enabled เป็น true, WHEN เข้าสู่ช่วง Equip_Standby_Phase หรือ Cancel_Phase, THE Fishing_Client SHALL แสดง prompt ผ่าน Prompt_HUD แทนการเรียก `lib.showTextUI` ภายใน 100 มิลลิวินาที นับจากเวลาที่เข้าสู่ช่วงนั้น
3. WHERE Prompt_Hud_Enabled เป็น false, WHEN เข้าสู่ช่วง Equip_Standby_Phase, THE Fishing_Client SHALL แสดง prompt ผ่าน `lib.showTextUI(locale('equip_hint'))` ตามพฤติกรรมเดิม
4. WHERE Prompt_Hud_Enabled เป็น false, WHEN เข้าสู่ช่วง Cancel_Phase, THE Fishing_Client SHALL แสดง prompt ผ่าน `lib.showTextUI(locale('cancel_hint'))` ตามพฤติกรรมเดิม
5. WHEN ออกจากช่วง Equip_Standby_Phase หรือ Cancel_Phase, THE Fishing_Client SHALL ซ่อน prompt ที่แสดงอยู่ (ทั้ง Prompt_HUD และ `lib.showTextUI`) ภายใน 100 มิลลิวินาที
6. IF `Config.PromptHud` ไม่ได้ถูกกำหนดค่า (nil) หรือมีค่าที่ไม่ใช่ boolean, THEN THE Fishing_Client SHALL ใช้ค่า Prompt_Hud_Enabled เป็น true เป็นค่าเริ่มต้น

### Requirement 4: Localization ของ Prompt HUD

**User Story:** As a player, I want prompt แสดงเป็นภาษาที่ตั้งค่าไว้ (รวมภาษาไทย), so that ฉันอ่านคำสั่งได้ในภาษาของฉัน

#### Acceptance Criteria

1. WHEN Prompt_HUD ถูกเรนเดอร์ครั้งแรก (initialize), THE Prompt_HUD SHALL ดึงข้อความทั้งหมดจาก Locale_Dictionary ที่โหลดผ่าน NUI callback `getLocale` ก่อนแสดงข้อความใด ๆ บนหน้าจอ
2. THE Locale_Dictionary SHALL มี locale key `equip_title` และ `cancel_title` ในไฟล์ `locales/en.json` และ `locales/th.json`
3. IF locale key ที่ร้องขอไม่มีในภาษา active ของ Locale_Dictionary, THEN THE Prompt_HUD SHALL ใช้ค่าของ locale key เดียวกันจากภาษา en (ภาษาฐาน) แทน
4. IF locale key ที่ร้องขอไม่มีทั้งในภาษา active และภาษา en, THEN THE Prompt_HUD SHALL แสดงข้อความ fallback ที่กำหนดไว้ล่วงหน้า แทนการแสดง key ดิบ
5. WHEN Prompt_HUD แสดงข้อความ, THE Prompt_HUD SHALL เลือกภาษา active ตามค่าที่กำหนดใน `Config.Locale` โดยใช้ภาษา en เป็นฐานและ overlay ด้วยภาษา active ตามกลไก Locale_Dictionary ที่มีอยู่
6. IF ค่า `Config.Locale` ไม่ตรงกับไฟล์ภาษาที่มีอยู่ (ไม่พบไฟล์ `locales/<Config.Locale>.json`), THEN THE Prompt_HUD SHALL ใช้ภาษา en เป็นภาษา active แทน

### Requirement 5: จำกัดผลกระทบเฉพาะฝั่งการนำเสนอ

**User Story:** As a server owner, I want การเปลี่ยนแปลงนี้ไม่กระทบ server logic และ prompt อื่น, so that ระบบตกปลาและ anti-cheat ยังทำงานเหมือนเดิม

#### Acceptance Criteria

1. THE Fishing_Client SHALL คงสถานะทั้ง 6 ของ lifecycle การตกปลา (equip standby, charge, cast callback, waiting, reeling, cleanup) ไว้ครบตามลำดับเดิม โดยไม่เพิ่ม ไม่ลบ และไม่สลับลำดับสถานะใด ๆ
2. WHEN ผู้เล่นเข้าหรือออกจากระยะโต้ตอบกับ NPC ขายปลา, THE Fishing_Client SHALL แสดงหรือซ่อน Sell_Prompt ผ่าน ox_lib TextUI (`lib.showTextUI(locale('sell'))`) ตามพฤติกรรมเดิม
3. THE Fishing_Client SHALL ไม่เปลี่ยนแปลงชื่อ จำนวน ลำดับ และโครงสร้าง argument/payload ของ server callback และ event ที่ส่งไปยัง server (`zfishing:cast`, `zfishing:cancel`, `zfishing:sellAll`, `zfishing:reportWeather`)
4. WHEN Fishing_Client เรียก `zfishing:cast`, THE Fishing_Client SHALL ไม่ส่ง argument ที่ระบุชนิดเหยื่อ (bait) โดยคงให้ server ใช้ `resolveBait()` เลือกเหยื่อเอง
5. WHILE ฟีเจอร์ Prompt_HUD ทำงาน, THE Fishing_Client SHALL คง trigger และความถี่ในการส่ง event `zfishing:reportWeather` ไว้ตามพฤติกรรมเดิม
6. IF การเรียก server callback หรือ event ล้มเหลว (ไม่มี response), THEN THE Fishing_Client SHALL คงสถานะข้อมูลผู้เล่นตามเดิมและแจ้งเตือนผู้เล่นผ่านช่องทาง notify ที่มีอยู่
