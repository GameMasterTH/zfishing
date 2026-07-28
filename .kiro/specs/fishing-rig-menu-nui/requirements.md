# Requirements Document

## Introduction

ปัจจุบันการจัดการเบ็ด (Manage Rod / rig) ทำผ่าน ox_lib context menu: ผู้เล่นคลิกขวาที่เบ็ดใน ox_inventory ("Manage Rod") หรือพิมพ์ `/fishrig` แล้ว `client/rig.lua` เรียก `lib.registerContext`/`lib.showContext` เพื่อแสดงรายการ attach/detach ชิ้นส่วน reel/line/hook/float โดยดึงข้อมูลจาก server callback `zfishing:rig:get` และเปลี่ยนแปลงผ่าน `zfishing:rig:attach`/`zfishing:rig:detach`

ฟีเจอร์นี้เปลี่ยนหน้าตาของเมนูจัดการเบ็ดจาก ox_lib context menu ให้เป็น NUI menu ใหม่ (React 18 + TypeScript + Vite, สื่อสารผ่าน `SendNUIMessage`/`useNuiEvent`/`fetchNui`) ตามภาพแนบ: มีหัวข้อ + บรรทัด "Press ESC to close" เป็น list ที่แต่ละแถวมีรูป icon ของ item + ชื่อ item + จำนวนที่ถือ (เช่น `1x`, `0x`) โดยแถวที่ผู้เล่นไม่มี (0x) ทั้งรูปและตัวอักษรจะจางลง (dimmed) เมนูวางอยู่กึ่งกลางฝั่งขวาของจอ (right-center) และเปิดด้วยการกดปุ่ม G (รองรับการตั้ง keybind ใหม่ผ่าน `RegisterKeyMapping`)

ขอบเขตของฟีเจอร์:

- **อยู่ในขอบเขต:** สร้าง Rig_Menu (NUI) แทน ox_lib context menu, เปิดเมนูด้วยปุ่ม G ที่ตั้ง keybind ใหม่ได้, แสดง list พร้อม icon/ชื่อ/จำนวน และ dim แถวที่จำนวนเป็น 0, จัดการ attach/detach ชิ้นส่วนผ่าน server callback เดิม, ลบช่องทางเปิดเมนูเดิมทั้งหมด (ox_lib context, ปุ่มคลิกขวา ox_inventory, `/fishrig`), เพิ่ม locale key ที่จำเป็น
- **ไม่อยู่ในขอบเขต:** การเลือกเหยื่อ (bait) — server ยังใช้ `resolveBait()` เลือกเหยื่ออัตโนมัติเหมือนเดิม, การเปลี่ยนแปลง server logic ของ rig (`zfishing:rig:get/attach/detach` คงพฤติกรรมและ signature เดิม), anti-cheat/validation ฝั่ง server, lifecycle การตกปลา 6 สถานะ

**หมายเหตุเรื่องโหมด:** zfishing resource รองรับเฉพาะ Enhanced_Mode เท่านั้น (โหมด simple ไม่มีอยู่ในระบบแล้ว) Rig_Client จึงถือว่าระบบอยู่ใน Enhanced_Mode เสมอ ไม่มีการตรวจสอบโหมดฝั่ง client และไม่มี callback `zfishing:rig:mode` การเปิด Rig_Menu ขึ้นกับเงื่อนไข Equip_Standby_Phase เพียงอย่างเดียว

**สมมติฐานที่ต้องยืนยันในรีวิว:** จากคำตอบ "ใช้ NUI + ปุ่ม G เท่านั้น" ฟีเจอร์นี้ตีความว่าปุ่ม G เป็นช่องทางเดียวในการเปิดเมนู และจะลบทั้งปุ่มคลิกขวา ox_inventory ("Manage Rod") และคำสั่ง `/fishrig` ออก หากต้องการคงช่องทางใดไว้ โปรดแจ้งในรีวิว

