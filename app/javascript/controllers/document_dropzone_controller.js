import { Controller } from "@hotwired/stimulus";

// Anywhere on this page is a drop target (design: "slim bar, drop anywhere").
// A drop posts each file to the ONE intake endpoint; the server answers with a
// tile, so the document is visible before the upload's own request has finished
// settling. No wizard, no navigation, no second screen.
export default class extends Controller {
  static targets = ["status"];
  static values = { url: String, failure: { type: String, default: "" } };

  connect() {
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
        .then((response) => this.respond(response))
        .catch(() => this.reportFailure());
    }
  }

  // A refused upload is answered with a turbo-stream too (a 422 whose body
  // writes the reason into the bar), so any stream response is rendered
  // whatever its status. Anything else — a 500, a lost connection — is thrown
  // so the catch can put it on the bar rather than swallow it.
  respond(response) {
    const contentType = response.headers.get("Content-Type") || "";
    if (!contentType.includes("turbo-stream"))
      throw new Error(`upload failed: ${response.status}`);
    return response
      .text()
      .then((html) => window.Turbo.renderStreamMessage(html));
  }

  reportFailure() {
    if (this.hasStatusTarget && this.failureValue)
      this.statusTarget.textContent = this.failureValue;
  }
}
