# OCR sidecar

A small FastAPI service wrapping [PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR).
It is the one place document bytes become per-page text, boxes, and rendered page
images. The Rails app talks to it over HTTP through `Ocr::Client`; nothing else
does.

It exists because paperless-ngx did this with Tesseract, badly, on exactly the
photographed and scanned pages this feature is for. Keeping the engine behind a
tiny HTTP contract means it can be swapped without the app noticing.

## Contract

### `POST /ocr`

`multipart/form-data` with two fields:

| field | value |
| --- | --- |
| `file` | the document bytes |
| `include_images` | the string `"true"` or `"false"` |

`include_images` is a string on the wire (that is what the Faraday client
sends). It is parsed by FastAPI's pydantic-backed `Form(bool)`, so `"false"`
means false — never Python's `bool("false")`, which is `True`.

Success (`200`) returns:

```json
{
  "engine": "paddleocr",
  "pages": [
    {
      "page": 1,
      "text": "the recognised text",
      "confidence": 0.97,
      "boxes": [
        { "text": "the recognised text", "bbox": [x0, y0, x1, y1], "confidence": 0.97 }
      ],
      "image": "<base64 png>"
    }
  ]
}
```

`image` is present **only** when `include_images` was truthy. The `bbox` is the
axis-aligned `[x0, y0, x1, y1]` of each recognised line.

A PDF is rasterised page by page (bounded by `OCR_MAX_PAGES`); an image is
normalised to a single page, honouring its EXIF orientation.

### `GET /healthz`

```json
{ "ok": true, "engine": "paddleocr", "lang": "en" }
```

### Status codes

- `200` — success.
- `422` — an input with no detectable text, or a file that cannot be opened
  (a malformed PDF, a corrupt image, an empty upload). This is a *normal*
  outcome the app must be able to see, not a server fault.
- `5xx` — a retryable fault.

## Configuration

| env var | default | meaning |
| --- | --- | --- |
| `OCR_LANG` | `en` | PaddleOCR language. A comma-separated list is accepted; the first entry wins. |
| `OCR_DPI` | `300` | Rasterisation DPI for PDFs. |
| `OCR_MAX_PAGES` | `60` | Upper bound on pages rendered from one PDF, so a runaway document cannot exhaust the container. |

## Internal only

The service has **no `ports:` block** in `deploy/compose.yml`. It is reachable
only on the compose-internal network, exactly like the paperless services it
replaces. The app reaches it at `OCR_SERVICE_URL` (default `http://ocr:9000`).

## Logs

It logs to stdout, so read them through compose:

```bash
cd deploy && docker compose logs -f ocr
```

The first request after a start loads the model; the weights are baked into the
image at build time, so that is a load, not a download.