**การพึ่งพา:** ฟีเจอร์นี้ต่อยอดจากสเปค `fishing-prompt-hud` ซึ่งแสดง HUD prompt ช่วง equip standby — ฟีเจอร์นี้เพิ่มคำใบ้ให้ผู้เล่นกด G ในช่วงดังกล่าว

## Glossary

- **Rig_Menu**: NUI component ใหม่ที่แสดงเมนูจัดการเบ็ดแบบ list (icon + ชื่อ item + จำนวน) แทนที่ ox_lib context menu เดิม
- **Rig_Client**: สคริปต์ฝั่ง client (`client/rig.lua`) ที่รับผิดชอบการเปิด/ปิด Rig_Menu, ดึง Rig_View จาก server, ส่งข้อมูลให้ NUI ผ่าน `SendNUIMessage`, และส่งคำสั่ง attach/detach กลับไปยัง server callback
- **Fishing_Client**: สคริปต์ฝั่ง client (`client/main.lua`) ที่ควบคุม lifecycle การตกปลาและกำหนดช่วง Equip_Standby_Phase
- **Rig_Keybind**: keybind ที่ลงทะเบียนผ่าน `RegisterCommand` + `RegisterKeyMapping` มีค่าเริ่มต้นเป็นปุ่ม G และผู้เล่นตั้งค่าใหม่ได้ผ่านเมนูตั้งค่าปุ่มของ FiveM
- **Rig_View**: payload ข้อมูลสภาพเบ็ดที่ server ส่งกลับผ่าน callback `zfishing:rig:get` ประกอบด้วยชื่อ/สภาพเบ็ด, ชิ้นส่วนที่ติดตั้งอยู่ (parts), และชิ้นส่วนสำรองที่ถือในกระเป๋า (carried) ต่อ Part_Type
- **Part_Type**: ชนิดชิ้นส่วนเบ็ดหนึ่งใน `reel`, `line`, `hook`, `float`
- **Rig_Row**: แถวหนึ่งใน Rig_Menu ที่แทน item หนึ่งชิ้น แสดง Item_Icon + ชื่อ (label) + Owned_Quantity
- **Item_Icon**: รูปภาพของ item ที่ดึงจากไฟล์ในโฟลเดอร์ `assets/items/<item>.png` ของ resource โดยชื่อไฟล์ตรงกับชื่อ item
- **Owned_Quantity**: จำนวนของ item ชิ้นนั้นที่ผู้เล่นถืออยู่ในกระเป๋า แสดงในรูปแบบ `Nx` (เช่น `1x`, `0x`)
- **Equip_Standby_Phase**: ช่วงที่ผู้เล่นถือเบ็ดพร้อมแล้วแต่ยังไม่ขว้าง (รอกด E เพื่อเริ่มขว้าง หรือ X เพื่อเก็บเบ็ด) ตามที่นิยามใน Fishing_Client
- **Enhanced_Mode**: โหมดที่ระบบ rig assembly เปิดใช้งาน และเป็นโหมดเดียวที่ zfishing resource รองรับ Rig_Client จึงถือว่าระบบอยู่ใน Enhanced_Mode เสมอโดยไม่ต้องตรวจสอบ
- **NUI_Focus**: สถานะที่ NUI รับ input จากเมาส์/คีย์บอร์ด ควบคุมด้วย `SetNuiFocus`
- **Locale_Dictionary**: ตาราง key/value ที่โหลดจาก `locales/{lang}.json` (en เป็นฐาน + ภาษา active overlay) และส่งให้ NUI ผ่าน NUI callback `getLocale`

## Requirements

### Requirement 1: เปิดเมนูจัดการเบ็ดด้วยปุ่ม G

**User Story:** As a player, I want เปิดเมนูจัดการเบ็ดด้วยการกดปุ่ม G, so that ฉันจัดการชิ้นส่วนเบ็ดได้สะดวกโดยไม่ต้องคลิกขวาที่ item ในกระเป๋า

#### Acceptance Criteria

