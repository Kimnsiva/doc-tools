# plan.md — Doc-Tools: Self-Hosted Document Workspace (Stirling-PDF-style UX)

> **Instructions for Claude Code — READ FIRST**
> - All decisions are already made. Do NOT ask clarifying questions.
> - Do NOT explain code in chat. Chat replies = 1–3 lines max (what was created, what to run next).
> - Do NOT run the server or tests yourself unless a build error occurs. The user tests manually via TESTING.md.
> - **Build ONE phase at a time.** Start with Phase 1. Only continue when the user explicitly says "start phase N".
> - Every phase ends with: working endpoints + working UI + a new TESTING.md section (in Thai, copy-paste commands).
> - If a fix fails twice, log it in KNOWN_ISSUES.md and move on. Never loop on the same bug.
> - Quality bars in section 9 are final — meeting the acceptance test is "done". Do not chase perfection beyond a library's known limits.

---

## 1. Product Concept

**Name:** doc-tools
**Goal:** Self-hosted document workspace, deployed as one Docker container on a company Linux server, used by employees over LAN. Covers the full iLovePDF feature set, but with **Stirling-PDF's file-first UX**:

> Upload a file ONCE → it stays in your workspace → apply any chain of operations to it (rotate → remove pages → OCR → compress) → download the result whenever you want. No re-uploading between tools.

Stateless beyond a short TTL: no database, no accounts. Working files live on the server only during the session (TTL from env) and are then wiped. Documents never leave the company network.

**Users:** Non-technical office staff, Thai/Japanese company. Documents are mixed Thai / Japanese / English — OCR must handle all three.

---

## 2. Architecture: File-First Workspace

### Core model
1. Client uploads file(s) → server stores under `/tmp/doc-tools/<file_id>/v1.pdf` → returns `file_id` + metadata.
2. Every operation takes a `file_id` (+ options) → produces a **new version** `v2, v3, ...` of the same file_id → returns updated metadata. Original versions are kept until TTL, enabling **Undo** (revert to previous version).
3. Client can download any version at any time. Every upload/operation refreshes the file's TTL clock.
4. Sweeper task deletes any file_id untouched for `FILE_TTL_MINUTES` (default 30).

### API contract
All JSON unless noted. Errors: `{"error": "<plain-language message>"}` + correct HTTP status.

| Endpoint | Purpose |
|---|---|
| `POST /api/files` | multipart upload (1+ files) → `[{file_id, name, pages, size_bytes, version}]` |
| `GET /api/files/{id}` | metadata: name, pages, size, version, version_history |
| `GET /api/files/{id}/download?version=n` | download (default latest) |
| `GET /api/files/{id}/thumb/{page}?version=n` | PNG thumbnail (~200px wide, poppler) for the page strip |
| `POST /api/files/{id}/revert` | `{to_version}` → undo |
| `DELETE /api/files/{id}` | user removes file from workspace immediately |
| `POST /api/ops/{tool}` | body `{file_id, ...options}` → runs tool → new version → returns updated metadata. Multi-input tools (merge, images_to_pdf, scan_to_pdf, compare) take `{file_ids: [...]}` and return a NEW file_id. Tools whose output isn't a PDF the workspace can keep versioning (pdf→images zip, pdf→word/excel, split-every-N zip) return `{"download_token": ...}` instead. Tool file inputs beyond the workspace file (stamp/signature images, .p12 certificates) are sent as base64 strings inside the JSON body — the whole ops contract stays JSON, no extra multipart endpoints. |
| `GET /api/ops/{job_id}` | poll async heavy jobs: `{status, progress?, result, error?}` |
| `GET /api/downloads/{token}` | redeem a `download_token` — one-shot, file is deleted after the first download |
| `GET /health` | `{"status":"ok"}` |

