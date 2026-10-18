import { Controller } from "@hotwired/stimulus";

// A small date-range helper for the transaction filter. Native date fields keep
// the platform calendar (including its Today button); this controller only adds
// the two conveniences the filter needs:
//
//   * picking a start date fills an empty/earlier end date with it and opens the
//     end calendar on the same month, so the range is one gesture;
//   * Today and Clear dates apply immediately instead of making the user hunt
//     for Apply.
export default class extends Controller {
  static targets = ["start", "end"];

  startChanged() {
    if (!this.startTarget.value) return;

    if (
      !this.endTarget.value ||
      this.endTarget.value < this.startTarget.value
    ) {
      this.endTarget.value = this.startTarget.value;
    }

    // Defer so the start field's native change event finishes first. The end
    // field now carries the same month, which is where showPicker opens.
    requestAnimationFrame(() => {
      try {
        this.endTarget.showPicker?.();
      } catch {
        // Older browsers have no picker API; the filled end date is still there.
      }
    });
  }

  today() {
    const today = this.#todayIso();
    this.startTarget.value = today;
    this.endTarget.value = today;
    this.#submit();
  }

  clear() {
    this.startTarget.value = "";
    this.endTarget.value = "";
    this.#submit();
  }

  #submit() {
    this.element.closest("form")?.requestSubmit();
  }

  #todayIso() {
    const now = new Date();
    const local = new Date(now.getTime() - now.getTimezoneOffset() * 60_000);
    return local.toISOString().slice(0, 10);
  }
}