1. WHEN Rig_Client เริ่มทำงาน (resource start), THE Rig_Client SHALL ลงทะเบียน Rig_Keybind ผ่าน `RegisterCommand` และ `RegisterKeyMapping` โดยกำหนดปุ่มเริ่มต้นเป็น `G` บนอุปกรณ์ `keyboard`
2. WHILE ผู้เล่นอยู่ใน Equip_Standby_Phase, WHEN ผู้เล่นกด Rig_Keybind และ Rig_Menu ยังไม่เปิดอยู่, THE Rig_Client SHALL ร้องขอ Rig_View จาก server callback `zfishing:rig:get` และสั่งเปิด Rig_Menu ภายใน 300 มิลลิวินาที นับจากที่ได้รับ Rig_View
3. IF ผู้เล่นกด Rig_Keybind ขณะไม่ได้อยู่ใน Equip_Standby_Phase, THEN THE Rig_Client SHALL ไม่เปิด Rig_Menu และไม่ส่งคำร้องขอ Rig_View ไปยัง server
4. WHILE Rig_Menu เปิดอยู่, WHEN ผู้เล่นกด Rig_Keybind, THE Rig_Client SHALL ปิด Rig_Menu ภายใน 200 มิลลิวินาที
5. THE Rig_Client SHALL อนุญาตให้ผู้เล่นเปลี่ยนปุ่มของ Rig_Keybind ผ่านเมนูตั้งค่าปุ่มของ FiveM โดยไม่ต้องแก้ไขซอร์สโค้ดของ resource
6. IF ผู้เล่นกด Rig_Keybind ขณะที่ Rig_View ที่ร้องขอคืนค่าว่าง (ไม่มีเบ็ดในช่องที่ตรวจสอบ), THEN THE Rig_Client SHALL ไม่เปิด Rig_Menu และแจ้งเตือนผู้เล่นด้วยข้อความ locale `rig_no_rod`
7. IF server callback `zfishing:rig:get` ไม่ตอบกลับภายใน 5000 มิลลิวินาทีหลังการร้องขอ, THEN THE Rig_Client SHALL ยกเลิกการเปิด Rig_Menu คงสถานะเมนูปิด และแจ้งเตือนผู้เล่นด้วยข้อความ locale `rig_error`
8. WHILE มีคำร้องขอ Rig_View ค้างอยู่ (ยังไม่ได้รับผลตอบกลับ), WHEN ผู้เล่นกด Rig_Keybind ซ้ำ, THE Rig_Client SHALL ไม่ส่งคำร้องขอ Rig_View ซ้ำ

### Requirement 2: แสดงรายการชิ้นส่วนแบบ list พร้อม icon และจำนวน

**User Story:** As a player, I want เห็นรายการชิ้นส่วนเบ็ดเป็น list พร้อมรูป จำนวนที่ถือ และหัวข้อชัดเจน, so that ฉันเลือกชิ้นส่วนที่จะใส่หรือถอดได้ง่าย

#### Acceptance Criteria

