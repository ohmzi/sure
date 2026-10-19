// A part of a page that could not load (the owner, 2026-10-19: mid-deploy the
// server restarts, and Turbo left a bare "Content missing" with no way on).
//
// - A frame whose request failed outright, or whose answer was an error page,
//   shows the #frame-load-error card: Try again reloads just that frame,
//   Reload page the whole page.
// - A frame answered with a working page that lacks it — the sign-in page
//   after a session ends, say — goes to that page instead.
// A frame's own turbo:frame-missing handler that calls preventDefault (the
// category quick-create picker) keeps the case to itself.

function showFrameError(frame) {
  const template = document.getElementById("frame-load-error");
  if (!template || !frame) return;

  const card = template.content.firstElementChild.cloneNode(true);
  card.querySelector("[data-frame-retry]")?.addEventListener("click", () => {
    if (frame.src) {
      frame.reload();
    } else {
      window.location.reload();
    }
  });
  card
    .querySelector("[data-frame-reload-page]")
    ?.addEventListener("click", () => window.location.reload());

  frame.replaceChildren(card);
  frame.removeAttribute("aria-busy");
  frame.removeAttribute("busy");
}

function frameFor(target) {
  if (!(target instanceof Element)) return null;
  if (target.tagName === "TURBO-FRAME") return target;

  const id = target.dataset.turboFrame;
  if (id === "_top") return null;
  if (id) return document.getElementById(id);
  const frame = target.closest("turbo-frame");
  return frame && frame.getAttribute("target") !== "_top" ? frame : null;
}

export function handleFrameErrors() {
  document.addEventListener("turbo:frame-missing", (event) => {
    if (event.defaultPrevented) return;
    const { response, visit } = event.detail;
    event.preventDefault();
    if (response.ok) {
      visit(response);
    } else {
      showFrameError(event.target);
    }
  });

  // A frame's own load fails on the frame; a form or link aimed at a frame
  // fails on itself, so follow it to the frame it fills.
  document.addEventListener("turbo:fetch-request-error", (event) => {
    showFrameError(frameFor(event.target));
  });
}
