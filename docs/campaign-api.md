# Campaign API (ข้อมูลกลางของแคมเปญ)

บอท ADMIN / พนักงานลงสินค้า อ่านข้อมูลแคมเปญจากแท็บ «งานเตรียม» ได้จาก Supabase ด้วย **ชื่อแคมเปญ**

- Base URL: `https://hcuqtpymbarurliqxmeh.supabase.co/rest/v1`
- Headers: `apikey: <ANON_KEY>` และ `Authorization: Bearer <ANON_KEY>` (`Content-Type: application/json` สำหรับ POST)
- `<ANON_KEY>` = publishable anon key ตัวเดียวกับที่อยู่ใน `content-task-tracker.html` (`SUPABASE_KEY = "..."`) — เป็นคีย์สาธารณะ ไม่ใช่รหัสผ่าน tracker

```bash
SB=https://hcuqtpymbarurliqxmeh.supabase.co/rest/v1
KEY=$(curl -s https://reallycute-tracker.pages.dev/content-task-tracker | grep -o 'SUPABASE_KEY = "[^"]*"' | cut -d'"' -f2)
```

## 1. อ่านแคมเปญด้วยชื่อ — `get_campaign(name)`

ไม่สนตัวพิมพ์ ชื่อตรงทั้งชื่อได้ก่อน ถ้าไม่ตรงจะค้นบางส่วน (`ilike %name%`) แล้วคืนแคมเปญล่าสุด 1 อัน ไม่รวมที่อยู่ในถังขยะ
ไม่เจอ → คืน `null`

```bash
curl -s -X POST "$SB/rpc/get_campaign" -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" -d '{"name":"mickey & friends"}'
```

ผลลัพธ์ (ย่อ):

```json
{
  "id": "93ec3b77-…", "name": "Mickey & Friends", "city": "Starry Guest Street", "product_type": "licensed",
  "post_start": "2026-11-17", "post_end": "2026-11-18", "image_date": "2026-11-14",
  "channels": ["Facebook ReallyCuteDollsShop", "TikTok reallycuteland"],
  "shops": ["Shopee reallycute.th", "Lazada", "TikTok Shop", "Line My Shop"],
  "captions": { "fb_ig_tt": "…", "x": "…", "threads": "…", "yt_community": "…", "yt_poll": ["ตัวเลือก 1", "ตัวเลือก 2"], "lemon8": "…" },
  "listing": { "product_name": "…", "options": "…", "price": "…", "description": "…", "keywords": "…",
               "shops": ["Shopee reallycute.th", "Lazada"], "links": { "Lazada": "https://…" } },
  "posts": [
    { "id": "…", "label": "ทีเซอร์", "post_date": "2026-11-17", "post_time": "19:00", "image_set": "12",
      "folder_path": "…", "image_order": "3,1,2", "comment_link": true, "comment_text": "…",
      "media_kind": "photo", "media_url": "", "captions": { "x": "แคปชั่น X เฉพาะโพสต์นี้" }, "post_id": null }
  ],
  "tasks": [ { "sort": 1, "title": "…", "assignee": "ริตา", "due_date": "2026-11-14", "status": "done", "template_key": "lic_1" } ]
}
```

- `captions` ของแคมเปญ = แคปชั่นหลัก · `posts[].captions` = ช่องที่โพสต์นั้นกรอกทับ (ช่องที่ไม่มี → ใช้ของแคมเปญ)
- `posts` เรียงตามวันโพสต์ + เวลา · ช่องว่างจะไม่มีคีย์ใน `captions` / `listing`

## 2. รายชื่อแคมเปญ — `find_campaigns(q)`

```bash
curl -s -X POST "$SB/rpc/find_campaigns" -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" -d '{"q":"day"}'      # {} = ทั้งหมด
```

## 3. พนักงานลงสินค้ากรอกลิงก์ร้านกลับ — `set_listing_link(campaign_name, shop, url, actor)`

- `campaign_name` ต้องตรงทั้งชื่อ (ไม่สนตัวพิมพ์) และต้องเจอแคมเปญเดียว
- `shop` ต้องเป็นหนึ่งใน: `Shopee wararit.th`, `Shopee ployririta`, `Shopee reallycute.th`, `Lazada`, `TikTok Shop`, `ThaiMart`, `Line My Shop`
- บันทึกลงแท็บ «กิจกรรม» อัตโนมัติ (actor = ชื่อบอทที่ส่งมา) · คืนแคมเปญทั้งก้อนเหมือน `get_campaign`
- `url` เป็นค่าว่าง = ลบลิงก์ของร้านนั้น (เก็บเป็นค่าว่าง)

```bash
curl -s -X POST "$SB/rpc/set_listing_link" -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"campaign_name":"Mickey & Friends","shop":"Lazada","url":"https://www.lazada.co.th/products/…","actor":"พนักงานลงสินค้า REALLYCUTE 2"}'
```

ผิดพลาด → HTTP 400 พร้อม `message` เช่น `unknown shop`, `not found`, `matches 2 campaigns`

## ตาราง (อ่านตรงได้ถ้าต้องการ)

- `campaigns` — เพิ่มคอลัมน์ `captions jsonb`, `listing jsonb`
- `campaign_posts` — หลายโพสต์ต่อแคมเปญ (`campaign_id`, `label`, `post_date`, `post_time`, `image_set`, `folder_path`, `image_order`, `comment_link`, `comment_text`, `media_kind`, `media_url`, `captions`, `post_id`, `deleted_at`)
- `campaign_tasks` — งานย่อย
- ทุกตาราง: anon อ่าน/เพิ่ม/แก้ได้ ลบจริงไม่ได้ (ลบ = ตั้ง `deleted_at`) · มี realtime
- ห้ามแก้ `app_data` (สินค้า/โพสต์/ยอดขาย) ผ่านช่องทางนี้ — ข้อมูลลงร้านในแคมเปญเป็นข้อมูลวางแผนเท่านั้น
