import { Controller } from "@hotwired/stimulus";

// Dropzone for the documents archive AND the wizard's quick-intake screen (M8
// Task 9 reuses this controller — the wizard's copy is not a fork): a dropped
// file is funneled into the hidden file input and submitted; a chosen file
// (the camera row, the drop zone's picker) submits the same form on `change`,
// so no Continue button is needed. The sha256-first duplicate warning is
// enforced server-side in DocumentLink::Intake (spec §8.1) — the digest is
// computed and checked BEFORE any row or paperless post — so a duplicate is
// never silently re-added regardless of how the file arrives.
export default class extends Controller {
  static targets = ["input", "form"];

  dragover(event) {
    event.preventDefault();
  }

  drop(event) {
    event.preventDefault();
    // Ruling 6 (M1): exactly ONE file. The input is single-file and the server
    // expects one file param — handing it a multi-entry FileList turns the
    // param into an Array and 500s the upload. This holds on the heic-ok
    // branch too (no conversion, but still funnel only the first file).
    const file = event.dataTransfer.files[0];
    if (!file) return;
    const dt = new DataTransfer();
    dt.items.add(file);
    this.inputTarget.files = dt.files;
    this.formTarget.requestSubmit();
  }

  // A file chosen through either row (the camera input or the drop zone's
  // input) submits instantly — the wizard's whole "quick" contract.
  change() {
    this.formTarget.requestSubmit();
  }
}
