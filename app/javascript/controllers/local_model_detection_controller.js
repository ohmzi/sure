import { Controller } from "@hotwired/stimulus";

// Drives the "Local (self-hosted)" provider panel: a Detect button probes for an
// OpenAI-compatible server on the user's own hardware, fills the model picker
// from its response, and renders a recommendation for the OCR/document read.
//
// Detection is user-triggered on purpose: the Docker-to-host probe can hang (a
// host firewall may drop it), so it never runs on page load. Every branch
// renders a message instead of throwing - a "no server" answer is a normal
// outcome here.
export default class extends Controller {
  static targets = [
    "button",
    "select",
    "status",
    "recommendation",
    "baseUrlField",
    "manualField",
    "manualWrapper",
  ];
  static values = { url: String, persistUrl: String, strings: Object };

  connect() {
    this.locked = this.hasSelectTarget && this.selectTarget.disabled;
    this.#toggleManual();
  }

  async detect() {
    this.#setBusy(true);
    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this.#csrfToken(),
        },
        body: JSON.stringify({
          setting: {
            local_llm_base_url: this.hasBaseUrlFieldTarget
              ? this.baseUrlFieldTarget.value
              : "",
          },
        }),
      });
      await this.#handle(await response.json());
    } catch (error) {
      this.#setStatus(
        this.stringsValue?.error || "Could not check for local models.",
        "error",
      );
    } finally {
      this.#setBusy(false);
    }
  }

  // The picker's change handler: reconcile the manual fallback and refresh the
  // recommendation from the selected option (no server call). The auto-submit
  // controller persists the choice through the normal update path.
  syncManual() {
    this.#toggleManual();
    this.#recommendForSelection();
  }

  async #handle(payload) {
    switch (payload.status) {
      case "ok":
        await this.#applyModels(payload);
        break;
      case "empty":
        this.#setStatus(
          this.#fill(this.stringsValue.empty, { url: payload.base_url }),
          "error",
        );
        break;
      case "not_found":
        this.#setStatus(this.#notFoundMessage(payload.attempts), "error");
        break;
      default:
        this.#setStatus(payload.message || this.stringsValue.error, "error");
    }
  }

  async #applyModels(payload) {
    if (this.hasBaseUrlFieldTarget && payload.base_url) {
      this.baseUrlFieldTarget.value = payload.base_url;
    }

    if (this.hasSelectTarget) {
      const select = this.selectTarget;
      const models = Array.isArray(payload.models) ? payload.models : [];

      select.innerHTML = "";
      models.forEach((model) => {
        select.appendChild(this.#modelOption(model));
      });
      select.appendChild(this.#manualOption());

      // Pre-select the recommended model. With no recommendation, leave the
      // picker on the manual option rather than quietly selecting a text-only
      // model that cannot read documents.
      select.value = payload.recommended_model || "";
      if (!this.locked) select.disabled = false;
    }

    this.#renderRecommendation(payload);
    this.#toggleManual();

    // Persist the detected pick without a reload, so clicking Detect and walking
    // away still leaves a working Local configuration. On failure #persist
    // surfaces the error and we keep it.
    if (payload.recommended_model) {
      const saved = await this.#persist(
        payload.recommended_model,
        payload.base_url,
      );
      if (!saved) return;
    }

    const server = (payload.server || "").toString();
    this.#setStatus(
      this.#fill(this.stringsValue.found, { server, url: payload.base_url }),
      "ok",
    );
  }

  // Saves the detected model + base URL through the dedicated JSON endpoint
  // (keeps the detected list on screen; no full-page reload). Returns true on
  // success, false after surfacing a failure status.
  async #persist(model, baseUrl) {
    if (!this.hasPersistUrlValue) return true;

    try {
      const response = await fetch(this.persistUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this.#csrfToken(),
        },
        body: JSON.stringify({
          setting: {
            local_llm_model: model,
            local_llm_base_url: baseUrl || "",
          },
        }),
      });
      const payload = await response.json();
      if (payload.status === "ok") return true;

      this.#setStatus(payload.message || this.stringsValue.save_error, "error");
      return false;
    } catch (error) {
      this.#setStatus(this.stringsValue.save_error, "error");
      return false;
    }
  }

  #modelOption(model) {
    const option = document.createElement("option");
    option.value = model.id;
    option.textContent = model.label || model.id;
    option.dataset.suitability = model.suitability || "";
    option.dataset.recommended = model.recommended ? "true" : "false";
    return option;
  }

  #manualOption() {
    const option = document.createElement("option");
    option.value = "";
    option.textContent = this.stringsValue.manual || "";
    option.dataset.manual = "true";
    return option;
  }

  #renderRecommendation(payload) {
    if (payload.recommended_model) {
      const reason = payload.recommendation?.reason;
      this.#alert(
        "info",
        `${this.stringsValue.best_lead} ${payload.recommended_model}${reason ? ` - ${reason}` : ""}`,
      );
    } else {
      this.#alert("warning", this.stringsValue.none);
    }
  }

  #recommendForSelection() {
    if (!this.hasSelectTarget) return;
    const option = this.selectTarget.selectedOptions[0];
    if (!option) return;

    const id = option.value;
    const suitability = option.dataset.suitability || "";
    if (option.dataset.recommended === "true") {
      this.#alert(
        "info",
        `${this.stringsValue.best_lead} ${id}${suitability ? ` - ${suitability}` : ""}`,
      );
    } else if (id) {
      this.#alert(
        "info",
        this.#fill(this.stringsValue.selected, { model: id, suitability }),
      );
    } else {
      this.#alert("warning", this.stringsValue.none);
    }
  }

  #alert(variant, text) {
    if (!this.hasRecommendationTarget) return;

    this.recommendationTarget.innerHTML = "";
    const wrapper = document.createElement("div");
    wrapper.className =
      variant === "warning"
        ? "p-4 rounded-lg border bg-warning/10 border-warning/20"
        : "p-4 rounded-lg border bg-info/10 border-info/20";

    const paragraph = document.createElement("p");
    paragraph.className = "text-sm text-primary";
    paragraph.textContent = text || "";
    wrapper.appendChild(paragraph);
    this.recommendationTarget.appendChild(wrapper);
  }

  #toggleManual() {
    if (!this.hasSelectTarget) return;
    const manual = !this.locked && this.selectTarget.value === "";
    if (this.hasManualWrapperTarget) this.manualWrapperTarget.hidden = !manual;
    if (this.hasManualFieldTarget) this.manualFieldTarget.disabled = !manual;
  }

  #notFoundMessage(attempts) {
    const list = Array.isArray(attempts) ? attempts : [];
    if (list.length === 0) return this.stringsValue.not_found;

    const first = list[0];
    const cause =
      this.stringsValue[`cause_${first.outcome}`] ||
      this.stringsValue.cause_unknown;
    return `${this.stringsValue.not_found} ${first.url} - ${cause}`;
  }

  #setBusy(busy) {
    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = busy;
      this.buttonTarget.setAttribute("aria-busy", busy ? "true" : "false");
    }
    if (busy) this.#setStatus(this.stringsValue.busy || "...", "busy");
  }

  #setStatus(text, kind) {
    if (!this.hasStatusTarget) return;
    this.statusTarget.textContent = text || "";
    this.statusTarget.classList.toggle("text-destructive", kind === "error");
    this.statusTarget.classList.toggle("text-secondary", kind !== "error");
  }

  #fill(template, vars) {
    if (!template) return "";
    return template.replace(/%\{(\w+)\}/g, (match, key) =>
      vars[key] != null ? vars[key] : match,
    );
  }

  #csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || "";
  }
}
