import { Controller } from "@hotwired/stimulus";

// The merchants donut's list follows a picked slice (the owner, 2026-10-18):
// the merchant list gives way to that merchant's latest transactions, loaded
// into a frame from the merchant row's own preview URL, with "All merchants"
// (donut-chart#reset) bringing the list back.
export default class extends Controller {
  static targets = ["list", "detail", "title"];

  select({ detail: { id } }) {
    const row = this.listTarget.querySelector(
      `[data-category-id="${CSS.escape(id)}"][data-preview-url]`,
    );
    if (!row) return;

    const frame = this.detailTarget.querySelector("turbo-frame");
    frame.src = row.dataset.previewUrl;
    if (this.hasTitleTarget)
      this.titleTarget.textContent = row.dataset.previewTitle;
    this.listTarget.hidden = true;
    this.detailTarget.hidden = false;
  }

  clear() {
    this.listTarget.hidden = false;
    this.detailTarget.hidden = true;
  }
}
