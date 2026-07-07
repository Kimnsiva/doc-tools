# TESTING.md — คู่มือทดสอบ Doc-Tools

เอกสารนี้จะเพิ่มเนื้อหาทีละ Phase ทุกคำสั่งสามารถ copy-paste รันบนเซิร์ฟเวอร์ Linux ที่ติดตั้ง Docker ได้เลย

---

## Phase 1 — PDF Core (Merge / Split / Remove pages / Organize / Rotate / Compress / Repair / Crop)

### 1. ข้อกำหนดเบื้องต้น (Prerequisites)

- เซิร์ฟเวอร์ Linux ที่ติดตั้ง Docker และ Docker Compose (v2) แล้ว
- เปิดพอร์ต 8080 (หรือพอร์ตที่กำหนดใน `.env`) ให้เข้าถึงได้ใน LAN บริษัท
- มี `curl`, `jq` (แกะ JSON เอา `file_id`), `qpdf` และ `poppler-utils` (สำหรับคำสั่ง `pdfinfo`) อยู่บนเครื่องที่ใช้ทดสอบ (ไม่ใช่ในคอนเทนเนอร์) — ถ้าไม่มีให้ติดตั้งด้วย `sudo apt-get install -y jq qpdf poppler-utils`

### 2. เริ่มระบบ

```bash
git clone <URL_REPO_ของคุณ> doc-tools
cd doc-tools
cp .env.example .env
docker compose up --build -d
```

ผลลัพธ์ที่คาดหวังใน log (`docker compose logs -f doc-tools`):

```
doc-tools-1  | INFO:     Started server process [1]
doc-tools-1  | INFO:     Waiting for application startup.
doc-tools-1  | INFO:     Application startup complete.
doc-tools-1  | INFO:     Uvicorn running on http://0.0.0.0:8080
```

ตรวจสุขภาพระบบ:

```bash
curl http://localhost:8080/health
# คาดหวัง: {"status":"ok"}
```

### 3. สร้างไฟล์ทดสอบ

ไฟล์ทดสอบทั้งหมดสร้างจากสคริปต์ในโปรเจกต์ (ไม่ใช้เอกสารจริงของบริษัท) รันสคริปต์นี้ผ่านคอนเทนเนอร์ที่กำลังทำงานอยู่ (มี pikepdf ติดตั้งพร้อมแล้ว):

```bash
docker compose exec doc-tools python3 /app/scripts/generate_test_files.py
```

ผลลัพธ์ที่คาดหวัง:

```
Test fixtures written to /tmp/doc-tools-fixtures
 - corrupted.pdf
 - sample_10page.pdf
 - sample_1page.pdf
 - sample_2page.pdf
 - sample_5page.pdf
```

คัดลอกไฟล์ออกมาที่เครื่องทดสอบ (host) เพื่อใช้กับคำสั่ง `curl` ด้านล่าง:

```bash
mkdir -p ~/doc-tools-fixtures
docker compose cp doc-tools:/tmp/doc-tools-fixtures/. ~/doc-tools-fixtures/
cd ~/doc-tools-fixtures
```

**หมายเหตุเรื่องไฟล์ทดสอบ:** `sample_5page.pdf` มี 5 หน้า แต่ละหน้าตั้งใจให้ "ขนาดหน้ากระดาษ" ต่างกัน (สูง 700, 710, 720, 730, 740 pt ตามลำดับหน้า 1–5) เพราะหน้าเปล่าไม่มีข้อความให้ตรวจสอบว่าลำดับถูกต้องหรือไม่ — เราจึงใช้ `pdfinfo -f <หน้า> -l <หน้า>` ดู "Page size" แทนการอ่านเนื้อหาข้อความ

### 4. ทดสอบทีละ Endpoint

ตั้งค่าตัวแปรพอร์ตให้ตรงกับ `.env` ของคุณก่อน (ค่าเริ่มต้น 8080):

```bash
API=http://localhost:8080
```

**รูปแบบ API จริงของระบบ (upload-once workspace):** ไม่มี endpoint แยกต่อเครื่องมือ (เช่น `/api/merge`) ทุกเครื่องมือเรียกผ่าน endpoint เดียวกันคือ `POST /api/ops/{tool}` โดยส่ง `file_id` ที่ได้จากการอัปโหลดครั้งแรก:

1. อัปโหลดไฟล์ → `POST /api/files` (multipart, field ชื่อ `files`) → ได้ `file_id` กลับมา
2. เรียกเครื่องมือ → `POST /api/ops/{tool}` (JSON, `{"file_id": "...", ...options}`) → ผลลัพธ์เป็น version ใหม่ของไฟล์เดิม (`output: version`), ไฟล์ใหม่ (`output: new_file`, เช่น merge), หรือ token ดาวน์โหลดครั้งเดียว (`output: download`, เช่น split แบบ every_n)
3. ดาวน์โหลด → `GET /api/files/{file_id}/download` (สำหรับ version/new_file) หรือ `GET /api/downloads/{token}` (สำหรับ download token)
4. เครื่องมือหนัก (async, เช่น OCR, office-to-pdf) endpoint เดียวกันแต่ตอบกลับ `{"job_id": "..."}` ทันที ต้อง poll `GET /api/ops/{job_id}` จนกว่า `status` จะเป็น `done`/`error`

ตัวอย่างการอัปโหลดแล้วดึง `file_id` ด้วย `jq`:
```bash
FILE_ID=$(curl -s -F "files=@sample_5page.pdf" $API/api/files | jq -r '.[0].file_id')
echo $FILE_ID
```

#### 4.1 Merge — `/api/ops/merge` (multi-input)

```bash
ID_A=$(curl -s -F "files=@sample_5page.pdf" $API/api/files | jq -r '.[0].file_id')
ID_B=$(curl -s -F "files=@sample_2page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_ids\":[\"$ID_A\",\"$ID_B\"]}" $API/api/ops/merge | tee merge_result.json
MERGED_ID=$(jq -r '.file_id' merge_result.json)
curl -s $API/api/files/$MERGED_ID/download -o merged.pdf
qpdf --show-npages merged.pdf
```
**คาดหวัง:** `7` (5 หน้า + 2 หน้า) — merge คืน `file_id` ใหม่ (ไม่ใช่ version ของไฟล์เดิม)

#### 4.2 Split — `/api/ops/split` (ดึงหน้าที่ต้องการ)

```bash
FILE_ID=$(curl -s -F "files=@sample_5page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"pages\":\"1-3,5\"}" $API/api/ops/split
curl -s $API/api/files/$FILE_ID/download -o extracted.pdf
qpdf --show-npages extracted.pdf
```
**คาดหวัง:** `4` (หน้า 1,2,3,5 — ข้ามหน้า 4) — ผลลัพธ์กลายเป็น version ใหม่ (v2) ของ `file_id` เดิม ดาวน์โหลด default จะได้ version ล่าสุดเสมอ

#### 4.3 Split — `/api/ops/split` (แบ่งทุก N หน้า)

โหมดนี้ output เป็น zip (`output_override: download`) ไม่ใช่ version:
```bash
FILE_ID=$(curl -s -F "files=@sample_10page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"mode\":\"every_n\",\"every_n\":3}" $API/api/ops/split | tee split_result.json
TOKEN=$(jq -r '.download_token' split_result.json)
curl -s $API/api/downloads/$TOKEN -o split.zip
unzip -l split.zip
```
**คาดหวัง:** ไฟล์ 4 ไฟล์ (`part_1.pdf`..`part_4.pdf`) — 3 ไฟล์แรกมี 3 หน้า ไฟล์สุดท้ายมี 1 หน้า ตรวจสอบด้วย:
```bash
unzip -o split.zip -d split_out
for f in split_out/*.pdf; do echo -n "$f: "; qpdf --show-npages "$f"; done
```

#### 4.4 Remove pages — `/api/ops/remove_pages`

```bash
FILE_ID=$(curl -s -F "files=@sample_5page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"pages\":\"2,4\"}" $API/api/ops/remove_pages
curl -s $API/api/files/$FILE_ID/download -o removed.pdf
qpdf --show-npages removed.pdf
```
**คาดหวัง:** `3` (เหลือหน้า 1,3,5)

#### 4.5 Organize — `/api/ops/organize`

```bash
FILE_ID=$(curl -s -F "files=@sample_5page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"order\":\"5,1,4,2,3\"}" $API/api/ops/organize
curl -s $API/api/files/$FILE_ID/download -o organized.pdf
pdfinfo -f 1 -l 1 organized.pdf | grep "Page size"
pdfinfo -f 3 -l 3 organized.pdf | grep "Page size"
```
**คาดหวัง:** หน้า 1 มีขนาด `595 x 740` (เดิมคือหน้า 5) และหน้า 3 มีขนาด `595 x 730` (เดิมคือหน้า 4)

#### 4.6 Rotate — `/api/ops/rotate`

```bash
FILE_ID=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"angle\":\"90\"}" $API/api/ops/rotate
curl -s $API/api/files/$FILE_ID/download -o rotated.pdf
pdfinfo rotated.pdf | grep "Page rot"
```
**คาดหวัง:** `Page rot:        90`

#### 4.7 Compress — `/api/ops/compress`

```bash
FILE_ID=$(curl -s -F "files=@sample_5page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"level\":\"medium\"}" $API/api/ops/compress
curl -s $API/api/files/$FILE_ID/download -o compressed.pdf
qpdf --show-npages compressed.pdf
ls -l sample_5page.pdf compressed.pdf
```
**คาดหวัง:** จำนวนหน้ายังคง `5` และไฟล์เปิดได้ปกติ **หมายเหตุ:** ไฟล์ทดสอบเป็นหน้ากระดาษเปล่า (ไม่มีรูปภาพ) จึงไม่สามารถวัดอัตราการบีบอัด ≥30% ตามเกณฑ์ในแผนได้ — การทดสอบอัตราบีบอัดจริงกับไฟล์ที่มีรูปภาพจะทำใน Phase 2 เมื่อมีเครื่องมือแปลงรูปภาพ→PDF แล้ว (ดู KNOWN_ISSUES.md)

