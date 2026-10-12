import { Controller } from "@hotwired/stimulus";

// Anywhere on this page is a drop target (design: "slim bar, drop anywhere").
// A drop posts each file to the ONE intake endpoint; the server answers with a
// tile, so the document is visible before the upload's own request has finished
// settling. No wizard, no navigation, no second screen.
export default class extends Controller {
  static targets = ["status"];
  static values = { url: String };

  connect() {
    this.dragging = false;
    this.onDragOver = (event) => this.showOverlay(event);
    this.onDragLeave = (event) => this.maybeHideOverlay(event);
    this.onDrop = (event) => this.drop(event);
    document.addEventListener("dragover", this.onDragOver);
    document.addEventListener("dragleave", this.onDragLeave);
    document.addEventListener("drop", this.onDrop);
  }

  disconnect() {
    document.removeEventListener("dragover", this.onDragOver);
    document.removeEventListener("dragleave", this.onDragLeave);
    document.removeEventListener("drop", this.onDrop);
  }

  pick(event) {
    // The bar's button is a label for a hidden file input; a chosen file takes
    // the same path a dropped one does.
    event.preventDefault();
    this.upload(event.target.files);
  }

  showOverlay(event) {
    if (!event.dataTransfer?.types?.includes("Files")) return;
    event.preventDefault();
    this.element.classList.add("drop-active");
  }

  maybeHideOverlay(event) {
    if (event.relatedTarget === null)
      this.element.classList.remove("drop-active");
  }

  drop(event) {
    const files = Array.from(event.dataTransfer?.files ?? []);
    if (files.length === 0) return;
    event.preventDefault();
    this.element.classList.remove("drop-active");
    this.upload(files);
  }

  upload(files) {
    for (const file of files) {
      const body = new FormData();
      body.append("document", file);
      fetch(this.urlValue, {
        method: "POST",
        body,
        headers: {
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")
            ?.content,
          Accept: "text/vnd.turbo-stream.html",
        },
      })
        .then((response) => response.text())
        .then((html) => window.Turbo.renderStreamMessage(html));
    }
  }
}
