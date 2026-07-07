# Doc-Tools — instructions for Claude

`plan.md` is the authoritative product spec. `TESTING.md` can drift — verify against
router/ops code before trusting it.

## View architecture (do not violate)

The app has exactly two full-screen display modes; the workspace (file cards +
horizontal thumbnail strip) is only a launchpad and preview:

- **GRID MODE** — only for Multi-Tool (many pages at once: reorder, rotate, delete,
  split). Implemented in `frontend/js/multitool.js` (`MultiTool.open(fileIds)`).
- **FULL-PAGE MODE** — for any tool that inspects or edits a single page's content
  (Crop, PDF Editor, and Redact today; future page-level tools). Implemented in
  `frontend/js/fullpage.js` (`FullPageViewer.open({fileId, version, renderSidebar, ...})`).
  One large pdf.js-rendered page, pagination top bar, tool options injected into the
  right sidebar via `renderSidebar(container)`. The PDF Editor (`frontend/js/pdfeditor.js`
  + `backend/ops/pdf_editor.py`) stores overlay elements in PDF points in the
  displayed-page frame; the backend maps them into user space with one matrix per
  /Rotate value (tested by `scripts/test_pdf_editor_coords.py`).

**Never show the small thumbnail strip as the working surface of a tool.** To make a
tool full-page, set `fullPage: true` on its entry in `frontend/js/tools.js`;
`selectTool()` in `workspace.js` routes it into the viewer and
`renderToolPanelInto()` renders its fields into the viewer sidebar.

## Architecture notes

- Frontend: vanilla JS, no build step, no CDN at runtime (LAN-safe). Third-party libs
  are vendored under `frontend/js/vendor/` (SortableJS, pdf.js).
- Backend: FastAPI; one generic endpoint `POST /api/ops/{tool}` dispatched via
  `TOOL_REGISTRY` (`backend/ops/*.py`, one module per tool). No per-tool endpoints.
- Files are `file_id` + versions (v1, v2, …); ops output `version`, `new_file`,
  `new_files`, or `download` (see `backend/ops/registry.py`).
- Docker: frontend is bind-mounted in `docker-compose.yml` for dev (refresh to see JS/CSS
  changes); backend changes need `docker compose up --build`.