#### 4.8 Repair — `/api/ops/repair`

ก่อนซ่อม ให้ยืนยันว่าไฟล์เสียจริง:
```bash
qpdf --show-npages corrupted.pdf
```
**คาดหวัง:** คำสั่งนี้จะแจ้ง error หรือ warning ว่าไฟล์เสีย (เพราะเราตัดท้ายไฟล์ทิ้งไป 200 ไบต์)

ทดสอบเครื่องมือซ่อมไฟล์:
```bash
FILE_ID=$(curl -s -F "files=@corrupted.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" -d "{\"file_id\":\"$FILE_ID\"}" $API/api/ops/repair
curl -s $API/api/files/$FILE_ID/download -o repaired.pdf
qpdf --show-npages repaired.pdf
```
**คาดหวัง:** คำสั่งสำเร็จและแสดงจำนวนหน้าใกล้เคียงหรือเท่ากับ `5` (qpdf กู้โครงสร้างไฟล์คืนจากการสแกนอ็อบเจกต์ในไฟล์ — จำนวนหน้าที่กู้คืนได้อาจต่างกันเล็กน้อยหากไฟล์ต้นทางเสียหายรุนแรงกว่านี้)

#### 4.9 Crop — `/api/ops/crop`

```bash
FILE_ID=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"top\":20,\"right\":10,\"bottom\":20,\"left\":10}" $API/api/ops/crop
curl -s $API/api/files/$FILE_ID/download -o cropped.pdf
pdfinfo cropped.pdf | grep "Page size"
```
**คาดหวัง:** ขนาดหน้าประมาณ `538.31 x 728.61 pts` (ต้นฉบับ 595x842 หักขอบซ้าย/ขวา 10มม. และบน/ล่าง 20มม. แต่ละมม. ≈2.83 pt คลาดเคลื่อนได้ ±0.5 pt)

#### 4.10 Undo/Revert — `/api/files/{id}/revert`

ทุก op ที่แก้ไฟล์เดิม (output: version) จะสร้าง version ใหม่โดยไม่ทิ้ง version เก่า ทดสอบย้อนกลับ:
```bash
FILE_ID=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" -d "{\"file_id\":\"$FILE_ID\",\"angle\":\"90\"}" $API/api/ops/rotate
curl -s $API/api/files/$FILE_ID | jq '.version, .version_history'
# คาดหวัง: version เป็น 2, version_history มี v1 และ v2

curl -s -X POST -H "Content-Type: application/json" -d "{\"to_version\":1}" $API/api/files/$FILE_ID/revert | jq '.version'
# คาดหวัง: 2 -> 1 (กลับไปใช้ v1 ที่ยังไม่ได้หมุน)
curl -s $API/api/files/$FILE_ID/download -o reverted.pdf
pdfinfo reverted.pdf | grep "Page rot"
```
**คาดหวัง:** `Page rot:        0` (ไฟล์ที่ดาวน์โหลดหลัง revert ไม่มีการหมุน เพราะกลับไปเป็น v1)

### 5. ทดสอบผ่านเบราว์เซอร์ (Browser Checklist)

เปิด `http://<IP เซิร์ฟเวอร์>:8080` ด้วย Chrome หรือ Edge แล้วตรวจสอบ (UI จริงเป็น **workspace เดียว** ไม่ใช่หน้าแยกต่อเครื่องมือ — sidebar ซ้าย/การ์ดไฟล์ตรงกลาง/แผงตัวเลือกขวา):

- [ ] หน้าแรก (ยังไม่มีไฟล์) แสดง drop zone ตรงกลางพร้อมปุ่มเลือกไฟล์
- [ ] ลากไฟล์ PDF วางบนหน้าเว็บ (หรือคลิกปุ่มเลือกไฟล์) → เข้าสู่ workspace 3 โซน: sidebar เครื่องมือซ้าย, การ์ดไฟล์ตรงกลางพร้อม page-strip, แผงตัวเลือกขวา
- [ ] sidebar ซ้ายแสดงหมวดหมู่ **Organize** และ **Optimize** พร้อมเครื่องมือครบทั้ง 8 รายการ เครื่องมือที่ใช้กับไฟล์ที่เลือกไม่ได้จะจาง (disabled)
- [ ] ติ๊ก checkbox ไฟล์ 2 ไฟล์ (PDF ทั้งคู่) → เครื่องมือ **Merge PDF** ใน sidebar ใช้งานได้ (ไม่จางแล้ว)
- [ ] คลิก **Merge PDF** → แผงขวาแสดงตัวเลือก + ปุ่ม Apply สีแดง → คลิก Apply → ปุ่มแสดงสถานะ "Processing..." พร้อมเวลาที่ผ่านไป
- [ ] เมื่อเสร็จ ไฟล์ผลลัพธ์ใหม่ปรากฏเป็นการ์ดในตรงกลาง พร้อมปุ่ม "Download" ที่ใช้งานได้จริง
- [ ] เลือกไฟล์ PDF 1 ไฟล์ → คลิก **Remove Pages** → คลิกเลือกหน้าในแถบ thumbnail ด้านล่างการ์ด → เลขหน้าที่เลือกไปปรากฏในช่อง "Pages to remove" อัตโนมัติ
- [ ] หลังรันเครื่องมือใดๆ แล้ว version bar ของการ์ดไฟล์นั้นแสดง `v1 v2 ...` และคลิก version เก่าเพื่อ revert (Undo) ได้
- [ ] คลิกปุ่ม "EN / ไทย" มุมขวาบน → ข้อความในหน้า (sidebar, ปุ่ม, footer) สลับภาษาได้
- [ ] Footer แสดงข้อความ "🔒 Files stay on the company server and are deleted after 30 minutes."
- [ ] ย่อหน้าต่างเบราว์เซอร์ให้แคบลง (< 1000px) → sidebar ยุบเหลือแค่ไอคอน

### 6. ทดสอบกรณีผิดพลาด (Failure Tests)

**6.1 อัปโหลดไฟล์ผิดชนิด/เนื้อหาไม่ตรงนามสกุล (คาดหวัง 400):**
```bash
echo "not a pdf" > fake.pdf
curl -s -o /dev/null -w "%{http_code}\n" -F "files=@fake.pdf" $API/api/files
```
**คาดหวัง:** `400` (magic bytes ไม่ตรงกับ `%PDF`)

**6.2 อัปโหลดไฟล์เกินขนาดที่กำหนด (คาดหวัง 413):**

แก้ไข `.env` ชั่วคราวเพื่อทดสอบ:
```bash
sed -i 's/MAX_FILE_SIZE_MB=.*/MAX_FILE_SIZE_MB=1/' .env
docker compose up -d
printf '%%PDF-1.4\n' > big.pdf
dd if=/dev/zero bs=1M count=2 >> big.pdf 2>/dev/null
curl -s -o /dev/null -w "%{http_code}\n" -F "files=@big.pdf" $API/api/files
```
**คาดหวัง:** `413` — จากนั้นคืนค่า `.env` เดิมและรัน `docker compose up -d` อีกครั้ง

**6.3 หน้าที่ระบุไม่มีอยู่จริง (คาดหวัง 400):**
```bash
FILE_ID=$(curl -s -F "files=@sample_5page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"pages\":\"99\"}" $API/api/ops/split
```
**คาดหวัง:** `400`

**6.4 file_id ที่ไม่มีอยู่จริง/หมดอายุแล้ว (คาดหวัง 404):**
```bash
curl -s -o /dev/null -w "%{http_code}\n" $API/api/files/00000000-0000-0000-0000-000000000000
```
**คาดหวัง:** `404`

**6.5 ชื่อเครื่องมือที่ไม่มีอยู่จริง (คาดหวัง 404):**
```bash
FILE_ID=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\"}" $API/api/ops/not_a_real_tool
```
**คาดหวัง:** `404`

### 7. ทดสอบการลบไฟล์ชั่วคราว (TTL Cleanup)

ไฟล์ที่อัปโหลด/version ที่สร้างจะยังอยู่ใน workspace (ให้ undo/download ย้อนหลังได้) จนกว่าจะไม่ถูกแตะต้องเกิน `FILE_TTL_MINUTES` — ตัวกวาด (sweeper) จะทำงานทุก 60 วินาที ลดค่านี้ชั่วคราวเพื่อทดสอบได้ไวขึ้น:

```bash
sed -i 's/FILE_TTL_MINUTES=.*/FILE_TTL_MINUTES=1/' .env
docker compose up -d
FILE_ID=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
docker compose exec doc-tools sh -c "ls /tmp/doc-tools/$FILE_ID"
```
**คาดหวัง:** เห็นไฟล์ `v1.pdf` อยู่จริง

รอประมาณ 90 วินาที (เกิน 1 นาทีที่ตั้งไว้ + รอบกวาดถัดไป) แล้วตรวจอีกครั้ง:
```bash
sleep 90
docker compose exec doc-tools sh -c "ls /tmp/doc-tools/$FILE_ID 2>&1; ls /tmp/doc-tools"
curl -s -o /dev/null -w "%{http_code}\n" $API/api/files/$FILE_ID
```
**คาดหวัง:** โฟลเดอร์ `$FILE_ID` หายไปแล้ว และเรียก `GET /api/files/{id}` ได้ `404` — จากนั้นคืนค่า `FILE_TTL_MINUTES` ใน `.env` กลับเป็น `30` แล้ว `docker compose up -d` อีกครั้ง

### 8. ขั้นตอนอัปเดตระบบ

```bash
git pull
docker compose up -d --build
```

### 9. ตารางแก้ปัญหา (Troubleshooting)

