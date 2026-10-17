import { Controller } from "@hotwired/stimulus";

// A document's pages as one continuous sheet (the owner, 2026-10-17). Tap to
// zoom in on the spot tapped, tap again to fit — the app turns off pinch zoom,
// so a phone reading a statement needs this. Opened from a transaction, the
// sheet starts at that transaction's marked line.
export default class extends Controller {
  static targets = ["scroller", "sheet", "mark"];

  connect() {
    this.moved = false;
    this.stopFollowing = () => {
      this.moved = true;
    };
    if (this.hasScrollerTarget) {
      this.scrollerTarget.addEventListener("touchstart", this.stopFollowing, { passive: true });
      this.scrollerTarget.addEventListener("wheel", this.stopFollowing, { passive: true });
    }
    this.settle();
  }

  disconnect() {
    if (!this.hasScrollerTarget) return;

    this.scrollerTarget.removeEventListener("touchstart", this.stopFollowing);
    this.scrollerTarget.removeEventListener("wheel", this.stopFollowing);
  }

  // Pages above the mark change height as their pictures load; keep the mark
  // in view until the reader scrolls on their own.
  settle() {
    if (!this.moved) this.centreMark("auto");
  }

  reveal() {
    this.moved = false;
    this.scrollerTarget.scrollIntoView({ behavior: "smooth", block: "nearest" });
    this.centreMark("smooth");
  }

  toggle(event) {
    if (!this.hasSheetTarget) return;

    const sheet = this.sheetTarget;
    const scroller = this.scrollerTarget;
    this.moved = true;

    if (sheet.dataset.zoomed === "true") {
      sheet.dataset.zoomed = "false";
      sheet.style.width = "";
      this.cursor("cursor-zoom-out", "cursor-zoom-in");
      return;
    }

    const rect = sheet.getBoundingClientRect();
    const x = (event.clientX - rect.left) / rect.width;
    const y = (event.clientY - rect.top) / rect.height;
    sheet.dataset.zoomed = "true";
    sheet.style.width = "250%";
    this.cursor("cursor-zoom-in", "cursor-zoom-out");
    requestAnimationFrame(() => {
      scroller.scrollLeft = x * sheet.offsetWidth - scroller.clientWidth / 2;
      scroller.scrollTop = y * sheet.offsetHeight - scroller.clientHeight / 2;
    });
  }

  centreMark(behavior) {
    if (!this.hasMarkTarget || !this.hasScrollerTarget) return;

    const scroller = this.scrollerTarget;
    const mark = this.markTarget.getBoundingClientRect();
    const frame = scroller.getBoundingClientRect();
    const top = scroller.scrollTop + mark.top - frame.top - (scroller.clientHeight - mark.height) / 2;
    scroller.scrollTo({ top: Math.max(0, top), behavior });
  }

  cursor(from, to) {
    for (const image of this.sheetTarget.querySelectorAll("img")) {
      image.classList.replace(from, to);
    }
  }
}
