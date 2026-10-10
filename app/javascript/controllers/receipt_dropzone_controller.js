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
    if (event.dataTransfer.files.length) {
      this.inputTarget.files = event.dataTransfer.files;
      this.formTarget.requestSubmit();
    }
  }
}