| อาการ | สาเหตุที่เป็นไปได้ | วิธีแก้ |
|---|---|---|
| `docker compose up` ค้างที่ build นาน | ครั้งแรกต้องโหลด base image + apt packages | รอให้เสร็จ (ปกติ 2-5 นาที) |
| พอร์ต 8080 ถูกใช้งานอยู่แล้ว | มีโปรแกรมอื่นใช้พอร์ตนี้ | เปลี่ยน `PORT` ใน `.env` แล้ว `docker compose up -d --build` |
| `curl: (7) Failed to connect` | คอนเทนเนอร์ยังไม่พร้อม หรือ firewall บล็อกพอร์ต | ตรวจ `docker compose ps` และ `docker compose logs doc-tools` |
| ได้ `{"error":"Processing failed"}` ตอนเรียก compress/repair | ghostscript/qpdf error กับไฟล์เฉพาะนั้น | ลองไฟล์อื่น, ดู log ด้วย `docker compose logs doc-tools`, บันทึกลง KNOWN_ISSUES.md ถ้าเกิดซ้ำ |
| ได้ 504 Processing timed out | ไฟล์ใหญ่/ซับซ้อนเกินไป หรือเครื่องช้า | ลองไฟล์เล็กลง หรือเพิ่ม timeout ในโค้ด router ที่เกี่ยวข้อง |
| หน้าเว็บโหลดไม่ขึ้น (404) | คอนเทนเนอร์ยังไม่ start เสร็จ | รอ healthcheck ผ่านก่อน (`docker compose ps` แสดง healthy) |

---

## Phase 2 — Convert (Word/Excel/PPT→PDF, PDF→JPG/PNG, Images→PDF, HTML→PDF)

### 1. อัปเดตระบบก่อนทดสอบ

Phase 2 เพิ่มแพ็กเกจใหม่ (LibreOffice, WeasyPrint และไลบรารีที่เกี่ยวข้อง) เข้าไปใน image ต้อง build ใหม่:

```bash
git pull
docker compose up -d --build
curl http://localhost:8080/health
# คาดหวัง: {"status":"ok"}
```

**หมายเหตุ:** ครั้งแรกที่ build ใหม่จะใช้เวลานานกว่าปกติ (LibreOffice มีขนาดใหญ่ ~500MB) รอจนกว่าจะขึ้น `Build` เสร็จ

### 2. สร้างไฟล์ทดสอบ (เพิ่มเติมจาก Phase 1)

สคริปต์เดิมถูกขยายให้สร้างไฟล์ทดสอบของ Phase 2 ด้วย (เอกสาร Office สังเคราะห์, รูปภาพ, HTML — ไม่ใช่เอกสารจริงของบริษัท) รันสคริปต์เดิมซ้ำอีกครั้ง:

```bash
docker compose exec doc-tools python3 /app/scripts/generate_test_files.py
```

ผลลัพธ์ที่คาดหวังเพิ่มจาก Phase 1:
```
 - sample.docx
 - sample.xlsx
 - sample.pptx
 - sample_red.png
 - sample_green.jpg
 - sample.html
 - sample_external.html
```

คัดลอกออกมาที่เครื่องทดสอบเหมือน Phase 1:
```bash
docker compose cp doc-tools:/tmp/doc-tools-fixtures/. ~/doc-tools-fixtures/
cd ~/doc-tools-fixtures
API=http://localhost:8080
```

### 3. ทดสอบทีละ Endpoint

เครื่องมือ Phase 2 เรียกผ่าน `/api/ops/{tool}` แบบเดียวกับ Phase 1 (ดูคำอธิบาย flow ที่หัวข้อ 4 ของ Phase 1) office-to-pdf เป็นเครื่องมือ **async** (ตอบกลับ `job_id` ต้อง poll)

#### 3.1 Word/Excel/PPT → PDF — `/api/ops/office_to_pdf` (async)

```bash
for f in sample.docx sample.xlsx sample.pptx; do
  FILE_ID=$(curl -s -F "files=@$f" $API/api/files | jq -r '.[0].file_id')
  JOB_ID=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"file_id\":\"$FILE_ID\"}" $API/api/ops/office_to_pdf | jq -r '.job_id')
  while true; do
    STATUS=$(curl -s $API/api/ops/$JOB_ID | jq -r '.status')
    [ "$STATUS" = "done" ] || [ "$STATUS" = "error" ] && break
    sleep 1
  done
  echo "$f -> job status: $STATUS"
  curl -s $API/api/files/$FILE_ID/download -o "converted_${f%.*}.pdf"
done
qpdf --show-npages converted_sample.pdf
```
**คาดหวัง:** ทุกไฟล์ได้ `status: done` และเปิด PDF ที่ได้ดูเนื้อหาตรงกับต้นฉบับ (หัวข้อ "Doc-Tools test document/sheet/slide") — สังเกตว่า `file_id` เดิมเปลี่ยน `kind` จาก office เป็น pdf หลังแปลงสำเร็จ (`curl -s $API/api/files/$FILE_ID | jq '.kind'` ต้องได้ `"pdf"`)

#### 3.2 PDF → JPG/PNG — `/api/ops/pdf_to_images` (sync, output เป็น zip)

```bash
FILE_ID=$(curl -s -F "files=@sample_5page.pdf" $API/api/files | jq -r '.[0].file_id')
TOKEN=$(curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"fmt\":\"jpg\",\"dpi\":150}" $API/api/ops/pdf_to_images | jq -r '.download_token')
curl -s $API/api/downloads/$TOKEN -o pages.zip
unzip -l pages.zip
```
**คาดหวัง:** ไฟล์ zip มี `page_1.jpg` ถึง `page_5.jpg` (5 ไฟล์ ตามจำนวนหน้า) — `download_token` ใช้ได้ครั้งเดียวเท่านั้น

#### 3.3 Images → PDF — `/api/ops/images_to_pdf` (multi-input, output เป็น file_id ใหม่)

```bash
ID_RED=$(curl -s -F "files=@sample_red.png" $API/api/files | jq -r '.[0].file_id')
ID_GREEN=$(curl -s -F "files=@sample_green.jpg" $API/api/files | jq -r '.[0].file_id')
NEW_ID=$(curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_ids\":[\"$ID_RED\",\"$ID_GREEN\"],\"fit\":\"a4\"}" $API/api/ops/images_to_pdf | jq -r '.file_id')
curl -s $API/api/files/$NEW_ID/download -o images_a4.pdf
qpdf --show-npages images_a4.pdf
pdfinfo -f 1 -l 1 images_a4.pdf | grep "Page size"
```
**คาดหวัง:** 2 หน้า ขนาดหน้าประมาณ `595.28 x 841.89 pts` (A4) ไม่ว่าขนาดรูปต้นฉบับจะเป็นเท่าใด

ทดสอบโหมด "ขนาดต้นฉบับ" ด้วย:
```bash
ID_RED2=$(curl -s -F "files=@sample_red.png" $API/api/files | jq -r '.[0].file_id')
ID_GREEN2=$(curl -s -F "files=@sample_green.jpg" $API/api/files | jq -r '.[0].file_id')
NEW_ID2=$(curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_ids\":[\"$ID_RED2\",\"$ID_GREEN2\"],\"fit\":\"original\"}" $API/api/ops/images_to_pdf | jq -r '.file_id')
curl -s $API/api/files/$NEW_ID2/download -o images_orig.pdf
pdfinfo -f 1 -l 1 images_orig.pdf | grep "Page size"
```
**คาดหวัง:** ขนาดหน้าแรก ≈ `225 x 300 pts` (รูป `sample_red.png` คือ 300×400 พิกเซล ที่ 96 DPI ตามค่าเริ่มต้นของ img2pdf เมื่อไฟล์ภาพไม่มีข้อมูล DPI ฝังมา)

#### 3.4 HTML → PDF — `/api/ops/html_to_pdf` (sync, output เป็น version)

```bash
FILE_ID=$(curl -s -F "files=@sample.html" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" -d "{\"file_id\":\"$FILE_ID\"}" $API/api/ops/html_to_pdf
curl -s $API/api/files/$FILE_ID/download -o converted_html.pdf
qpdf --show-npages converted_html.pdf
```
**คาดหวัง:** สำเร็จ (`kind` ของ `file_id` นี้เปลี่ยนจาก html เป็น pdf) ไฟล์ PDF 1 หน้า มีข้อความ "Doc-Tools HTML test page"

ทดสอบว่าไฟล์ที่อ้างอิงรูปภาพจากอินเทอร์เน็ตยังคงแปลงสำเร็จ (เพราะระบบไม่ดึงข้อมูลจากภายนอกตามกฎ LAN security) โดยรูปนั้นจะถูกข้ามไปเฉย ๆ ไม่ทำให้การแปลงล้มเหลว:
```bash
FILE_ID2=$(curl -s -F "files=@sample_external.html" $API/api/files | jq -r '.[0].file_id')
curl -s -o /dev/null -w "HTTP %{http_code}\n" -X POST -H "Content-Type: application/json" -d "{\"file_id\":\"$FILE_ID2\"}" $API/api/ops/html_to_pdf
```
**คาดหวัง:** `HTTP 200` เช่นกัน (endpoint นี้ไม่มีการเรียก network ออกไปนอกเครื่องเลย — ดูโค้ดที่ `backend/ops/html_to_pdf.py` ที่ปฏิเสธการดึง URL ภายนอกทุกกรณี)

### 4. ทดสอบผ่านเบราว์เซอร์ (เพิ่มเติมจาก Phase 1)

- [ ] sidebar ซ้ายมีหมวดหมู่ใหม่ **Convert** (สีส้ม) พร้อมเครื่องมือ 4 รายการ
- [ ] อัปโหลดไฟล์ `.docx` → การ์ดแสดงไอคอนไฟล์ office ทั่วไป (ไม่มี page-strip เพราะยังไม่ใช่ PDF) → เลือกไฟล์ → คลิก **Word/Excel/PPT to PDF** → รอสถานะ processing (async) → การ์ดกลายเป็น PDF พร้อม page-strip
- [ ] เลือกไฟล์ PDF → คลิก **PDF to JPG/PNG** → เลือกความละเอียดและฟอร์แมต → Apply → ได้ลิงก์ดาวน์โหลดไฟล์ `.zip` แบบใช้ครั้งเดียว
- [ ] อัปโหลดรูป 2 ไฟล์ → ติ๊ก checkbox ทั้งคู่ → คลิก **Images to PDF** → ได้การ์ดไฟล์ PDF ใหม่
- [ ] อัปโหลดไฟล์ `.html` → คลิก **HTML to PDF** → แปลงสำเร็จเป็น PDF ในการ์ดเดิม