1. WHEN Rig_Menu ถูกเปิด, THE Rig_Menu SHALL แสดงหัวข้อ (title) จาก Locale_Dictionary และบรรทัดคำแนะนำ "Press ESC to close" จาก Locale_Dictionary
2. WHEN Rig_Menu ถูกเปิดด้วย Rig_View ที่กำหนด, THE Rig_Menu SHALL แสดง Rig_Row หนึ่งแถวต่อ item ที่จัดการได้แต่ละชิ้น เรียงลำดับจากบนลงล่างตามลำดับที่ item ปรากฏใน Rig_View (index จากน้อยไปมาก) โดยแต่ละ Rig_Row ประกอบด้วย Item_Icon, ชื่อ item (label), และ Owned_Quantity
3. WHEN แสดง Owned_Quantity ของ Rig_Row, THE Rig_Menu SHALL แสดงค่าดังกล่าวเป็นจำนวนเต็มในช่วง 0 ถึง 9999 ในรูปแบบ `Nx` โดยหาก Owned_Quantity มากกว่า 9999 ให้แสดงเป็น `9999x`
4. THE Rig_Menu SHALL ดึง Item_Icon ของแต่ละ Rig_Row จากไฟล์ในโฟลเดอร์ `assets/items/` ของ resource โดยอ้างชื่อไฟล์ตามชื่อ item ของ Rig_Row นั้น
5. WHERE Owned_Quantity ของ Rig_Row เท่ากับ 0, THE Rig_Menu SHALL แสดง Rig_Row นั้นในสภาพจาง (dimmed) โดยกำหนดค่า opacity ของทั้ง Item_Icon และตัวอักษรไม่เกิน 0.5
6. WHERE Owned_Quantity ของ Rig_Row มากกว่า 0, THE Rig_Menu SHALL แสดง Rig_Row นั้นด้วย opacity เต็ม (1.0)
7. IF ไฟล์ Item_Icon ของ Rig_Row ไม่สามารถโหลดได้, THEN THE Rig_Menu SHALL แสดง Rig_Row นั้นต่อไปโดยยังคงแสดงชื่อ item และ Owned_Quantity ครบถ้วน และแสดงพื้นที่ว่างแทนตำแหน่งของ Item_Icon โดยไม่ทำให้แถวอื่นเลื่อนตำแหน่ง
8. IF Rig_View ที่ใช้เปิด Rig_Menu ไม่มี item ที่จัดการได้เลย (จำนวน Rig_Row เท่ากับ 0), THEN THE Rig_Menu SHALL แสดงหัวข้อและบรรทัดคำแนะนำตามข้อ 1 พร้อมข้อความจาก Locale_Dictionary ที่ระบุว่าไม่มีรายการชิ้นส่วนให้จัดการ
9. THE Rig_Menu SHALL จัดวางตัวเองโดยชิดกึ่งกลางแนวตั้ง (vertical center) ของหน้าจอและชิดด้านขวา โดยเว้นระยะห่างจากขอบขวาของหน้าจอไม่น้อยกว่า 2% ของความกว้างหน้าจอ

### Requirement 3: ควบคุม NUI Focus และการปิดด้วย ESC

**User Story:** As a player, I want เมนูรับการคลิกเมาส์ได้และปิดด้วยปุ่ม ESC, so that ฉันโต้ตอบกับเมนูได้และกลับไปควบคุมเกมได้ตามปกติ

#### Acceptance Criteria

1. WHEN Rig_Client เปิด Rig_Menu, THE Rig_Client SHALL ตั้ง NUI_Focus ให้รับ input จากเมาส์และคีย์บอร์ด (`SetNuiFocus(true, true)`) ภายใน 100 มิลลิวินาทีหลังเมนูแสดงผล
2. WHEN ผู้เล่นกดปุ่ม ESC ขณะ Rig_Menu เปิดอยู่, THE Rig_Menu SHALL แจ้ง Rig_Client ให้ปิดเมนูผ่าน `fetchNui` ภายใน 100 มิลลิวินาทีหลังรับ keydown event
3. WHEN Rig_Client ปิด Rig_Menu, THE Rig_Client SHALL คืน NUI_Focus (`SetNuiFocus(false, false)`) และสั่งซ่อนองค์ประกอบทั้งหมดของ Rig_Menu ภายใน 200 มิลลิวินาที
4. IF Rig_Client ปิด Rig_Menu จากเหตุใด ๆ (กด ESC, กด Rig_Keybind ซ้ำ, หรือ cleanup การตกปลา), THEN THE Rig_Client SHALL คืน NUI_Focus (`SetNuiFocus(false, false)`) ทุกกรณีภายใน 200 มิลลิวินาที เพื่อไม่ให้เมาส์ค้างบนหน้าจอ
5. IF การแจ้งปิดเมนูผ่าน `fetchNui` ไม่สำเร็จหรือไม่ได้รับการตอบกลับภายใน 500 มิลลิวินาที, THEN THE Rig_Client SHALL คืน NUI_Focus (`SetNuiFocus(false, false)`) และซ่อน Rig_Menu โดยใช้ค่า timeout ฝั่ง client เป็น fallback เพื่อป้องกันเมาส์ค้างบนหน้าจอ
6. WHILE Rig_Menu ปิดอยู่แล้ว (NUI_Focus ถูกคืนแล้ว), WHEN มีคำสั่งปิดซ้ำ, THE Rig_Client SHALL เพิกเฉยต่อคำสั่งปิดซ้ำและคง NUI_Focus ไว้ที่สถานะ `false, false` โดยไม่เปลี่ยนแปลงสถานะการควบคุมเกม
7. IF Rig_Client คืน NUI_Focus (`SetNuiFocus(false, false)`) สำเร็จแต่การซ่อนองค์ประกอบภาพของ Rig_Menu ล้มเหลว, THEN THE Rig_Client SHALL ดำเนินการ cleanup แบบบางส่วนต่อไปโดยคง NUI_Focus ไว้ที่ `false, false` แม้องค์ประกอบภาพบางส่วนยังคงแสดงอยู่ เพื่อไม่ให้เมาส์ค้างบนหน้าจอ

