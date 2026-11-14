# ติดตามงาน reallyCute

หน้าเช็คลิสต์สินค้าอยู่ที่ `content-task-tracker.html` และขึ้น Cloudflare Pages ที่ `/content-task-tracker`.

ข้อมูลหลักอยู่ใน Supabase ตาราง `app_data`

| key | ความหมาย |
| --- | --- |
| `products` | ก้อนสินค้า gzip+base64 `{ list, order, trash, updatedAt, csku_retired, costCfg? }` |
| `posts` | โพสต์ |
| `sales` | ยอดขาย |

รูปแบบก้อน `products` ไม่ได้เปลี่ยน บอทเดิมที่อ่าน `value` แล้วคลาย gzip ยังใช้ได้

## หลายคนแก้พร้อมกัน

หน้าเว็บไม่เขียนทับทั้งก้อนก้อนเดิมอีกต่อไป

1. จำ `updated_at` ตอนโหลด
2. ก่อนบันทึก อ่านแถวล่าสุด
3. ถ้ามีคนอื่นเขียนไปแล้ว จะรวมเฉพาะช่องที่แต่ละฝ่ายแก้ (สินค้าคนละชิ้นอยู่ครบทั้งคู่)
4. เขียนกลับด้วยเงื่อนไข `updated_at` เดิม ถ้าชนกันจะอ่านใหม่แล้วรวมอีกครั้ง
5. แท็บที่เปิดค้างอยู่จะเห็นของคนอื่นเอง โดยโพลทุกประมาณ 8 วินาที และฟัง Supabase Realtime ถ้าเปิด publication แล้ว

ช่องเดียวกันของสินค้าชิ้นเดียวกัน ถ้าสองฝ่ายแก้พร้อมกัน คนที่บันทึกทีหลังได้ค่านั้น ช่องอื่นของชิ้นนั้นยังอยู่

ถ้าเปิดหน้าแล้วต่อคลาวด์ไม่ทัน และยังไม่เคยโหลดก้อนจากเซิร์ฟเวอร์ในรอบนั้น หน้าเว็บจะไม่ upsert ทับแถวที่มีอยู่แล้ว

ตั้งชื่อผู้ใช้ที่ปุ่ม «ตั้งชื่อผู้ใช้» ชื่อนี้ติดไปกับบันทึกกิจกรรมของเครื่องนั้น

## SQL ที่ต้องรันเอง

ไฟล์ `supabase/migrations/20261110120000_activity_log_and_realtime.sql`

รันใน Supabase SQL Editor ของโปรเจกต์นี้ **ด้วยมือ** PR นี้ไม่ได้รันกับ production และไม่ได้ย้ายข้อมูลเดิม

ก่อนรัน SQL หน้าเว็บยังใช้ได้

- การรวมสินค้า/โพสต์/ยอดขายไม่ต้องมีตารางใหม่
- กิจกรรมจะถูกเก็บสำรองที่ `app_data` key `activity` (ก้อน gzip `{ "v": 1, "entries": [...] }` ไม่เกิน 300 รายการ)
- Realtime อาจยังไม่มีอีเวนต์ จนกว่าตารางจะอยู่ใน publication `supabase_realtime` หน้าเว็บจึงโพลต่อ

หลังรัน SQL หน้าเว็บและบอทจะ insert ลง `activity_log` แทน และ realtime ของ `app_data` กับ `activity_log` ใช้ได้

## บอทส่งบันทึกกิจกรรม

ใช้ anon key ตัวเดียวกับในหน้าเว็บ (`SUPABASE_KEY`) ห้ามใส่ service role ในสคริปต์ที่มากับหน้าเว็บ

ฟิลด์ที่ insert

| ฟิลด์ | ชนิด | จำเป็น | ความหมาย |
| --- | --- | --- | --- |
| `actor` | text | ใช่ | ชื่อบอทหรือคน เช่น `บอท-sku` |
| `action` | text | ใช่ | เช่น `edit`, `add`, `save-products` |
| `summary` | text | ใช่ | ประโยคสั้นภาษาไทยที่โชว์ในไทม์ไลน์ |
| `detail` | jsonb | ไม่ | รายละเอียด เช่น `{ "edited": [{ "id", "label", "fields" }] }` |

`created_at` ให้ฐานข้อมูลใส่เอง อย่าส่ง `id`

หน้าเว็บใช้ `detail` แบบนี้เมื่อคนกดบันทึก (ใส่ได้ไม่ครบก็ได้)

```json
{
  "key": "products",
  "added": [{ "id": "abc", "label": "ชื่อสินค้า" }],
  "edited": [{ "id": "def", "label": "ชื่อสินค้า", "fields": ["csku", "ph"] }],
  "trashed": [],
  "restored": [],
  "addedCount": 1,
  "editedCount": 1
}
```

`fields` เป็นชื่อฟิลด์ในสินค้า เช่น `ph` `vd` `up` `g` `csku` `sp` `s` `rights` `set`

ตัวอย่าง Python (stdlib เท่านั้น) หลังรัน SQL แล้ว

```python
import json
import urllib.request

URL = "https://hcuqtpymbarurliqxmeh.supabase.co"
KEY = "sb_publishable_9TXJ5TdQnBRx0uKr3DPaaA_KlC_Sb1K"  # anon key เดียวกับในหน้าเว็บ

def log_activity(actor, action, summary, detail=None):
    body = json.dumps({
        "actor": actor,
        "action": action,
        "summary": summary,
        "detail": detail or {},
    }).encode()
    req = urllib.request.Request(
        URL + "/rest/v1/activity_log",
        data=body,
        method="POST",
        headers={
            "apikey": KEY,
            "Authorization": "Bearer " + KEY,
            "Content-Type": "application/json",
            "Prefer": "return=minimal",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as res:
        res.read()

log_activity(
    "บอท-sku",
    "edit",
    "บอทตั้ง SKU กลาง 1 รายการ",
    {"key": "products", "edited": [{"id": "abc", "label": "ชื่อสินค้า", "fields": ["csku"]}], "editedCount": 1},
)
```