### 5. ทดสอบกรณีผิดพลาด (เพิ่มเติมจาก Phase 1)

```bash
# นามสกุลไฟล์ไม่รองรับ (คาดหวัง 400 ตอนอัปโหลด ก่อนถึงขั้นเรียกเครื่องมือด้วยซ้ำ)
echo "hello" > fake.txt
curl -s -o /dev/null -w "%{http_code}\n" -F "files=@fake.txt" $API/api/files

# ไฟล์ไม่ใช่รูปภาพจริงแต่ตั้งนามสกุล .png (คาดหวัง 400 ตอนอัปโหลด - magic bytes ไม่ตรง)
echo "not an image" > fake.png
curl -s -o /dev/null -w "%{http_code}\n" -F "files=@fake.png" $API/api/files

# dpi ที่ไม่รองรับสำหรับ pdf_to_images (คาดหวัง 400 ตอนเรียกเครื่องมือ)
FILE_ID=$(curl -s -F "files=@sample_5page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"dpi\":72}" $API/api/ops/pdf_to_images
```
**คาดหวัง:** ทั้ง 3 คำสั่งได้ `400`

### 6. ตารางแก้ปัญหาเพิ่มเติม (Phase 2)

| อาการ | สาเหตุที่เป็นไปได้ | วิธีแก้ |
|---|---|---|
| `office-to-pdf` คืนค่า 500 "LibreOffice failed to produce a PDF" | ไฟล์ Office เสียหาย หรือ LibreOffice ใช้เวลานานเกิน timeout 120 วิ | ลองไฟล์เล็กลง/ไฟล์อื่น ตรวจ log ด้วย `docker compose logs doc-tools` |
| `html-to-pdf` คืนค่า 500 | ไฟล์ HTML มีโครงสร้างที่ WeasyPrint แปลงไม่ได้ | ตรวจว่าไฟล์เป็น HTML ที่ถูกต้อง (ไม่ใช่ .docx ที่เปลี่ยนนามสกุลเป็น .html) |
| build ช้ามากตอนติดตั้ง LibreOffice | ปกติของแพ็กเกจนี้ (ขนาดใหญ่) | รอให้เสร็จครั้งเดียว ครั้งถัดไป Docker cache ไว้แล้วจะเร็วขึ้น |

---

## Phase 3 — OCR & Document Conversion (OCR / Scan-to-PDF / PDF→Word / PDF→Excel)

> **สำคัญ:** Phase นี้ต้องทดสอบผ่าน Docker เท่านั้น (ต้องมี tesseract + language packs ที่ติดตั้งใน image) ทดสอบตรงบน Windows/host ไม่ได้

### 1. อัปเดตระบบก่อนทดสอบ

Phase 3 เพิ่มแพ็กเกจใหม่จำนวนมาก (tesseract + ภาษาไทย/ญี่ปุ่น, unpaper, imagemagick, ฟอนต์ Thai/CJK, ocrmypdf, pdf2docx, camelot) ต้อง build ใหม่:

```bash
git pull
docker compose up -d --build
curl http://localhost:8080/health
# คาดหวัง: {"status":"ok"}
```

**หมายเหตุ:** การ build ครั้งแรกของ Phase นี้จะใช้เวลานานกว่าปกติมาก (ติดตั้งฟอนต์ + tesseract + ไลบรารี OCR/Python เพิ่มหลายตัว) รอจนกว่าจะขึ้น `Build` เสร็จ

ตรวจสอบว่า tesseract มี language pack ครบ:
```bash
docker compose exec doc-tools tesseract --list-langs
```
**คาดหวัง:** เห็น `tha`, `jpn`, `jpn_vert`, `eng` ในรายการ

### 2. สร้างไฟล์ทดสอบ (เพิ่มเติมจาก Phase 1/2)

สคริปต์เดิมถูกขยายให้สร้างไฟล์ทดสอบ OCR ด้วย (ข้อความสังเคราะห์ที่ rasterize เป็นภาพแล้วห่อกลับเป็น PDF — ไม่ใช่เอกสารจริงของบริษัท) รันสคริปต์เดิมซ้ำอีกครั้ง **ในคอนเทนเนอร์** (ฟอนต์ Thai/CJK อยู่ในคอนเทนเนอร์เท่านั้น):

```bash
docker compose exec doc-tools python3 /app/scripts/generate_test_files.py
```

ผลลัพธ์ที่คาดหวังเพิ่มจาก Phase 1/2:
```
 - ocr_thai.pdf              # หน้าเดียว รูปข้อความไทย "ทดสอบภาษาไทย" ที่ 200dpi (ไม่มี text layer)
 - ocr_japanese.pdf          # หน้าเดียว รูปข้อความญี่ปุ่น "日本語テスト" ที่ 200dpi
 - ocr_english.pdf           # หน้าเดียว รูปข้อความอังกฤษ "English OCR Test" ที่ 200dpi
 - ocr_english_rotated.pdf   # เหมือนกันแต่หมุน 90 องศา ก่อนห่อเป็น PDF
 - ocr_too_many_pages.pdf    # 201 หน้าเปล่า (ทดสอบ reject >200 หน้า)
 - born_digital.pdf          # PDF ที่มี text layer จริง (ไม่ใช่ภาพ) สำหรับทดสอบ --skip-text
 - table_test.pdf            # ตารางมีเส้นขอบ (ruled table) สำหรับทดสอบ pdf_to_excel
 - scan_page1.png            # ภาพดิบ "English OCR Test" สำหรับทดสอบ scan_to_pdf
 - scan_page2.png            # ภาพดิบข้อความไทย สำหรับทดสอบ scan_to_pdf (ถ้ามีฟอนต์ไทย)
```
ถ้าไม่เห็น `ocr_thai.pdf` หรือ `ocr_japanese.pdf` ให้ดู log ของสคริปต์ — จะมี `WARNING: no ... font found` ถ้า Dockerfile ไม่ได้ติดตั้งฟอนต์ตามที่คาดไว้

คัดลอกออกมาที่เครื่องทดสอบเหมือน Phase 1/2:
```bash
docker compose cp doc-tools:/tmp/doc-tools-fixtures/. ~/doc-tools-fixtures/
cd ~/doc-tools-fixtures
API=http://localhost:8080
```

### 3. ทดสอบทีละ Endpoint

เครื่องมือทั้งหมดใน Phase นี้เป็น **async** (`POST /api/ops/{tool}` ตอบกลับ `job_id` ทันที ต้อง poll `GET /api/ops/{job_id}` จนกว่า `status` จะเป็น `done`/`error` — ดู flow เต็มที่หัวข้อ 4 ของ Phase 1)

ฟังก์ชันช่วย poll (ใส่ไว้ใน shell session เดียวกัน จะได้ไม่ต้องเขียน loop ซ้ำทุกครั้ง):
```bash
poll_job() {
  local job_id=$1
  while true; do
    local resp; resp=$(curl -s $API/api/ops/$job_id)
    local status; status=$(echo "$resp" | jq -r '.status')
    if [ "$status" = "done" ]; then echo "$resp" | jq -c '.result'; return 0; fi
    if [ "$status" = "error" ]; then echo "$resp" | jq -r '.error' >&2; return 1; fi
    sleep 2
  done
}
```

#### 3.1 OCR — `/api/ops/ocr`

ทดสอบทีละภาษา แล้วตรวจด้วย `pdftotext` ว่า keyword ที่รู้อยู่แล้วถูกดึงออกมาได้ (ตามเกณฑ์ plan.md หัวข้อ 7):

```bash
# ภาษาไทย
FILE_ID=$(curl -s -F "files=@ocr_thai.pdf" $API/api/files | jq -r '.[0].file_id')
JOB=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"file_id\":\"$FILE_ID\",\"languages\":\"tha\"}" $API/api/ops/ocr | jq -r '.job_id')
poll_job "$JOB"
curl -s $API/api/files/$FILE_ID/download -o ocr_thai_out.pdf
pdftotext ocr_thai_out.pdf - | grep "ไทย"

# ภาษาญี่ปุ่น
FILE_ID=$(curl -s -F "files=@ocr_japanese.pdf" $API/api/files | jq -r '.[0].file_id')
JOB=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"file_id\":\"$FILE_ID\",\"languages\":\"jpn\"}" $API/api/ops/ocr | jq -r '.job_id')
poll_job "$JOB"
curl -s $API/api/files/$FILE_ID/download -o ocr_japanese_out.pdf
pdftotext ocr_japanese_out.pdf - | grep "日本語"

# ภาษาอังกฤษ
FILE_ID=$(curl -s -F "files=@ocr_english.pdf" $API/api/files | jq -r '.[0].file_id')
JOB=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"file_id\":\"$FILE_ID\",\"languages\":\"eng\"}" $API/api/ops/ocr | jq -r '.job_id')
poll_job "$JOB"
curl -s $API/api/files/$FILE_ID/download -o ocr_english_out.pdf
pdftotext ocr_english_out.pdf - | grep -i "English"
```
**คาดหวัง:** ทั้ง 3 คำสั่ง `grep` เจอ keyword (`ไทย`, `日本語`, `English`) — ถ้าไม่เจอในบางภาษา OCR อาจอ่านผิดบางตัวอักษรแต่ยังพอใช้ได้ ให้ลองดูข้อความเต็มด้วย `pdftotext ... -` ก่อนสรุปว่าเป็นบั๊ก (ลายมือ/ฟอนต์แปลกไม่รองรับ — ดู plan.md หัวข้อ 9)

ทดสอบว่าไฟล์หมุน 90° ยังดึงข้อความได้ (พิสูจน์ `--rotate-pages`):
```bash
FILE_ID=$(curl -s -F "files=@ocr_english_rotated.pdf" $API/api/files | jq -r '.[0].file_id')
JOB=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"file_id\":\"$FILE_ID\"}" $API/api/ops/ocr | jq -r '.job_id')
poll_job "$JOB"
curl -s $API/api/files/$FILE_ID/download -o ocr_rotated_out.pdf
pdftotext ocr_rotated_out.pdf - | grep -i "English"
```
**คาดหวัง:** เจอ `English` เช่นกัน แม้ต้นฉบับเป็นภาพที่หมุนไว้

