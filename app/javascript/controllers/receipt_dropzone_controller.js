import { Controller } from "@hotwired/stimulus";

// Dropzone for the documents archive: a dropped file is funneled into the
// hidden file input and submitted. The sha256-first duplicate warning is
// enforced server-side in DocumentLinksController#create (spec §8.1) — the
// digest is computed and checked BEFORE any row or paperless post — so a
// duplicate is never silently re-added regardless of how the file arrives.
export default class extends Controller {
  static targets = ["input", "form"];

  dragover(event) {
    event.preventDefault();
  }

  drop(event) {
    event.preventDefault();
    // Ruling 6 (M1): exactly ONE file. The input is single-file and the server
    // expects one `document` param — handing it a multi-entry FileList makes
    // params.require(:document) an Array and 500s the upload. This holds on the
    // heic-ok branch too (no conversion, but still funnel only the first file).
    const file = event.dataTransfer.files[0];
    if (!file) return;
    const dt = new DataTransfer();
    dt.items.add(file);
    this.inputTarget.files = dt.files;
    this.formTarget.requestSubmit();
  }
}
