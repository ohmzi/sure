"""The OCR sidecar: bytes in, per-page text and boxes out.

One warm process. PaddleOCR's model load dominates a cold start, so the service
is long-lived and the Rails app calls it over HTTP rather than spawning a
process per document.
"""
import base64
import io
import os

import numpy as np
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from paddleocr import PaddleOCR
from pdf2image import convert_from_bytes
from PIL import Image, ImageOps

DPI = int(os.environ.get("OCR_DPI", "300"))
MAX_PAGES = int(os.environ.get("OCR_MAX_PAGES", "60"))
LANG = os.environ.get("OCR_LANG", "en").split(",")[0].strip() or "en"

# A page this small on either side cannot hold a legible line of text. PaddleOCR's
# unwarping stage raises on such degenerate inputs ("axes don't match array"), and
# an unhandled raise is a retryable 500 — but a page that is simply too small is a
# permanent property of the document, so it must take the 422 "unreadable" path.
MIN_SIDE = 32

app = FastAPI(title="ohmzbudget-ocr")
_engine = None


def engine():
    """Loaded once, on first use, so a container that never sees a document
    never pays for the weights."""
    global _engine
    if _engine is None:
        # PaddleOCR 3.x renamed the 2.x `use_angle_cls` switch to
        # `use_textline_orientation` (the old name survives only as a deprecated
        # alias) and dropped `show_log` entirely — passing it raises "Unknown
        # argument". Same behaviour, so the angle classifier still runs.
        _engine = PaddleOCR(use_textline_orientation=True, lang=LANG)
    return _engine


def render(data: bytes, filename: str):
    """PDF -> page images (bounded); image -> a single normalised page.

    Raises for anything the engine cannot be asked about; the caller turns that
    into 422 (unreadable), never a retryable 5xx."""
    if filename.lower().endswith(".pdf") or data[:4] == b"%PDF":
        # `last_page` hands the bound to the rasteriser. Slicing a full render
        # afterwards would rasterise EVERY page into memory first (~26 MB/page at
        # 300 DPI) and can exhaust the container on a runaway PDF — exactly what
        # MAX_PAGES exists to prevent.
        pages = convert_from_bytes(data, dpi=DPI, fmt="png", last_page=MAX_PAGES)
    else:
        # EXIF orientation FIRST: a phone photo is routinely stored rotated, and
        # an unrotated page is exactly the failure this service exists to fix.
        pages = [ImageOps.exif_transpose(Image.open(io.BytesIO(data))).convert("RGB")]

    for page in pages:
        if min(page.size) < MIN_SIDE:
            raise ValueError(f"degenerate page {page.size}")

    return pages


def ocr_page(image):
    # PaddleOCR 3.x (the pinned 3.0.0) dropped the 2.x nested-list return shape:
    # predict() now yields result objects that behave like mappings, carrying
    # rec_texts / rec_scores and rec_polys (one 4-point polygon per recognised
    # line). We fold each polygon to the axis-aligned [x0, y0, x1, y1] the 2.x
    # shape produced, so the HTTP contract above this function is unchanged.
    results = engine().predict(np.array(image)) or []

    boxes = []
    for result in results:
        texts = result["rec_texts"] or []
        scores = result["rec_scores"] or []
        polys = result["rec_polys"] or []
        for text, confidence, poly in zip(texts, scores, polys):
            points = np.asarray(poly).reshape(-1, 2)
            xs = points[:, 0]
            ys = points[:, 1]
            boxes.append({
                "text": text,
                "bbox": [float(xs.min()), float(ys.min()), float(xs.max()), float(ys.max())],
                "confidence": float(confidence),
            })

    text = "\n".join(b["text"] for b in boxes)
    confidence = sum(b["confidence"] for b in boxes) / len(boxes) if boxes else 0.0
    return {"text": text, "confidence": confidence, "boxes": boxes}


@app.get("/healthz")
def healthz():
    return {"ok": True, "engine": "paddleocr", "lang": LANG}


def encode_page(image):
    """The page as a base64 PNG. The vision call reads the SAME rendering the
    OCR did — that is the whole reason this service owns rasterisation."""
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return base64.b64encode(buffer.getvalue()).decode("ascii")


@app.post("/ocr")
def ocr(file: UploadFile = File(...), include_images: bool = Form(False)):
    # Plain `def`, not `async def`: the body is fully synchronous (poppler
    # subprocess + a GPU model that can take tens of seconds per page). Under
    # `--workers 1` an async handler blocks the event loop, so /healthz could not
    # answer during an OCR and the healthcheck's 5s timeout would restart the
    # container mid-document. FastAPI runs a plain `def` in its threadpool.
    data = file.file.read()
    if not data:
        raise HTTPException(status_code=422, detail="empty upload")

    try:
        images = render(data, file.filename or "")
    except Exception:
        # A malformed PDF or an image PIL cannot open is an unreadable input,
        # not a server fault — the app must be able to tell the two apart.
        raise HTTPException(status_code=422, detail="unreadable")

    pages = []
    for index, image in enumerate(images, start=1):
        page = {"page": index, **ocr_page(image)}
        if include_images:
            page["image"] = encode_page(image)
        pages.append(page)

    # A page that rendered but yielded no recognised text is a NORMAL page with
    # `text: ""`, never a 422: the vision model reads the page IMAGE precisely
    # when the OCR is poor, and a photographed page with no glyphs is the
    # canonical case. Only a document the service could not render at all is
    # unreadable (the `render` raise above).
    return {"engine": "paddleocr", "pages": pages}