ถ้าได้ 404 หรือ `PGRST205` แปลว่ายังไม่ได้รัน SQL ทางสำรองคืออ่าน `app_data` key `activity` แล้วเขียนกลับทั้งก้อน `{ "v": 1, "entries": [...] }` แบบ gzip+base64 เดียวกับ `products` (`{ "compressed": true, "data": "<base64>" }`) โดย `PATCH` เฉพาะเมื่อ `updated_at` ยังตรงกับตอนที่อ่าน รายการใหม่อยู่ตัวแรก และตัดให้เหลือไม่เกิน 300 รายการ แต่ละรายการมี `id`, `created_at`, `actor`, `action`, `summary`, `detail`

หน้าแท็บ «กิจกรรม» จะว่างจนกว่าจะมีแถวจริง ไม่มีการสมมติประวัติขึ้นเอง มีแค่เวลา `updatedAt` ของก้อนสินค้า ซึ่งไม่มีชื่อคนแก้

## บอทเขียนก้อน products

รูปแบบเดิม: `value` เป็น `{ "compressed": true, "data": "<gzip base64>" }` ของ JSON `{ list, order, trash, updatedAt, csku_retired }`

อย่า upsert ทับทั้งแถวจากสำเนาเก่า ให้อ่าน `updated_at` แล้วเขียนแบบมีเงื่อนไข

```python
# หลังแก้ pack ในหน่วยความจำแล้ว gzip ใส่ packed
req = urllib.request.Request(
    URL + "/rest/v1/app_data?key=eq.products&updated_at=eq." + urllib.parse.quote(old_updated_at, safe=""),
    data=json.dumps({"value": packed, "updated_at": new_iso}).encode(),
    method="PATCH",
    headers={
        "apikey": KEY,
        "Authorization": "Bearer " + KEY,
        "Content-Type": "application/json",
        "Prefer": "return=representation",
    },
)
```

ถ้าผลลัพธ์เป็นแถวว่าง แสดงว่ามีคนเขียนไปแล้ว ให้อ่านก้อนใหม่ ใส่เฉพาะส่วนที่บอทตั้งใจเปลี่ยน แล้วลอง PATCH อีกครั้ง

## ทดสอบตรรกะการรวม

```bash
node sync-merge.test.mjs
```

เทสต์นี้ไม่ต่อ Supabase และไม่เขียนข้อมูลจริง

## แท็บงานเตรียม (แคมเปญ)

วางแผนงานเตรียมคอนเทนต์ทั้งสัปดาห์ (สัปดาห์เริ่มวันเสาร์) ข้อมูลอยู่ในตารางใหม่ ไม่แตะ `app_data`

| ตาราง | ความหมาย |
| --- | --- |
| `campaigns` | 1 แคมเปญ = 1 ชุดโพสต์: `name`, `post_start`, `post_end`, `image_date`, `city`, `product_type` (`licensed` / `original` / `unlicensed` / null = รอเลือก), `channels`, `shops`, `product_ids` (jsonb), `note`, `media_kind`, `media_url`, `caption`, `post_id` |
| `campaign_tasks` | งานย่อย: `campaign_id`, `sort`, `title`, `detail`, `assignee` (ริตา / Claude / Grok bot / อัตโนมัติ), `due_date`, `status` (`todo` / `doing` / `done`), `template_key` (`schedule_post` = งานตั้งเวลาโพสต์) |

- ลบจากหน้าเว็บ = ใส่ `deleted_at` (เห็นในแท็บถังขยะ 7 วัน กู้คืนได้) anon ไม่มีสิทธิ์ DELETE
- ทุกการเพิ่ม/แก้/ติ๊ก/ลบ/กู้คืน บันทึกลง `activity_log` (action `campaign-*` / `task-*`)
- งาน `schedule_post` เสร็จ → ปุ่ม «บันทึกการโพสต์» เปิดฟอร์มเดิมในปฏิทิน กรอกสินค้า วันที่ ชนิดสื่อ ช่องทาง แคปชั่นให้
- SQL: `supabase/migrations/20261114140000_prep_campaigns.sql` (รันแล้วกับโปรเจกต์นี้)
- บอทอ่าน/เขียนได้ด้วย anon key ผ่าน REST `/rest/v1/campaigns` และ `/rest/v1/campaign_tasks` แล้ว insert `activity_log` ทุกครั้ง

## จำการเข้าใช้งาน 30 วัน

- ใส่รหัสถูกครั้งเดียว เบราว์เซอร์นั้นจะจำไว้ 30 วัน (localStorage key `tuka-gate-remember` = `{ until, p }` โดย `p` เป็นลายนิ้วมือของรหัส ไม่ใช่รหัสจริง)
- เปลี่ยน `APP_PASSWORD` แล้ว ทุกเครื่องต้องใส่รหัสใหม่ (ลายนิ้วมือไม่ตรง)
- ปุ่ม «ออกจากระบบ» อยู่ในเมนู ⋯ เพิ่มเติม (รอให้การแก้ที่ค้างอยู่ขึ้นคลาวด์ก่อน แล้วล้างการจำ)
- จำแยกต่อเว็บไซต์ ลิงก์ทดลอง (`*.reallycute-tracker.pages.dev`) กับเว็บจริงต้องใส่รหัสแยกกันครั้งแรก
