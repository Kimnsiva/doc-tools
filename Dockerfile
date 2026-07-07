# Phase 1: pikepdf (in-process) + ghostscript (compress) + qpdf (repair) + poppler-utils (pdftoppm/pdfinfo)
# Phase 2: libreoffice (office-to-pdf) + weasyprint's Pango/cairo/gdk-pixbuf runtime libs (html-to-pdf)
# Phase 3: tesseract + language packs (ocr) + unpaper (ocrmypdf --clean, scan_to_pdf) + imagemagick
#          (scan_to_pdf's `convert`) + Noto Thai/CJK fonts (renders Thai/Japanese test fixtures + watermark)
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ghostscript \
    qpdf \
    poppler-utils \
    curl \
    libreoffice \
    fonts-dejavu-core \
    libpango-1.0-0 \
    libpangoft2-1.0-0 \
    libpangocairo-1.0-0 \
    libcairo2 \
    libgdk-pixbuf-2.0-0 \
    shared-mime-info \
    tesseract-ocr \
    tesseract-ocr-tha \
    tesseract-ocr-jpn \
    tesseract-ocr-jpn-vert \
    tesseract-ocr-eng \
    unpaper \
    imagemagick \
    libgomp1 \
    fonts-noto-cjk \
    fonts-thai-tlwg \
    fonts-vlgothic \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY backend/requirements.txt backend/requirements.txt
RUN pip install --no-cache-dir -r backend/requirements.txt

COPY backend ./backend
COPY frontend ./frontend
COPY scripts ./scripts

ENV PYTHONUNBUFFERED=1
WORKDIR /app/backend
EXPOSE 8080

CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT:-8080}"]