ทดสอบ PDF born-digital (มี text layer จริงอยู่แล้ว) ผ่าน OCR แบบ default (`--skip-text`) ต้องไม่ error และไม่มี text layer ซ้ำซ้อน:
```bash
FILE_ID=$(curl -s -F "files=@born_digital.pdf" $API/api/files | jq -r '.[0].file_id')
JOB=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"file_id\":\"$FILE_ID\"}" $API/api/ops/ocr | jq -r '.job_id')
poll_job "$JOB"
curl -s $API/api/files/$FILE_ID/download -o skip_text_out.pdf
pdftotext skip_text_out.pdf - | grep "born digital"
```
**คาดหวัง:** สำเร็จ (ไม่ error) และยังเจอข้อความเดิม "born digital" ผ่านไปเฉยๆ ไม่ถูกแปลงเป็นภาพซ้ำ

ทดสอบไฟล์เกิน 200 หน้า (การตรวจสอบเกิดขึ้นในงาน background หลังจากได้ `job_id` แล้ว จึงต้อง poll เหมือนเดิม แค่คาดหวังผลเป็น error แทนที่จะเป็น done):
```bash
FILE_ID=$(curl -s -F "files=@ocr_too_many_pages.pdf" $API/api/files | jq -r '.[0].file_id')
JOB=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"file_id\":\"$FILE_ID\"}" $API/api/ops/ocr | jq -r '.job_id')
poll_job "$JOB"; echo "exit code: $?"
```
**คาดหวัง:** `exit code: 1` และ stderr แสดงข้อความ "Document exceeds 200 pages..." (มาจากฟังก์ชัน `poll_job` ที่ print error ไป stderr แล้ว return 1 เมื่อ `status: "error"`)

#### 3.2 Scan to Searchable PDF — `/api/ops/scan_to_pdf` (multi-input, output เป็น file_id ใหม่)

```bash
ID1=$(curl -s -F "files=@scan_page1.png" $API/api/files | jq -r '.[0].file_id')
ID2=$(curl -s -F "files=@scan_page2.png" $API/api/files | jq -r '.[0].file_id')
JOB=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"file_ids\":[\"$ID1\",\"$ID2\"]}" $API/api/ops/scan_to_pdf | jq -r '.job_id')
RESULT=$(poll_job "$JOB")
NEW_ID=$(echo "$RESULT" | jq -r '.file_id')
curl -s $API/api/files/$NEW_ID/download -o scanned.pdf
qpdf --show-npages scanned.pdf
pdftotext scanned.pdf - | grep -i "English"
```
**คาดหวัง:** 2 หน้า และเจอข้อความ "English" จากหน้าแรกอย่างน้อย (unpaper cleanup อาจลด noise ได้บ้าง ไม่ได้แปลว่าแม่นยำ 100% — ดู honesty bar ใน plan.md)

#### 3.3 PDF to Word — `/api/ops/pdf_to_word` (output เป็น download token)

```bash
FILE_ID=$(curl -s -F "files=@born_digital.pdf" $API/api/files | jq -r '.[0].file_id')
JOB=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"file_id\":\"$FILE_ID\"}" $API/api/ops/pdf_to_word | jq -r '.job_id')
RESULT=$(poll_job "$JOB")
TOKEN=$(echo "$RESULT" | jq -r '.download_token')
curl -s $API/api/downloads/$TOKEN -o converted.docx
unzip -p converted.docx word/document.xml | grep -o "born digital"
```
**คาดหวัง:** เจอ "born digital" ในเนื้อหา (docx เป็นไฟล์ zip ข้างในมี `word/document.xml`) เปิดด้วย Word/LibreOffice จริงเพื่อดูเลย์เอาต์ได้ตามสะดวก

#### 3.4 PDF to Excel — `/api/ops/pdf_to_excel` (output เป็น download token)

```bash
FILE_ID=$(curl -s -F "files=@table_test.pdf" $API/api/files | jq -r '.[0].file_id')
JOB=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"file_id\":\"$FILE_ID\"}" $API/api/ops/pdf_to_excel | jq -r '.job_id')
RESULT=$(poll_job "$JOB")
TOKEN=$(echo "$RESULT" | jq -r '.download_token')
curl -s $API/api/downloads/$TOKEN -o tables.xlsx
```
**คาดหวัง:** ได้ไฟล์ `.xlsx` เปิดด้วย Excel/LibreOffice Calc แล้วเห็นตาราง 3 แถว (`Name/Age/City`, `Somchai/30/Bangkok`, `Yuki/25/Tokyo`) ตรงตามต้นฉบับ (ตารางมีเส้นขอบชัดเจน → ควรได้ผลจาก lattice mode)

ทดสอบไฟล์ที่ไม่มีตารางเลย (คาดหวัง error ผ่าน job แบบ error ไม่ใช่ crash):
```bash
FILE_ID=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
JOB=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"file_id\":\"$FILE_ID\"}" $API/api/ops/pdf_to_excel | jq -r '.job_id')
poll_job "$JOB"; echo "exit code: $?"
```
**คาดหวัง:** `exit code: 1` และ stderr แสดงข้อความ "No tables found..."

### 4. ทดสอบผ่านเบราว์เซอร์

- [ ] sidebar ซ้ายมีหมวดหมู่ใหม่ **OCR** (สีม่วง) พร้อมเครื่องมือ **OCR — Make Searchable** และ **Scan to Searchable PDF**
- [ ] หมวด **Convert** มีเครื่องมือเพิ่ม **PDF to Word** และ **PDF to Excel**
- [ ] อัปโหลด `ocr_thai.pdf` → เลือกไฟล์ → คลิก **OCR — Make Searchable** → ติ๊ก/ปลดติ๊กภาษาในช่อง checkbox ได้ (ไทย/ญี่ปุ่น/อังกฤษ) → คลิก "Run OCR" → เห็นสถานะ processing พร้อมเวลาที่ผ่านไป (job แบบ async) → เสร็จแล้วดาวน์โหลดได้และเปิดค้นหาข้อความในตัวได้จริง (เช่นเปิดด้วย PDF reader แล้ว Ctrl+F)
- [ ] ติ๊ก checkbox "Force OCR" แล้วรันซ้ำกับไฟล์ที่ OCR แล้ว → ไม่ error
- [ ] อัปโหลดรูป 2 ไฟล์ (`scan_page1.png`, `scan_page2.png`) → ติ๊กทั้งคู่ → คลิก **Scan to Searchable PDF** → ได้ไฟล์ PDF ใหม่ที่ค้นหาข้อความได้
- [ ] อัปโหลด PDF → คลิก **PDF to Word** → ได้ลิงก์ดาวน์โหลด `.docx` แบบใช้ครั้งเดียว
- [ ] อัปโหลด `table_test.pdf` → คลิก **PDF to Excel** → ระบุช่วงหน้าว่าง (all) → ได้ลิงก์ดาวน์โหลด `.xlsx`

### 5. ทดสอบกรณีผิดพลาด

```bash
# ไฟล์เกิน 200 หน้าสำหรับ OCR (คาดหวัง job status=error, ดูหัวข้อ 3.1)

# PDF ที่ไม่มีตารางสำหรับ pdf_to_excel (คาดหวัง job status=error, ดูหัวข้อ 3.4)

# scan_to_pdf ด้วยไฟล์เดียว (ต้องการอย่างน้อย 2 ไฟล์ - คาดหวัง 400 ทันที ไม่ต้องรอ job)
ID1=$(curl -s -F "files=@scan_page1.png" $API/api/files | jq -r '.[0].file_id')
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" \
  -d "{\"file_ids\":[\"$ID1\"]}" $API/api/ops/scan_to_pdf
```
**คาดหวัง:** `400` ("Provide at least 2 file_ids for this tool")

### 6. ตารางแก้ปัญหาเพิ่มเติม (Phase 3)

| อาการ | สาเหตุที่เป็นไปได้ | วิธีแก้ |
|---|---|---|
| `tesseract --list-langs` ไม่มี `tha`/`jpn`/`jpn_vert` | ลืม build ใหม่ หรือ apt package ชื่อผิดสำหรับ distro เวอร์ชันที่ใช้ | ตรวจ `Dockerfile`, `docker compose up -d --build` อีกครั้ง |
| `ocr_thai.pdf`/`ocr_japanese.pdf` ไม่ถูกสร้าง (มี WARNING ตอนรันสคริปต์) | หาไฟล์ฟอนต์ไม่เจอในคอนเทนเนอร์ (path เปลี่ยนไปตาม distro version) | `docker compose exec doc-tools fc-list \| grep -i thai` หรือ `\| grep -i vlgothic` แล้วแก้ path ใน `scripts/generate_test_files.py` |
| OCR ได้ `job status: error` "Processing failed" | ocrmypdf ล้มเหลว (อาจเป็น timeout หรือไฟล์เสีย) | ดู log `docker compose logs doc-tools`, ลองไฟล์เล็กลง |
| `pdf_to_excel` ได้ "No tables found" กับไฟล์ที่มีตารางจริง | ตารางไม่มีเส้นขอบชัดเจน (lattice mode ต้องการเส้น) | ผลลัพธ์แบบ best-effort ตาม honesty bar ของ plan.md — ลอง stream mode จะ fallback อัตโนมัติอยู่แล้วแต่ตารางไม่มีเส้นแบ่งอาจไม่แม่นยำ |
| `pdf_to_word`/`pdf_to_excel` ค้างสถานะ `running` นาน | ไฟล์ใหญ่/ซับซ้อน หรือ `MAX_CONCURRENT_HEAVY_JOBS` เต็ม (queue รอคิว) | ตรวจ `docker compose logs doc-tools`, ลองไฟล์เล็กลง |
| build ช้ามากตอนติดตั้ง tesseract/ฟอนต์ | ปกติของแพ็กเกจกลุ่มนี้ (ภาษา+ฟอนต์เยอะ) | รอให้เสร็จครั้งเดียว ครั้งถัดไป Docker cache ไว้แล้วจะเร็วขึ้น |