### Requirement 4: จัดการ attach/detach ชิ้นส่วนผ่าน server callback เดิม

**User Story:** As a player, I want ใส่หรือถอดชิ้นส่วนเบ็ดจากเมนู NUI, so that ฉันประกอบเบ็ดให้พร้อมใช้งานได้เหมือนเมนูเดิม

#### Acceptance Criteria

1. WHEN ผู้เล่นเลือก Rig_Row ที่แทนชิ้นส่วนสำรองที่ถืออยู่ (Owned_Quantity มากกว่า 0) และ Part_Type ของชิ้นส่วนนั้นยังว่างบนเบ็ด, THE Rig_Client SHALL เรียก server callback `zfishing:rig:attach` ด้วย slot ของเบ็ด, Part_Type และชื่อ item เดิมตามที่ callback รองรับ
2. WHEN ผู้เล่นเลือกชิ้นส่วนที่ติดตั้งอยู่บนเบ็ดเพื่อถอด, THE Rig_Client SHALL เรียก server callback `zfishing:rig:detach` ด้วย slot ของเบ็ด และ Part_Type ตามที่ callback รองรับ
3. IF ผู้เล่นเลือก Rig_Row ที่มี Owned_Quantity เท่ากับ 0 หรือ Part_Type นั้นถูกติดตั้งอยู่บนเบ็ดแล้ว, THEN THE Rig_Client SHALL ไม่เรียก server callback `zfishing:rig:attach` และแจ้งเตือนผู้เล่นด้วยข้อความ locale `rig_error` พร้อมคงสภาพเบ็ดที่แสดงไว้ตามเดิม
4. WHEN server callback `zfishing:rig:attach` หรือ `zfishing:rig:detach` คืนค่าสำเร็จ (`ok = true`), THE Rig_Client SHALL ร้องขอ Rig_View ใหม่และปรับ Rig_Menu ให้แสดงสภาพเบ็ดล่าสุดภายใน 300 มิลลิวินาที
5. WHEN server callback `zfishing:rig:attach` คืนค่าสำเร็จ (`ok = true`), THE Rig_Client SHALL แจ้งเตือนผู้เล่นด้วยข้อความ locale `attached` ภายใน 300 มิลลิวินาที
6. WHEN server callback `zfishing:rig:detach` คืนค่าสำเร็จ (`ok = true`), THE Rig_Client SHALL แจ้งเตือนผู้เล่นด้วยข้อความ locale `detached` ภายใน 300 มิลลิวินาที
7. IF server callback `zfishing:rig:detach` คืนค่าล้มเหลวด้วยเหตุ `inv_full`, THEN THE Rig_Client SHALL แจ้งเตือนผู้เล่นด้วยข้อความ locale `rig_inv_full` ภายใน 300 มิลลิวินาที และคงสภาพเบ็ดที่แสดงไว้ตามเดิม
8. IF server callback `zfishing:rig:attach` หรือ `zfishing:rig:detach` คืนค่าล้มเหลวด้วยเหตุอื่นนอกเหนือจาก `inv_full`, THEN THE Rig_Client SHALL แจ้งเตือนผู้เล่นด้วยข้อความ locale `rig_error` ภายใน 300 มิลลิวินาที และคงสภาพเบ็ดที่แสดงไว้ตามเดิม
9. IF server callback `zfishing:rig:attach` หรือ `zfishing:rig:detach` ไม่คืนค่าภายใน 5 วินาทีหลังการเรียก, THEN THE Rig_Client SHALL ยกเลิกการรอผล แจ้งเตือนผู้เล่นด้วยข้อความ locale `rig_error` และคงสภาพเบ็ดที่แสดงไว้ตามเดิม
10. THE Rig_Client SHALL ไม่เปลี่ยนแปลงชื่อ, จำนวน argument, ลำดับ argument และรูปแบบ payload ของ server callback `zfishing:rig:get`, `zfishing:rig:attach` และ `zfishing:rig:detach`

