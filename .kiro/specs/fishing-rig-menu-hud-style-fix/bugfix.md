# Bugfix Requirements Document

## Introduction

บั๊กนี้เป็น follow-up จากสองสเปคที่เพิ่ง implement (`fishing-rig-menu-nui` และ `fishing-prompt-hud`) มี 2 อาการที่ทำให้ UI ไม่เข้าชุดกันและคำใบ้ปุ่มไม่ครบ:

1. **เมนูจัดการเบ็ด (Rig_Menu NUI)** ถูกเรนเดอร์เป็นกล่องพื้นหลังทึบสีเข้ม (dark panel) ซึ่งไม่เข้ากับสไตล์ HUD ตกปลากลางล่างที่เป็นตัวอักษรลอยพื้นหลังโปร่งใส ผู้ใช้ต้องการให้เมนูเป็นแบบตัวหนังสือสีขาวมีเงา (text-shadow) พื้นหลังโปร่งใสทั้งหมด แบบเดียวกับ HUD ตกปลา
2. **HUD กลางล่าง (Prompt_HUD)** ช่วง equip standby แสดง subtitle `[E] เริ่มตกปลา · [X] เก็บเบ็ด` แต่ไม่มีคำใบ้ให้กดปุ่ม G เพื่อเปิดเมนูจัดการเบ็ด ทั้งที่ปุ่ม G เปิดเมนูได้จริงในช่วงนี้

ผลกระทบ: ผู้เล่นไม่รู้ว่ากด G เปิดเมนูจัดการเบ็ดได้ และเมนูดูไม่กลมกลืนกับ HUD ที่เหลือของระบบตกปลา

**หมายเหตุขอบเขต (จากการอ่านโค้ดจริง):** `client/rig.lua` ตัดการตรวจ simple/enhanced mode ออกไปแล้ว — เมนู G เปิดได้เสมอในช่วง equip standby โดยไม่มีการเรียก `zfishing:rig:mode` และฝั่ง client ไม่รับรู้ค่า `Zfishing.Enhanced()` ของ server ดังนั้นคำใบ้ปุ่ม G จะถูกแสดงพร้อมกันกับ standby prompt เสมอ (ไม่เพิ่ม logic ตรวจ mode ใหม่ เพื่อไม่ขยายขอบเขตเกินการแก้บั๊ก)

## Bug Analysis

### Current Behavior (Defect)

เมื่อเปิดเมนูจัดการเบ็ด และเมื่อ HUD แสดงช่วง equip standby ระบบมีพฤติกรรมที่ผิดดังนี้:

1.1 WHEN เมนูจัดการเบ็ด (Rig_Menu) ถูกเรนเดอร์ THEN the system วาดกล่องพื้นหลังทึบสีเข้ม (`background: var(--bg)`), เส้นขอบ (`border` + `border-left` accent), เงา (`box-shadow`) และ `backdrop-filter: blur` ครอบเมนู ทำให้เป็นกล่องทึบ ไม่กลมกลืนกับ HUD ตกปลา
1.2 WHEN เมนูจัดการเบ็ดถูกเรนเดอร์ THEN the system แสดงตัวอักษรโดยไม่มี text-shadow ต่างจากที่ผู้ใช้ต้องการให้เข้าชุดกับ HUD ตกปลา
1.3 WHEN HUD แสดงช่วง equip standby (title `การตกปลา`) THEN the system แสดง subtitle `[E] เริ่มตกปลา · [X] เก็บเบ็ด` โดยไม่มีคำใบ้ปุ่ม G สำหรับเปิดเมนูจัดการเบ็ด

### Expected Behavior (Correct)

พฤติกรรมที่ถูกต้องสำหรับเงื่อนไขเดียวกัน:

2.1 WHEN เมนูจัดการเบ็ด (Rig_Menu) ถูกเรนเดอร์ THEN the system SHALL แสดงเมนูโดยพื้นหลังโปร่งใสทั้งหมด — ไม่มีกล่อง/พื้นหลังทึบ, ไม่มีเส้นขอบ box, ไม่มี box-shadow และไม่มี backdrop blur ที่ทำให้เกิดกล่องทึบ
2.2 WHEN เมนูจัดการเบ็ดถูกเรนเดอร์ THEN the system SHALL แสดงตัวอักษรสีขาวพร้อม text-shadow ในสไตล์เดียวกับ HUD ตกปลา (หัวข้อตัวใหญ่, บรรทัดคำใบ้ "กด ESC เพื่อปิด", และแต่ละแถวมี icon + ชื่อ + จำนวน บนพื้นหลังโปร่งใส)
2.3 WHEN HUD แสดงช่วง equip standby (title `การตกปลา`) THEN the system SHALL แสดง subtitle ที่รวมคำใบ้ปุ่ม G ต่อท้าย เป็น `[E] เริ่มตกปลา · [X] เก็บเบ็ด · [G] จัดการเบ็ด` (en: `[E] Start fishing · [X] Pack up rod · [G] Manage Rod`)