---

## Phase 4 — Security & Finishing (Protect / Unlock / Change Permissions / Watermark / Page Numbers / Add Stamp / Sign / Sign with Certificate / Flatten / Sanitize / PDF/A)

> ทุกเครื่องมือใน Phase นี้เป็น **sync** (ไม่มี `job_id`) ยกเว้นจะใช้เวลานานผิดปกติ ผลลัพธ์กลับมาทันทีเหมือน Phase 1

### 1. อัปเดตระบบก่อนทดสอบ

Phase 4 เพิ่มไลบรารี Python ใหม่ 2 ตัว (`reportlab` สำหรับลายน้ำ/เลขหน้า/ตราประทับ, `pyhanko` สำหรับเซ็นด้วยใบรับรอง) ไม่มี apt package ใหม่ (ใช้ฟอนต์ Noto Thai/JP ที่บันเดิลมากับโค้ดเอง ไม่ใช่ฟอนต์ระบบ):

```bash
git pull
docker compose up -d --build
curl http://localhost:8080/health
# คาดหวัง: {"status":"ok"}
```

### 2. สร้างไฟล์ทดสอบ (เพิ่มเติมจาก Phase 1/2/3)

ไม่มีไฟล์ใหม่ในสคริปต์ — Phase นี้ใช้ `sample_1page.pdf`/`sample_5page.pdf` (Phase 1) และ `sample_red.png` (Phase 2) ที่มีอยู่แล้ว รันสคริปต์เดิมซ้ำได้ถ้ายังไม่มีไฟล์เหล่านี้:

```bash
docker compose exec doc-tools python3 /app/scripts/generate_test_files.py
docker compose cp doc-tools:/tmp/doc-tools-fixtures/. ~/doc-tools-fixtures/
cd ~/doc-tools-fixtures
API=http://localhost:8080
```

**เฉพาะ "Sign with Certificate" เท่านั้น** ต้องมีไฟล์ใบรับรองทดสอบ (.p12) — สร้างด้วย `openssl` บนเครื่องทดสอบ (host) เอง ไม่ใช่เอกสารจริง ใช้ครั้งเดียวแล้วทิ้ง:

```bash
openssl req -x509 -newkey rsa:2048 -keyout test_key.pem -out test_cert.pem -days 1 -nodes -subj "/CN=Doc-Tools Test"
openssl pkcs12 -export -inkey test_key.pem -in test_cert.pem -out test_cert.p12 -passout pass:test1234
```
**คาดหวัง:** ได้ไฟล์ `test_cert.p12` ในโฟลเดอร์ปัจจุบัน

### 3. ทดสอบทีละ Endpoint

#### 3.1 Protect — `/api/ops/protect`

```bash
FILE_ID=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"user_password\":\"test1234\"}" $API/api/ops/protect
curl -s $API/api/files/$FILE_ID/download -o protected.pdf
qpdf --show-npages protected.pdf
```
**คาดหวัง:** คำสั่งสุดท้าย**ล้มเหลว** (`invalid password` — พิสูจน์ว่าไฟล์ถูกเข้ารหัสจริง) ทดสอบด้วยรหัสผ่านที่ถูกต้อง:
```bash
qpdf --password=test1234 --show-npages protected.pdf
```
**คาดหวัง:** `1`

#### 3.2 Unlock — `/api/ops/unlock`

```bash
FILE_ID=$(curl -s -F "files=@protected.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"password\":\"test1234\"}" $API/api/ops/unlock
curl -s $API/api/files/$FILE_ID/download -o unlocked.pdf
qpdf --show-npages unlocked.pdf
```
**คาดหวัง:** `1` (สำเร็จโดยไม่ต้องใส่รหัสผ่าน — ไฟล์ปลดล็อกแล้ว) ทดสอบรหัสผ่านผิด (คาดหวัง 400):
```bash
FILE_ID2=$(curl -s -F "files=@protected.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID2\",\"password\":\"wrongpass\"}" $API/api/ops/unlock
```
**คาดหวัง:** `400`

#### 3.3 Change Permissions — `/api/ops/change_permissions`

```bash
FILE_ID=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"allow_print\":\"true\",\"allow_copy\":\"false\",\"allow_modify\":\"false\"}" $API/api/ops/change_permissions
curl -s $API/api/files/$FILE_ID/download -o perms.pdf
qpdf --show-npages perms.pdf
qpdf --show-encryption perms.pdf | grep -i "extract for"
```
**คาดหวัง:** เปิดไฟล์ได้ทันที (ไม่มีรหัสผ่านสำหรับเปิด) และบรรทัด "extract for..." แสดงว่าไม่อนุญาต (คัดลอกถูกปิด)

#### 3.4 Watermark — `/api/ops/watermark`

```bash
FILE_ID=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"text\":\"CONFIDENTIAL\",\"opacity\":0.4,\"angle\":45}" $API/api/ops/watermark
curl -s $API/api/files/$FILE_ID/download -o watermarked.pdf
pdftotext watermarked.pdf - | grep -i CONFIDENTIAL
```
**คาดหวัง:** เจอคำว่า `CONFIDENTIAL` (ลายน้ำเป็นข้อความจริง ไม่ใช่ภาพ จึงค้นหาได้) ทดสอบข้อความภาษาไทยด้วย:
```bash
FILE_ID2=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" \
  -d "$(jq -n --arg fid "$FILE_ID2" '{file_id:$fid, text:"ห้ามเผยแพร่"}')" $API/api/ops/watermark
curl -s $API/api/files/$FILE_ID2/download -o watermarked_th.pdf
pdftotext watermarked_th.pdf - | grep "ห้ามเผยแพร่"
```
**คาดหวัง:** เจอข้อความไทยเช่นกัน (ใช้ฟอนต์ Noto Sans Thai ที่บันเดิลมา)

#### 3.5 Page Numbers — `/api/ops/page_numbers`

```bash
FILE_ID=$(curl -s -F "files=@sample_5page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"position\":\"bottom-center\",\"format\":\"{n}/{total}\"}" $API/api/ops/page_numbers
curl -s $API/api/files/$FILE_ID/download -o numbered.pdf
pdftotext -f 3 -l 3 numbered.pdf - | grep "3/5"
```
**คาดหวัง:** เจอ `3/5` ในหน้าที่ 3

#### 3.6 Add Stamp — `/api/ops/add_stamp`

```bash
FILE_ID=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
IMG_B64=$(base64 -w0 sample_red.png)
curl -s -X POST -H "Content-Type: application/json" \
  -d "$(jq -n --arg fid "$FILE_ID" --arg img "$IMG_B64" '{file_id:$fid, image_base64:$img, x:10, y:10, width_mm:30}')" \
  $API/api/ops/add_stamp
curl -s $API/api/files/$FILE_ID/download -o stamped.pdf
qpdf --show-npages stamped.pdf
ls -l sample_1page.pdf stamped.pdf
```
**คาดหวัง:** เปิดไฟล์ได้ปกติ (`1` หน้า) และขนาดไฟล์โตขึ้นชัดเจน (มีรูปภาพฝังเพิ่ม) — ตรวจตำแหน่งรูปตราประทับจริงด้วยการเปิดไฟล์ดู (ไม่มีเครื่องมือ command-line ตรวจตำแหน่งพิกเซลของภาพที่ฝังใน PDF ได้ตรงไปตรงมา)

#### 3.7 Sign (image stamp) — `/api/ops/sign`

```bash
FILE_ID=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
IMG_B64=$(base64 -w0 sample_red.png)
curl -s -X POST -H "Content-Type: application/json" \
  -d "$(jq -n --arg fid "$FILE_ID" --arg img "$IMG_B64" '{file_id:$fid, signature_base64:$img, x:120, y:20, width_mm:40}')" \
  $API/api/ops/sign
curl -s $API/api/files/$FILE_ID/download -o signed_stamp.pdf
qpdf --show-npages signed_stamp.pdf
```
**คาดหวัง:** เปิดไฟล์ได้ปกติ (`1` หน้า) — เป็นตราประทับภาพเท่านั้น **ไม่ใช่**ลายเซ็นดิจิทัลที่มีผลทางกฎหมาย (ดู 3.8 สำหรับลายเซ็นดิจิทัลจริง)

#### 3.8 Sign with Certificate — `/api/ops/sign_certificate`

```bash
FILE_ID=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
CERT_B64=$(base64 -w0 test_cert.p12)
curl -s -X POST -H "Content-Type: application/json" \
  -d "$(jq -n --arg fid "$FILE_ID" --arg cert "$CERT_B64" \
      '{file_id:$fid, cert_base64:$cert, cert_password:"test1234", reason:"Testing", location:"Bangkok"}')" \
  $API/api/ops/sign_certificate
curl -s $API/api/files/$FILE_ID/download -o signed_cert.pdf
pdfsig signed_cert.pdf
```
**คาดหวัง:** `pdfsig` (มากับ poppler-utils) แสดงลายเซ็น 1 รายการ พร้อม Reason "Testing" — สถานะความน่าเชื่อถือของใบรับรอง (trust) จะขึ้นว่าไม่ผ่าน เพราะเป็นใบรับรอง self-signed ที่สร้างเองเพื่อทดสอบเท่านั้น (คาดหวัง ไม่ใช่บั๊ก) ถ้าเครื่องทดสอบไม่มีคำสั่ง `pdfsig` (บาง distro แยกแพ็กเกจ) ให้ตรวจสอบด้วยการเปิดไฟล์ในโปรแกรมอ่าน PDF ที่แสดงแผงลายเซ็นแทน (เช่น Adobe Reader)

ทดสอบ base64 ที่ไม่ถูกต้อง (คาดหวัง 400):
```bash
FILE_ID2=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID2\",\"cert_base64\":\"not-valid-base64!!\"}" $API/api/ops/sign_certificate
```
**คาดหวัง:** `400`

#### 3.9 Flatten — `/api/ops/flatten`