### Requirement 5: แทนที่ช่องทางเปิดเมนูเดิมทั้งหมด

**User Story:** As a server owner, I want ให้เมนูจัดการเบ็ดเปิดจากปุ่ม G เท่านั้น, so that มีช่องทางเดียวที่สอดคล้องกันและไม่มีเมนูเดิมค้างอยู่

#### Acceptance Criteria

1. THE Rig_Client SHALL ไม่ลงทะเบียนและไม่แสดง ox_lib context menu สำหรับการจัดการเบ็ดในทุกกรณี (ต้องไม่มีการเรียก `lib.registerContext` หรือ `lib.showContext` ที่มี context id ของ rig ตลอดอายุการทำงานของ resource)
2. WHEN Rig_Client ได้รับ event `zfishing:manageRod` จาก ox_inventory (คลิกขวาจัดการเบ็ด), THE Rig_Client SHALL ไม่เปิดเมนูใด ๆ และไม่เปลี่ยนสถานะ UI ใด ๆ จาก event นั้น
3. THE zfishing resource SHALL ไม่ลงทะเบียนคำสั่ง `/fishrig` (ต้องไม่มีการเรียก `RegisterCommand` สำหรับ `fishrig`) ดังนั้นเมื่อผู้เล่นพิมพ์ `/fishrig` ระบบต้องไม่เปิด Rig_Menu
4. WHEN ผู้เล่นกดปุ่ม G ในขณะที่เงื่อนไขการใช้งานเบ็ดถูกต้อง, THE Rig_Client SHALL เปิด Rig_Menu (NUI) ภายใน 200 มิลลิวินาที และแสดง Rig_Menu เพียงหนึ่งอินสแตนซ์เท่านั้น
5. WHILE Rig_Menu (NUI) เปิดอยู่, THE Rig_Client SHALL ไม่แสดง ox_lib context menu หรือเมนูจัดการเบ็ดช่องทางอื่นควบคู่กัน (จำนวนเมนูจัดการเบ็ดที่แสดงพร้อมกันต้องเท่ากับ 1 เสมอ)
6. IF มีการ trigger ช่องทางเปิดเมนูจัดการเบ็ดแบบเดิม (ox_lib context menu, event `zfishing:manageRod`, หรือคำสั่ง `/fishrig`), THEN THE Rig_Client SHALL ไม่เปิดเมนูใด ๆ และคงสถานะ UI ปัจจุบันไว้โดยไม่เปลี่ยนแปลง
7. IF Rig_Client ไม่สามารถทำให้ Rig_Menu แสดงผลได้ภายใน 200 มิลลิวินาทีนับจากที่ได้รับ Rig_View และเริ่มสั่งเปิดเมนู, THEN THE Rig_Client SHALL ยกเลิกการเปิด Rig_Menu และคงสถานะเมนูปิดไว้ แทนการเปิดเมนูล่าช้าเกินกำหนด

### Requirement 6: Localization ของ Rig Menu

**User Story:** As a player, I want เมนูจัดการเบ็ดแสดงเป็นภาษาที่ตั้งค่าไว้ (รวมภาษาไทย), so that ฉันอ่านข้อความในเมนูได้ในภาษาของฉัน

#### Acceptance Criteria

