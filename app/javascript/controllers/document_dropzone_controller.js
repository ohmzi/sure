import { Controller } from "@hotwired/stimulus";

// Anywhere on this page is a drop target (design: "slim bar, drop anywhere").
// A drop posts each file to the ONE intake endpoint; the server answers with a
// tile, so the document is visible before the upload's own request has finished
// settling. No wizard, no navigation, no second screen.
export default class extends Controller {
  static targets = ["status", "currency"];
  // `dropAnywhere` off keeps the page itself from catching drops (Home only
  // hosts the Add sheet); `notify` asks the server to confirm with a toast,
  // for a page with no grid to show the new tile in.
  static values = {
    url: String,
    failure: { type: String, default: "" },
    dropAnywhere: { type: Boolean, default: true },
    notify: { type: Boolean, default: false },
  };

  connect() {
    if (!this.dropAnywhereValue) return;
    this.onDragOver = (event) => this.showOverlay(event);
    this.onDragLeave = (event) => this.maybeHideOverlay(event);
    this.onDrop = (event) => this.drop(event);
    document.addEventListener("dragover", this.onDragOver);
    document.addEventListener("dragleave", this.onDragLeave);
    document.addEventListener("drop", this.onDrop);
  }

  disconnect() {
    if (!this.onDragOver) return;
    document.removeEventListener("dragover", this.onDragOver);
    document.removeEventListener("dragleave", this.onDragLeave);
    document.removeEventListener("drop", this.onDrop);
  }

  pick(event) {
    // Each Add sheet row is the label of a hidden file input; a chosen file
    // takes the same path a dropped one does. The sheet then slides away, and
    // the input is cleared so the same file can be picked again.
    event.preventDefault();
    const input = event.target;
    this.upload(input.files);
    input.value = "";
    input.closest("dialog")?.dispatchEvent(new CustomEvent("sheet:close"));
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
      // The currency chosen on the bar (a receipt or bill's money); the server
      // keeps it only when it is a real code.
      if (this.hasCurrencyTarget)
        body.append("currency", this.currencyTarget.value);
      if (this.notifyValue) body.append("notify", "1");
      fetch(this.urlValue, {
        method: "POST",
        body,
        headers: {
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")
            ?.content,
          Accept: "text/vnd.turbo-stream.html",
        },
      })
        .then((response) => {
          // A CSV or OFX drop answers with a redirect to the screen that can
          // read it. `fetch` follows it as a GET, which never yields a
          // turbo-stream body, so it must be handed to Turbo as a navigation
          // instead — otherwise a successful import reports itself as a failure.
          if (response.redirected) {
            window.Turbo.visit(response.url);
            return;
          }
          return this.respond(response);
        })
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