```bash
FILE_ID=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" -d "{\"file_id\":\"$FILE_ID\",\"mode\":\"all\"}" $API/api/ops/flatten
curl -s $API/api/files/$FILE_ID/download -o flattened.pdf
qpdf --show-npages flattened.pdf
```
**คาดหวัง:** สำเร็จ (`1` หน้า) **หมายเหตุ:** ไฟล์ทดสอบไม่มีฟอร์ม/คำอธิบายประกอบอยู่แล้ว จึงพิสูจน์ได้แค่ว่า flatten ทำงานได้โดยไม่ error กับไฟล์ทั่วไป ไม่ได้พิสูจน์ว่าลบฟอร์มจริงออกไปหรือไม่ (ดู KNOWN_ISSUES.md)

#### 3.10 Sanitize — `/api/ops/sanitize`

```bash
pdfinfo sample_1page.pdf | grep -i producer
FILE_ID=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" -d "{\"file_id\":\"$FILE_ID\"}" $API/api/ops/sanitize
curl -s $API/api/files/$FILE_ID/download -o sanitized.pdf
pdfinfo sanitized.pdf | grep -i producer
```
**คาดหวัง:** คำสั่งแรกเจอบรรทัด `Producer` (ไฟล์ต้นฉบับสร้างด้วย pikepdf) ส่วนคำสั่งหลัง sanitize จะไม่เจอบรรทัด `Producer` เลย (metadata ถูกล้างแล้ว)

#### 3.11 PDF to PDF/A — `/api/ops/pdfa`

```bash
FILE_ID=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" -d "{\"file_id\":\"$FILE_ID\",\"level\":\"2\"}" $API/api/ops/pdfa
curl -s $API/api/files/$FILE_ID/download -o pdfa_out.pdf
qpdf --show-npages pdfa_out.pdf
```
**คาดหวัง:** สำเร็จ (`1` หน้า) เปิดได้ปกติ **หมายเหตุ:** นี่คือผลลัพธ์แบบ best-effort จาก ghostscript เท่านั้น ยังไม่ได้ตรวจสอบผ่านเครื่องมือมาตรฐาน veraPDF ว่าไฟล์เป็น PDF/A ที่ถูกต้อง 100% ตามสเปก (ดู KNOWN_ISSUES.md)

### 4. ทดสอบผ่านเบราว์เซอร์ (เพิ่มเติมจาก Phase 1/2/3)

- [ ] sidebar ซ้ายมีหมวดหมู่ใหม่ **Security** (สีน้ำเงิน) พร้อมเครื่องมือครบ 11 รายการ (Protect, Unlock, Change Permissions, Watermark, Page Numbers, Add Stamp, Sign, Sign with Certificate, Flatten, Sanitize, PDF to PDF/A)
- [ ] เลือกไฟล์ PDF → คลิก **Protect PDF** → ใส่รหัสผ่าน → Apply → ดาวน์โหลดไฟล์แล้วลองเปิดด้วยโปรแกรมอ่าน PDF ทั่วไป → ต้องถามรหัสผ่านก่อนเปิด
- [ ] อัปโหลดไฟล์ที่ใส่รหัสผ่านแล้ว → คลิก **Unlock PDF** → ใส่รหัสผ่านถูกต้อง → Apply → ไฟล์เปิดได้โดยไม่ต้องใส่รหัสผ่านอีก
- [ ] คลิก **Watermark** → พิมพ์ข้อความ (ลองภาษาไทย) → Apply → เปิดไฟล์ผลลัพธ์เห็นลายน้ำแนวทแยง
- [ ] คลิก **Page Numbers** → เลือกตำแหน่ง → Apply → เปิดไฟล์เห็นเลขหน้าตามตำแหน่งที่เลือก
- [ ] คลิก **Add Stamp** หรือ **Sign** → เลือกไฟล์รูปภาพจากเครื่อง (ปุ่ม "Choose file" ในแผงตัวเลือกขวา) → เห็นข้อความ "✓ เลือกไฟล์แล้ว" → Apply → เปิดไฟล์เห็นรูปที่วางไว้ตามตำแหน่ง
- [ ] คลิก **Sign with Certificate** → เลือกไฟล์ `.p12` ที่สร้างไว้ + ใส่รหัสผ่าน → Apply → ไฟล์ผลลัพธ์มีแผงลายเซ็นดิจิทัลเมื่อเปิดในโปรแกรมที่รองรับ (เช่น Adobe Reader)
- [ ] คลิก **PDF to PDF/A** → เลือกระดับ → Apply → ไฟล์เปิดได้ปกติ

### 5. ทดสอบกรณีผิดพลาด (เพิ่มเติมจาก Phase 1/2/3)

```bash
# protect โดยไม่ใส่รหัสผ่านใดๆ เลย (คาดหวัง 400)
FILE_ID=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\"}" $API/api/ops/protect

# watermark โดยไม่ใส่ข้อความ (คาดหวัง 400)
FILE_ID2=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID2\"}" $API/api/ops/watermark

# pdfa ด้วย level ที่ไม่รองรับ (คาดหวัง 400)
FILE_ID3=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID3\",\"level\":\"9\"}" $API/api/ops/pdfa
```
**คาดหวัง:** ทั้ง 3 คำสั่งได้ `400`

### 6. ตารางแก้ปัญหาเพิ่มเติม (Phase 4)

| อาการ | สาเหตุที่เป็นไปได้ | วิธีแก้ |
|---|---|---|
| `protect`/`unlock` ได้ 500 กับ PDF ที่มีการเข้ารหัสแบบแปลกๆ อยู่แล้ว | pikepdf ไม่รองรับรูปแบบการเข้ารหัสเดิมของไฟล์นั้น | ลองไฟล์อื่น หรือ unlock ด้วยโปรแกรมอื่นก่อนแล้วค่อยอัปโหลดใหม่ |
| `sign_certificate` ได้ 500 "Signing failed" | ใบรับรอง `.p12` เสียหาย/รหัสผ่านผิด/รูปแบบไม่รองรับ | ตรวจว่าสร้าง `.p12` ถูกต้องด้วยคำสั่ง `openssl pkcs12 -info -in test_cert.p12` |
| `pdfsig` ไม่มีในเครื่องทดสอบ | บาง distro แยก poppler-utils ออกเป็นหลายแพ็กเกจย่อย | ติดตั้งเพิ่มหรือข้ามการตรวจสอบนี้ไปตรวจด้วยโปรแกรมอ่าน PDF แทน |
| ลายน้ำ/เลขหน้าภาษาไทยกลายเป็นสี่เหลี่ยม/หายไป | ฟอนต์ Noto Sans Thai ไม่ได้ถูก copy เข้า image ตอน build | ตรวจว่า `backend/assets/fonts/NotoSansThai-Regular.ttf` มีอยู่จริงในคอนเทนเนอร์ (`docker compose exec doc-tools ls backend/assets/fonts/` เมื่ออยู่ที่ `/app`) |
| `pdfa` ได้ 500 "PDF/A conversion failed" | ghostscript ไม่รองรับโครงสร้างไฟล์ต้นฉบับบางแบบ | ลองไฟล์อื่น ดู log `docker compose logs doc-tools` |

---

## Phase 5 — Advanced (Compare / Redact)

> **Compare** เป็นเครื่องมือ **async** (ตอบกลับ `job_id` ต้อง poll) รับ PDF 2 ไฟล์พอดี แล้วสร้าง "รายงานเปรียบเทียบ" เป็นไฟล์ใหม่ (file_id ใหม่) ในพื้นที่ทำงาน
> **Redact** เป็นเครื่องมือ **sync** ปิดทับข้อมูลด้วยกล่องสีดำ แล้วแปลงหน้านั้นเป็นรูปภาพ ทำให้ข้อความใต้กล่อง**ถูกลบถาวร** (พิสูจน์ได้ด้วย `pdftotext`)

### 1. อัปเดตระบบก่อนทดสอบ

Phase 5 ไม่มีไลบรารีหรือ apt package ใหม่ (ใช้ pdf2image / Pillow / reportlab / img2pdf / pikepdf ที่ติดตั้งแล้ว):

```bash
git pull
docker compose up -d --build
curl http://localhost:8080/health
# คาดหวัง: {"status":"ok"}
```

### 2. สร้างไฟล์ทดสอบ (เพิ่มเติมจาก Phase 1–4)

รันสคริปต์เดิมซ้ำ — จะได้ไฟล์ใหม่ 3 ไฟล์: `compare_a.pdf` (3 หน้า), `compare_b.pdf` (4 หน้า — หน้า 2 ข้อความต่างจาก A และหน้า 4 มีเฉพาะใน B), `redact_secret.pdf` (2 หน้า — หน้า 1 มีคำลับ `SECRET-12345` อยู่ด้านบน, หน้า 2 มีข้อความ `PUBLIC-PAGE-TWO`):

```bash
docker compose exec doc-tools python3 /app/scripts/generate_test_files.py
docker compose cp doc-tools:/tmp/doc-tools-fixtures/. ~/doc-tools-fixtures/
cd ~/doc-tools-fixtures
API=http://localhost:8080
```

### 3. ทดสอบทีละ Endpoint

#### 3.1 Compare — `/api/ops/compare` (async, multi-input, ได้ file_id ใหม่)

```bash
ID_A=$(curl -s -F "files=@compare_a.pdf" $API/api/files | jq -r '.[0].file_id')
ID_B=$(curl -s -F "files=@compare_b.pdf" $API/api/files | jq -r '.[0].file_id')
JOB_ID=$(curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_ids\":[\"$ID_A\",\"$ID_B\"]}" $API/api/ops/compare | jq -r '.job_id')
while true; do
  STATUS=$(curl -s $API/api/ops/$JOB_ID | jq -r '.status')
  [ "$STATUS" = "done" ] || [ "$STATUS" = "error" ] && break
  sleep 1
done
echo "job status: $STATUS"
REPORT_ID=$(curl -s $API/api/ops/$JOB_ID | jq -r '.result.file_id')
curl -s $API/api/files/$REPORT_ID/download -o compare_report.pdf
qpdf --show-npages compare_report.pdf
pdftotext -f 1 -l 1 compare_report.pdf -
```
**คาดหวัง:** `status: done` · รายงานมี `2` หน้า (หน้าสรุป + หน้าเทียบข้างกัน 1 หน้าสำหรับหน้าที่ 2 ที่ต่างกัน) · ข้อความหน้าสรุปมี `Changed pages (1): 2` และ `Pages only in file B: 4`