1. WHEN Rig_Menu ถูกเรนเดอร์ครั้งแรก, THE Rig_Menu SHALL เรียก NUI callback `getLocale` เพื่อดึงข้อความหัวข้อและคำแนะนำทั้งหมดจาก Locale_Dictionary ให้เสร็จภายใน 5 วินาที ก่อนแสดงข้อความบนหน้าจอ
2. THE Locale_Dictionary SHALL มี locale key สำหรับหัวข้อ Rig_Menu และคำแนะนำ "Press ESC to close" ในไฟล์ `locales/en.json` และ `locales/th.json`
3. IF locale key ที่ร้องขอไม่มีในภาษา active ของ Locale_Dictionary แต่มีอยู่ในภาษา en (ภาษาฐาน), THEN THE Rig_Menu SHALL ใช้ค่าของ locale key เดียวกันจากภาษา en แทน
4. IF locale key ที่ร้องขอไม่มีทั้งในภาษา active และภาษา en, THEN THE Rig_Menu SHALL แสดงข้อความ fallback ที่กำหนดไว้ล่วงหน้าในโค้ด (ค่าคงที่ต่อ 1 key) แทนการแสดง key ดิบ และยังคงเรนเดอร์เมนูต่อได้โดยไม่หยุดทำงาน
5. IF NUI callback `getLocale` ล้มเหลวหรือไม่ตอบกลับภายใน 5 วินาที, THEN THE Rig_Menu SHALL ใช้ค่าจากภาษา en (ภาษาฐาน) สำหรับทุก locale key และแสดงตัวบ่งชี้ข้อผิดพลาดว่าโหลดภาษาไม่สำเร็จ โดยไม่หยุดการเรนเดอร์เมนู

### Requirement 7: จำกัดผลกระทบเฉพาะฝั่งการนำเสนอและช่องทางเปิดเมนู

**User Story:** As a server owner, I want การเปลี่ยนแปลงนี้ไม่กระทบ server logic และการเลือกเหยื่อ, so that ระบบตกปลา, การประกอบเบ็ดฝั่ง server และ anti-cheat ยังทำงานเหมือนเดิม

#### Acceptance Criteria

1. THE zfishing resource SHALL คงชื่อ event, จำนวน argument, ลำดับ argument, ชนิดของ argument และโครงสร้าง return value ของ server callback `zfishing:rig:get`, `zfishing:rig:attach`, `zfishing:rig:detach` ให้ตรงกับเวอร์ชันก่อนการเปลี่ยนแปลงทุกรายการ
2. THE zfishing resource SHALL คงตรรกะการตรวจสอบสิทธิ์ (ownership/slot validation) และการเขียน metadata ของ rig ฝั่ง server ไว้เดิมโดยไม่แก้ไข
3. THE Fishing_Client SHALL คง lifecycle การตกปลา 6 สถานะ (equip standby, charge, cast callback, waiting, reeling, cleanup) ไว้ครบตามลำดับเดิมโดยไม่เพิ่ม ไม่ลบ และไม่สลับลำดับสถานะใด ๆ
4. THE zfishing resource SHALL คงให้ server ใช้ `resolveBait()` เลือกเหยื่ออัตโนมัติเหมือนเดิม โดยการเลือกอัตโนมัติฝั่ง server ต้องยังทำงานได้เต็มรูปแบบ แม้ในภายหลังจะมีการเพิ่มตัวเลือกเลือกเหยื่อแบบ manual ผ่าน Rig_Menu ก็ตาม (ทั้งสองวิธีต้องทำงานอยู่ร่วมกันได้โดยไม่ขัดแย้งกัน)
5. IF การเรียก server callback ของ rig ไม่คืนค่าภายใน 10 วินาที, THEN THE Rig_Client SHALL คงสภาพข้อมูลที่แสดงไว้ตามเดิมโดยไม่เปลี่ยนแปลง
6. IF การเรียก server callback ของ rig ไม่คืนค่าภายใน 10 วินาที, THEN THE Rig_Client SHALL แจ้งเตือนผู้เล่นผ่านช่องทาง notify ที่มีอยู่
