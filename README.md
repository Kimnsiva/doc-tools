# Doc-Tools

Self-hosted document utility suite (iLovePDF-style) for internal LAN use. Stateless — no database, no accounts, files auto-deleted shortly after processing.

**Currently implemented: Phase 1–4** — PDF Core (Merge, Split, Remove pages, Organize, Rotate, Compress, Repair, Crop), Convert (Office↔PDF, PDF↔Images, HTML→PDF), OCR (OCR, Scan-to-PDF, PDF→Word, PDF→Excel), and Security & Finishing (Protect, Unlock, Change Permissions, Watermark, Page Numbers, Add Stamp, Sign, Sign with Certificate, Flatten, Sanitize, PDF/A). See [plan.md](plan.md) for the full roadmap and [TESTING.md](TESTING.md) for the Thai-language manual test guide.

## Deploy (5 commands)

```bash
git clone <URL_REPO_ของคุณ> doc-tools
cd doc-tools
cp .env.example .env
docker compose up --build -d
# open http://<server-ip>:8080
```

## Configuration

Edit `.env` before starting (see `.env.example`):

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `8080` | Port exposed on the host |
| `MAX_FILE_SIZE_MB` | `100` | Reject uploads larger than this |
| `FILE_TTL_MINUTES` | `30` | Backstop cleanup age for temp files |
| `MAX_CONCURRENT_HEAVY_JOBS` | `2` | Concurrency limit for subprocess/async tools (compress, repair, OCR, office-convert, ...) |
| `MAX_CONCURRENT_LIGHT_JOBS` | `6` | Concurrency limit for in-process pikepdf tools |

## Update

```bash
git pull
docker compose up -d --build
```

## Known limitations

See [KNOWN_ISSUES.md](KNOWN_ISSUES.md).