#### 3.2 Compare ไฟล์เหมือนกันทุกหน้า (ต้องไม่พบความต่าง)

```bash
ID_A1=$(curl -s -F "files=@compare_a.pdf" $API/api/files | jq -r '.[0].file_id')
ID_A2=$(curl -s -F "files=@compare_a.pdf" $API/api/files | jq -r '.[0].file_id')
JOB_ID=$(curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_ids\":[\"$ID_A1\",\"$ID_A2\"]}" $API/api/ops/compare | jq -r '.job_id')
sleep 5
REPORT_ID=$(curl -s $API/api/ops/$JOB_ID | jq -r '.result.file_id')
curl -s $API/api/files/$REPORT_ID/download -o compare_same.pdf
qpdf --show-npages compare_same.pdf
pdftotext compare_same.pdf - | grep "No visual differences"
```
**คาดหวัง:** รายงานมี `1` หน้า (สรุปอย่างเดียว) และเจอข้อความ `No visual differences found`

#### 3.3 Redact — `/api/ops/redact` (sync, พิสูจน์ว่าข้อความถูกลบจริง)

ก่อน redact ต้องดึงคำลับออกมาได้:
```bash
pdftotext redact_secret.pdf - | grep SECRET-12345
```
**คาดหวัง:** เจอ `SECRET-12345`

จากนั้น redact กล่องคลุมส่วนบนของหน้า 1 (พิกัด 0–1 เทียบกับขนาดหน้า, มุมบนซ้ายคือจุด 0,0):
```bash
FILE_ID=$(curl -s -F "files=@redact_secret.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"boxes\":[{\"page\":1,\"x0\":0,\"y0\":0,\"x1\":1,\"y1\":0.35}]}" \
  $API/api/ops/redact | jq '.version'
curl -s $API/api/files/$FILE_ID/download -o redacted.pdf
qpdf --show-npages redacted.pdf
pdftotext redacted.pdf - | grep SECRET-12345
pdftotext redacted.pdf - | grep PUBLIC-PAGE-TWO
```
**คาดหวัง:** `version` เป็น `2` · ยังมี `2` หน้าเท่าเดิม · คำสั่ง grep `SECRET-12345` **ไม่เจออะไรเลย** (ข้อความถูกลบถาวร) · grep `PUBLIC-PAGE-TWO` ยังเจอ (หน้า 2 ไม่ถูกแตะต้อง ข้อความยังอยู่)

**หมายเหตุ:** ข้อความอื่นบนหน้า 1 (`page-one-public-text`) จะหายจากการค้นหาด้วย เพราะทั้งหน้าถูกแปลงเป็นรูปภาพ — ยังมองเห็นตามปกติ แต่ค้นหา/คัดลอกไม่ได้ (ตามข้อจำกัดที่ตั้งใจไว้ใน plan.md)

ทดสอบ undo หลัง redact (ข้อความต้องกลับมา):
```bash
curl -s -X POST -H "Content-Type: application/json" -d '{"to_version":1}' $API/api/files/$FILE_ID/revert | jq '.version'
curl -s $API/api/files/$FILE_ID/download -o reverted.pdf
pdftotext reverted.pdf - | grep SECRET-12345
```
**คาดหวัง:** `version` กลับเป็น `1` และเจอ `SECRET-12345` อีกครั้ง (v1 ต้นฉบับยังอยู่จนกว่า TTL จะหมด — ถ้าต้องการลบถาวรจริงให้ดาวน์โหลดไฟล์ v2 แล้วลบไฟล์ออกจากพื้นที่ทำงาน)

### 4. ทดสอบผ่านเบราว์เซอร์ (เพิ่มเติมจาก Phase 1–4)

- [ ] sidebar ซ้ายมีหมวดหมู่ใหม่ **Advanced** (สีเทา) พร้อมเครื่องมือ 2 รายการ (Compare PDFs, Redact)
- [ ] อัปโหลด `compare_a.pdf` และ `compare_b.pdf` → **Compare PDFs** จางอยู่จนกว่าจะติ๊กเลือก PDF **2 ไฟล์พอดี** (ติ๊ก 1 หรือ 3 ไฟล์ = จาง)
- [ ] ติ๊ก 2 ไฟล์ → คลิก **Compare PDFs** → Apply → เห็นตัวนับเวลาขณะประมวลผล → ได้การ์ดไฟล์ใหม่ `compare_report.pdf` ในพื้นที่ทำงาน เปิด thumbnail ดูหน้าสรุปและหน้าเทียบข้างกันได้
- [ ] เลือกไฟล์ PDF 1 ไฟล์ → คลิก **Redact** → thumbnail ของทุกหน้าขยายใหญ่ขึ้นและ cursor เป็นกากบาท → **ลากเมาส์**บนหน้าเพื่อวาดกล่อง → เห็นกล่องดำทับบริเวณที่ลาก
- [ ] คลิกที่กล่องดำที่วาดไว้ → กล่องหายไป (ลบทีละกล่องได้) · ปุ่ม "Clear all boxes" ในแผงขวาล้างทุกกล่อง
- [ ] ปุ่ม Apply จางอยู่จนกว่าจะมีกล่องอย่างน้อย 1 กล่อง → วาดกล่อง → Apply → version เพิ่มเป็น v2 และ thumbnail แสดงกล่องดำถาวรบนหน้า
- [ ] กด v1 ใน version bar (undo) → กลับเป็นหน้าเดิมก่อนปิดทับ

### 5. ทดสอบกรณีผิดพลาด (เพิ่มเติมจาก Phase 1–4)

```bash
# compare ด้วยไฟล์ 3 ไฟล์ (คาดหวัง 400 - ต้อง 2 ไฟล์พอดี)
ID1=$(curl -s -F "files=@compare_a.pdf" $API/api/files | jq -r '.[0].file_id')
ID2=$(curl -s -F "files=@compare_b.pdf" $API/api/files | jq -r '.[0].file_id')
ID3=$(curl -s -F "files=@sample_1page.pdf" $API/api/files | jq -r '.[0].file_id')
JOB_ID=$(curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"file_ids\":[\"$ID1\",\"$ID2\",\"$ID3\"]}" $API/api/ops/compare | jq -r '.job_id')
sleep 2
curl -s $API/api/ops/$JOB_ID | jq '{status, error}'
# คาดหวัง: status "error" และ error "Select exactly 2 PDF files to compare"
# (เครื่องมือ async รายงานข้อผิดพลาดผ่านสถานะ job ไม่ใช่ HTTP code ตอน submit)

# compare ด้วยไฟล์เดียว (คาดหวัง 400 ทันทีตอน submit - router ต้องการอย่างน้อย 2)
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" \
  -d "{\"file_ids\":[\"$ID1\"]}" $API/api/ops/compare

# redact โดยไม่ส่ง boxes เลย (คาดหวัง 400)
FILE_ID=$(curl -s -F "files=@redact_secret.pdf" $API/api/files | jq -r '.[0].file_id')
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\"}" $API/api/ops/redact

# redact กล่องชี้ไปหน้าที่ไม่มีจริง (คาดหวัง 400)
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"boxes\":[{\"page\":99,\"x0\":0,\"y0\":0,\"x1\":0.5,\"y1\":0.5}]}" $API/api/ops/redact

# redact พิกัดกลับด้าน x1 < x0 (คาดหวัง 400)
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\",\"boxes\":[{\"page\":1,\"x0\":0.8,\"y0\":0,\"x1\":0.2,\"y1\":0.5}]}" $API/api/ops/redact
```
**คาดหวัง:** compare 1 ไฟล์ / redact ทั้ง 3 กรณีได้ `400`

### 6. ตารางแก้ปัญหาเพิ่มเติม (Phase 5)

| อาการ | สาเหตุที่เป็นไปได้ | วิธีแก้ |
|---|---|---|
| compare ได้ job `error` "limited to 100 pages" | ไฟล์ใดไฟล์หนึ่งเกิน 100 หน้า | เครื่องมือเปรียบเทียบจำกัด 100 หน้าต่อไฟล์เพื่อประสิทธิภาพ — แยกไฟล์ (Split) ก่อนเทียบ |
| compare ช้ามาก | ต้อง render ทั้ง 2 ไฟล์ทุกหน้าเป็นรูปภาพ | ปกติสำหรับไฟล์หลายสิบหน้า รอ job จบ (มีตัวนับเวลาใน UI) |
| compare ไม่ flag หน้าที่แก้ตัวอักษรเล็กน้อยมาก | การเปลี่ยนแปลง <0.5% ของพิกเซลถือว่าเป็น noise | ข้อจำกัดที่ตั้งใจ (ไม่ใช่ word-level diff — ดู plan.md ข้อ 9) |
| หน้าใน redacted.pdf ดูแตกต่างจากเดิมเล็กน้อย (ฟอนต์ไม่คม) | หน้าที่ถูกปิดทับถูกแปลงเป็นรูปภาพ 200 dpi ทั้งหน้า | พฤติกรรมที่ตั้งใจ — จำเป็นเพื่อให้ข้อความใต้กล่องถูกลบจริง |
| ขนาดไฟล์โตขึ้นหลัง redact | หน้า raster (PNG) ใหญ่กว่าหน้าข้อความเดิม | ใช้เครื่องมือ Compress ต่อในเชนได้ (ผลลัพธ์ยังค้นหาไม่ได้เหมือนเดิม) |
| วาดกล่องในเบราว์เซอร์ไม่ได้ | ยังไม่ได้เลือกเครื่องมือ Redact หรือติ๊กไฟล์ไว้มากกว่า 1 ไฟล์ | เลือกเครื่องมือ Redact และติ๊ก PDF ไว้เพียงไฟล์เดียว |

---
