import { Controller } from "@hotwired/stimulus";

// Tap a document page to zoom in on the spot tapped, tap again to fit — the
// app turns off pinch zoom, so a phone reading a statement needs this
// (the owner, 2026-10-17).
export default class extends Controller {
  static targets = ["frame"];

  toggle(event) {
    const image = event.currentTarget;
    const frame = image.closest("[data-page-zoom-target='frame']");
    const zoomed = image.dataset.zoomed === "true";

    if (zoomed) {
      image.dataset.zoomed = "false";
      image.style.width = "";
      image.classList.replace("cursor-zoom-out", "cursor-zoom-in");
      return;
    }

    const rect = image.getBoundingClientRect();
    const x = (event.clientX - rect.left) / rect.width;
    const y = (event.clientY - rect.top) / rect.height;
    image.dataset.zoomed = "true";
    image.style.width = "250%";
    image.classList.replace("cursor-zoom-in", "cursor-zoom-out");
    requestAnimationFrame(() => {
      frame.scrollLeft = x * image.offsetWidth - frame.clientWidth / 2;
      frame.scrollTop = y * image.offsetHeight - frame.clientHeight / 2;
    });
  }
}