Async vs sync: tools flagged `async_job` in the registry (OCR, office→PDF, scan-to-pdf, PDF→Word, PDF→Excel; compare when built) return `{job_id}` immediately — poll `GET /api/ops/{job_id}`. Other heavy tools (compress, repair, PDF/A, HTML→PDF, PDF→images) run synchronously but under the heavy semaphore; light tools run synchronously under the light semaphore. One code path in frontend handles both.

---

## 3. Tech Stack (fixed — do not substitute)

| Layer | Choice | Used for |
|---|---|---|
| Backend | Python 3.12 + FastAPI + uvicorn | API + serves static frontend |
| PDF core | pikepdf | merge, split, rotate, organize, remove pages, protect, unlock, crop, metadata |
| Compress / PDF-A | ghostscript | compress presets, PDF/A |
| Repair | qpdf CLI | structure rebuild |
| Office → PDF | LibreOffice headless | docx/xlsx/pptx → PDF |
| **OCR ★** | **ocrmypdf** + tesseract langs `tha` `jpn` `jpn_vert` `eng` | searchable PDF, scan cleanup |
| PDF → Word | pdf2docx | text-based PDFs (auto-OCR first if scanned) |
| PDF → Excel | camelot-py[cv] | table extraction |
| PDF ↔ Images | pdf2image (poppler) + img2pdf + Pillow | thumbnails, pdf→jpg/png, images→pdf |
| Overlays | reportlab + pikepdf | watermark, page numbers, stamp/sign overlays — Noto Sans Thai + Noto Sans JP fonts bundled in `backend/assets/fonts/` |
| Certificate signing | pyhanko | sign_certificate (PAdES from a user-uploaded .p12) — offline only, no TSA/OCSP/CRL calls |
| HTML → PDF | weasyprint | uploaded .html only (no URL fetch — LAN security) |
| Frontend | Static HTML + vanilla JS + CSS, no framework, no build step, no CDN (bundle fonts locally) | single-page workspace |
| Container | Docker + docker-compose, base `python:3.12-slim` + apt packages | one container |

