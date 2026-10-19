import { Controller } from "@hotwired/stimulus";

// A donut widget's list follows a picked slice (the owner, 2026-10-18): the
// list gives way to the slice's latest transactions, loaded into a frame
// from its row's preview URL, under a chip naming the slice in its colour.
// The chip's ✕ (donut-chart#reset), or picking the slice again, brings the
// list back. Used by the merchants and card charges widgets.
export default class extends Controller {
  static targets = ["list", "detail", "title", "swatch"];

  select({ detail: { id } }) {
    const row = this.listTarget.querySelector(
      `[data-category-id="${CSS.escape(id)}"][data-preview-url]`,
    );
    if (!row) return;

    const frame = this.detailTarget.querySelector("turbo-frame");
    frame.src = row.dataset.previewUrl;
    this.titleTarget.textContent = row.dataset.previewTitle;
    this.swatchTarget.style.backgroundColor = row.dataset.previewColor || "";
    this.listTarget.hidden = true;
    this.detailTarget.hidden = false;
  }

  clear() {
    this.listTarget.hidden = false;
    this.detailTarget.hidden = true;
  }
}
