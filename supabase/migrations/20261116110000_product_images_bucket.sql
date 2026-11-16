-- กระจกรูปสินค้า (ริตาอนุมัติทำลิงก์ทดลอง 16 พ.ย. 2026)
-- เพิ่มอย่างเดียว: bucket ใหม่ product-images (อ่านได้สาธารณะ) + สิทธิ์อัปโหลดแบบจำกัด
-- ไม่แตะตาราง/ข้อมูลเดิม
-- ถอนคืน: drop policy ... (3 อัน) ; delete from storage.objects where bucket_id='product-images'; delete from storage.buckets where id='product-images';
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 1048576, array['image/webp','application/json'])
on conflict (id) do nothing;

-- อัปโหลดได้เฉพาะชื่อไฟล์รูปแบบ p/<hex>.webp และไฟล์รายการ _index.json เท่านั้น (ลบไม่ได้)
create policy "product_images_insert" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'product-images' and (name ~ '^p/[0-9a-f]{1,14}\.webp$' or name = '_index.json'));
-- แก้ทับได้เฉพาะ _index.json (สคริปต์อัปเดตรายการรูปที่มีแล้ว)
create policy "product_images_update_index" on storage.objects for update to anon, authenticated
  using (bucket_id = 'product-images' and name = '_index.json')
  with check (bucket_id = 'product-images' and name = '_index.json');
-- ต้องมี select เพื่อให้ upsert ทำงาน (bucket เป็น public อยู่แล้ว อ่านได้ทุกคน)
create policy "product_images_select" on storage.objects for select to anon, authenticated
  using (bucket_id = 'product-images');