**Dockerfile apt packages (as shipped):** `ghostscript qpdf poppler-utils curl libreoffice tesseract-ocr tesseract-ocr-{tha,jpn,jpn-vert,eng} unpaper imagemagick` + weasyprint runtime libs (`libpango*`, `libcairo2`, `libgdk-pixbuf-2.0-0`, `shared-mime-info`) + fonts (`fonts-dejavu-core fonts-noto-cjk fonts-thai-tlwg fonts-vlgothic`) + `libgomp1`, all with `--no-install-recommends`. (`pngquant` was dropped: ocrmypdf runs at `--optimize 1`, which doesn't need it.) Python pins live in `backend/requirements.txt` with comments; see KNOWN_ISSUES.md before bumping pikepdf/ocrmypdf/weasyprint/pydyf/camelot.

**.env.example:** `PORT=8080, MAX_FILE_SIZE_MB=100, FILE_TTL_MINUTES=30, MAX_CONCURRENT_HEAVY_JOBS=2, MAX_CONCURRENT_LIGHT_JOBS=6`

---

## 4. Repository Structure

```
doc-tools/
├── docker-compose.yml          # named volume doc-tools-tmp → /tmp/doc-tools, healthcheck /health, restart unless-stopped
├── Dockerfile
├── .env.example
├── .gitignore                  # .env, __pycache__/, generated test files (*.pdf/docx/xlsx/zip), tmp/, .DS_Store
├── README.md                   # deploy in ≤5 commands
├── TESTING.md                  # ★ Thai manual test guide, grows per phase
├── KNOWN_ISSUES.md
├── scripts/
│   └── generate_test_files.py  # generates ALL test fixtures for TESTING.md (never real documents)
├── backend/
│   ├── main.py                 # FastAPI app: health, routers, TTL sweeper lifespan, serves frontend/
│   ├── requirements.txt        # pinned; comments explain each pin (see KNOWN_ISSUES.md)
│   ├── assets/fonts/           # bundled Noto Sans Thai + Noto Sans JP (+ OFL licenses)
│   ├── core/
│   │   ├── store.py            # file_id/version storage under /tmp/doc-tools, metadata, TTL sweeper, revert, thumbnails
│   │   ├── limits.py           # size check, heavy/light semaphores
│   │   ├── jobs.py             # in-memory async job registry for heavy ops
│   │   ├── runner.py           # subprocess wrapper: arg list only, timeout, kill → 504
│   │   ├── fonts.py            # registers the bundled Noto fonts for reportlab
│   │   ├── pdfutils.py         # shared pikepdf/page-range helpers
│   │   └── stamping.py         # shared overlay logic (watermark / page numbers / stamp / sign)
│   ├── routers/
│   │   ├── files.py            # /api/files* endpoints
│   │   └── ops.py              # /api/ops/{tool}, /api/ops/{job_id}, /api/downloads/{token}
│   └── ops/                    # one module per tool; importing the package registers everything
│       ├── registry.py         # ToolSpec / OpResult dataclasses + TOOL_REGISTRY dict
│       ├── __init__.py         # imports every tool module → registers it (new tool = new file + one import line)
│       ├── merge.py  split.py  rotate.py  organize.py  remove_pages.py     # Phase 1
│       ├── compress.py  repair.py  crop.py                                 # Phase 1
│       ├── office_to_pdf.py  pdf_to_images.py  images_to_pdf.py  html_to_pdf.py   # Phase 2
│       ├── ocr.py  scan_to_pdf.py  pdf_to_word.py  pdf_to_excel.py         # Phase 3
│       ├── protect.py  unlock.py  change_permissions.py  watermark.py      # Phase 4
│       ├── page_numbers.py  add_stamp.py  sign.py  sign_certificate.py     # Phase 4
│       ├── flatten.py  sanitize.py  pdfa.py                                # Phase 4
│       └── compare.py  redact.py                                           # Phase 5
└── frontend/
    ├── index.html
    ├── css/style.css
    └── js/
        ├── api.js              # fetch wrapper, job polling
        ├── workspace.js        # file list, page strip, versions, undo
        └── tools.js            # tool panel rendering from a TOOLS config object
```

`TOOL_REGISTRY` pattern (`ops/registry.py`): each ops module calls `register(ToolSpec(name, input_type single/multi, heavy, async_job, output version/new_file/download, run))` at import time; `ops/__init__.py` imports every module. Router and frontend tool panel are driven by the registry → adding a tool = one new `ops/*.py` file + one import line, zero router changes. An op's `run()` returns an `OpResult` and may override the output kind per-call (e.g. split: page range → new version, but every-N mode → zip download).

---

## 5. Frontend: Workspace UI (Stirling-style)

**Single-page layout, three zones:**

```
┌──────────┬──────────────────────────────┬───────────────┐
│ TOOLS    │  WORKSPACE (center)          │ TOOL OPTIONS  │
│ sidebar  │  file card(s) + page strip   │ panel (right) │
│ grouped, │  thumbnails, version bar,    │ appears when  │
│ search   │  Undo / Download buttons     │ tool selected │
└──────────┴──────────────────────────────┴───────────────┘
```

- **Empty state:** big centered drop zone "Drop PDF / Word / Excel / images here — วางไฟล์ที่นี่" + file picker button.
- **After upload:** file card in center: filename, page count, size, current version. Below it a horizontal **page-thumbnail strip** (lazy-loaded from `/thumb/`). Multiple files stack as separate cards; merge/compare tools activate when 2+ selected via checkboxes.
- **Left sidebar:** tools grouped — **Organize / Optimize / Convert / OCR / Security / Advanced** — with a quick-filter search box. Tool names: English + short Thai subtitle ("OCR — แปลงสแกนเป็นข้อความค้นหาได้"). Tools that don't apply to current selection are dimmed.
- **Right panel:** options for the selected tool + big **Apply** button. On apply: light ops update the card instantly (version +1, thumbnails refresh); heavy ops show progress with elapsed time via job polling.
- **Chaining is the point:** after an op completes, the file stays selected — user immediately picks the next tool. Version bar shows `v1 → v2 → v3` with an **Undo** (revert) control.
- **Download:** persistent button on each file card, always downloads the latest version (or chosen version from the version bar).
- **Visual theme:** clean, light, professional-tool feel: background `#f5f6f8`, white panels, accent red `#e5322d`, per-category icon colors (Organize red / Optimize green / Convert orange / OCR purple / Security blue / Advanced gray), rounded 8px, subtle shadows, system font stack or bundled Inter woff2 (NO CDN). Footer: "🔒 Files stay on the company server and are deleted after 30 minutes."
- Desktop Chrome/Edge first; sidebar collapses to icons on narrow windows.

---

## 6. Full Tool Set → Build Phases

> Status (2026-07-06): Phases 1–4 are **shipped** (endpoints + UI + Thai TESTING.md sections exist for each). Phase 5 (compare, redact) is **implemented and awaiting the user's TESTING.md run** — its gate is not passed yet. Phase 6 (polish) is not started.

### Phase 1 — Workspace core + light PDF ops ✅ shipped
The foundation phase: `core/store.py`, upload, thumbnails, versioning, undo, TTL sweeper, workspace UI shell, plus these registry tools (pikepdf/ghostscript only):
**Merge · Split/Extract pages · Remove pages · Organize (reorder) · Rotate · Compress · Repair · Crop**
Split/Remove/Organize should support clicking pages in the thumbnail strip to select them (fallback: text input `1-3,5`).

### Phase 2 — Convert ✅ shipped
**Office→PDF (LibreOffice, async) · PDF→JPG/PNG (zip, dpi 96/150/300) · Images→PDF · HTML→PDF (uploaded .html only)**
Non-PDF uploads (docx/xlsx/pptx/images/html) are accepted at `/api/files` from this phase; workspace shows a generic icon card for them and offers only the applicable convert tools.

### Phase 3 — OCR ★ flagship (see section 7) ✅ shipped
**OCR (searchable PDF, async) · Scan-to-PDF (images → unpaper clean → OCR) · PDF→Word (pdf2docx, auto-OCR scanned input) · PDF→Excel (camelot lattice→stream fallback)**

### Phase 4 — Security & finishing ✅ shipped
**Protect (AES-256) · Unlock (correct password only — never brute-force) · Change permissions · Watermark (text/image; must render Thai + Japanese via bundled Noto fonts) · Page numbers · Add stamp · Sign (visual image stamp — NOT a digital certificate, labeled clearly in UI) · Sign with certificate (real PAdES via pyhanko + user .p12 — offline, no TSA/OCSP, so no trusted timestamp/LTV) · Flatten · Sanitize (strip metadata/JS/embedded content) · PDF→PDF/A**
Shipped scope is wider than originally planned (11 tools vs 6): change_permissions / add_stamp / flatten / sanitize / sign_certificate from implementation_plan.md's broader Security list were already implemented, so they were wired in rather than left as dead code (see KNOWN_ISSUES.md Phase 4). Later phase lists are a floor, not a ceiling.

### Phase 5 — Advanced (best-effort tier) 🧪 implemented, awaiting manual test
**Compare** (two file_ids → changed-page list + side-by-side PNG report) · **Redact** (user draws boxes on page thumbnails → coordinates sent → redacted pages rasterized so text is truly removed — verify with pdftotext).
**Edit PDF = out of scope** (in-browser text editing is a separate product); the workspace chain of Organize+Watermark+Sign+Page-numbers covers the practical need.

### Phase 6 — Polish
Thai/English UI toggle, keyboard shortcuts (Del = remove selected pages), drag-reorder thumbnails for Organize, favicon + simple original logo (do not imitate Stirling or iLovePDF branding), docker healthcheck, README finalization.

---

## 7. OCR Quality Requirements ★ (overrides everything else for Phase 3)

1. Use **ocrmypdf**, not raw tesseract. Default flags: `--rotate-pages --deskew --clean --optimize 1 --skip-text`. UI options: language checkboxes + "Force OCR" toggle (`--force-ocr` for PDFs with a bad existing text layer).
2. Languages: checkboxes `tha / jpn / eng`, default all three → `-l tha+jpn+eng`; add `jpn_vert` automatically when jpn is selected.
3. Output = searchable PDF: original page image preserved, invisible text layer added. Never re-render pages at lower quality.
4. Heavy semaphore; timeout `30s + 10s × page_count`, cap 15 min; reject >200 pages with a clear message.
5. **Acceptance tests (must appear in TESTING.md):**
   - Script generates 3 one-page image-only PDFs locally (a Thai sentence, a Japanese sentence, an English sentence — rendered to 200-dpi raster, wrapped back into PDF). Never use real company documents.
   - OCR each → `pdftotext out.pdf -` must contain the known keyword for each language (keywords listed in TESTING.md).
   - A 90°-rotated English scan → text still extractable (proves `--rotate-pages`).
   - A born-digital PDF with `--skip-text` → passes through, no duplicated text layer.

---

## 8. Platform Rules (every endpoint)

- Validate uploads by magic bytes (`%PDF`, PNG/JPG, zip-based office signatures), never trust extension → 400.
- Enforce `MAX_FILE_SIZE_MB` → 413. Light/heavy semaphores from env.
- All subprocess calls via `core/runner.py`: argument list (no shell=True), timeout, kill → 504 friendly message.
- file_id = UUID4; path traversal impossible (ids validated, paths built server-side only).
- Every op writes a new version file then atomically updates metadata — a crashed op never corrupts the previous version.
- No filenames/contents in logs above debug. No outbound network calls at runtime.

## 9. Quality Bars & Honest Limits (do not fight these)

| Feature | "Done" means | Accepted limit |
|---|---|---|
| OCR | keywords extractable in tha/jpn/eng tests | handwriting unsupported |
| Office→PDF | opens correctly, matches LibreOffice rendering | exotic fonts fall back |
| PDF→Word | text + basic layout editable in Word | complex layouts imperfect |
| PDF→Excel | ruled tables land in correct cells | borderless tables best-effort |
| Compress | ≥30% smaller on image-heavy test at medium | text-only PDFs shrink little |
| Compare | changed pages correctly flagged | not word-level legal diff |
| Redact | redacted text unrecoverable via pdftotext | redacted pages become raster |
| Thumbnails | strip loads <2s for a 50-page file | rendered at 100dpi max |

## 10. TESTING.md Rules

Thai language, grows one section per phase, everything copy-paste: prerequisites check · `docker compose up --build` with expected log lines · script generating ALL test files (PDFs, images, docx/xlsx via python-docx/openpyxl — never real documents) · per-endpoint curl tests including the file_id flow (upload → capture file_id with `jq` → op → download → verify with `qpdf --show-npages` / `pdftotext` / `ls -l`) · undo/revert test · browser checklist per phase · failure tests (wrong type→400, oversize→413, wrong password, bad file_id→404) · TTL cleanup check (`docker compose exec doc-tools ls /tmp/doc-tools`) · update procedure (`git pull && docker compose up -d --build`) · troubleshooting table.

## 11. Phase Completion Gates

A phase is complete only when: all its ops pass their TESTING.md curl tests · the workspace UI flow works in the browser including chaining and undo · TESTING.md section written in Thai · KNOWN_ISSUES.md updated · README still deploys in ≤5 commands. Then STOP and wait for the user.