### Unchanged Behavior (Regression Prevention)

พฤติกรรมเดิมที่ต้องคงไว้หลังการแก้:

3.1 WHEN ผู้เล่นกด G ขณะ equip standby หรือกด ESC ขณะเมนูเปิด THEN the system SHALL CONTINUE TO เปิด/ปิดเมนู และทำ attach/detach ชิ้นส่วนได้เหมือนเดิม
3.2 WHEN HUD แสดงช่วง equip standby THEN the system SHALL CONTINUE TO แสดง title `การตกปลา` และคำสั่ง `[E]` / `[X]` เดิม พร้อม layout กลางล่างของจอเหมือนเดิม
3.3 WHEN ภาษาที่ใช้งานเป็นไทยหรืออังกฤษ หรือเมื่อ locale โหลดไม่สำเร็จ THEN the system SHALL CONTINUE TO แสดงข้อความตามภาษาที่ถูกต้อง และ fallback ตามเดิม
3.4 WHEN มีการทำ attach/detach หรือ cast ผ่าน server callbacks THEN the system SHALL CONTINUE TO ทำงานตาม server logic / anti-cheat เดิม โดยไม่มีการแก้ไขฝั่ง server
3.5 WHEN `Config.PromptHud = false` (โหมด TextUI fallback) THEN the system SHALL CONTINUE TO แสดงคำใบ้ผ่าน `lib.showTextUI` ตามเดิม (รวมคำใบ้ปุ่ม G ที่เพิ่มเข้าไปใน subtitle key)

## Deriving the Bug Condition

### Bug Condition Function

```pascal
FUNCTION isBugCondition(X)
  INPUT: X of type RenderContext
  OUTPUT: boolean

  // อาการ 1: เมนูจัดการเบ็ดถูกเรนเดอร์ (มีกล่องทึบ/ไม่มี text-shadow)
  // อาการ 2: HUD อยู่ช่วง equip standby (subtitle ไม่มีคำใบ้ G)
  RETURN (X.surface = 'rig_menu')
      OR (X.surface = 'prompt_hud' AND X.phase = 'equip_standby')
END FUNCTION
```

### Property Specification (Fix Checking)

```pascal
// Property: Fix Checking — Rig_Menu โปร่งใส + text-shadow
FOR ALL X WHERE isBugCondition(X) AND X.surface = 'rig_menu' DO
  render ← RigMenu'(X)
  ASSERT no_solid_background(render)
     AND no_box_border(render)
     AND no_box_shadow(render)
     AND has_text_shadow(render)
END FOR

// Property: Fix Checking — คำใบ้ปุ่ม G ใน equip standby
FOR ALL X WHERE isBugCondition(X) AND X.surface = 'prompt_hud' AND X.phase = 'equip_standby' DO
  subtitle ← resolvePromptText('equip_hint')
  ASSERT contains(subtitle, '[G]') AND contains(subtitle, 'จัดการเบ็ด' OR 'Manage Rod')
END FOR
```

### Preservation Goal (Preservation Checking)

```pascal
// Property: Preservation Checking
FOR ALL X WHERE NOT isBugCondition(X) DO
  ASSERT F(X) = F'(X)
END FOR
```

สำหรับทุก input ที่ไม่ใช่เงื่อนไขบั๊ก (เช่น HUD ช่วง cancel/reeling, การเปิด/ปิดเมนูด้วย G/ESC, attach/detach, server callbacks, locale fallback และ TextUI fallback) โค้ดที่แก้แล้ว (F') ต้องมีพฤติกรรมเหมือนโค้ดเดิม (F) ทุกประการ

**Key Definitions:**
- **F**: โค้ดก่อนแก้ (Rig_Menu เป็นกล่องทึบ, subtitle ไม่มีคำใบ้ G)
- **F'**: โค้ดหลังแก้ (Rig_Menu โปร่งใส + text-shadow, subtitle มีคำใบ้ G)
