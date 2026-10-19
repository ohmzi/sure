// When a finger on a chart means "scrub" rather than "scroll the page" (the
// owner, 2026-10-18: press and hold should feel clean). A touch scrubs once
// it is held still for a moment or moves sideways; one that moves up or down
// first is a scroll, and shows nothing — readings used to flash as a page
// scroll began over a chart. A mouse scrubs at once.
//
//   const intent = scrubIntent({ onStart: (event) => show(event) });
//   pointerdown: if (intent.down(event)) show(event);
//   pointermove: if (intent.move(event)) show(event);
//   pointerup / pointercancel / pointerleave: intent.end(); hide();
export function scrubIntent({ onStart, holdMs = 120, slop = 6 } = {}) {
  let start = null;
  let active = false;
  let timer = null;
  let last = null;

  return {
    get active() {
      return active;
    },

    down(event) {
      if (event.pointerType === "mouse") {
        active = true;
        return true;
      }
      clearTimeout(timer);
      start = { x: event.clientX, y: event.clientY };
      last = event;
      active = false;
      timer = setTimeout(() => {
        if (!start) return;
        active = true;
        onStart?.(last);
      }, holdMs);
      return false;
    },

    move(event) {
      last = event;
      if (active || event.pointerType === "mouse") return true;
      if (!start) return false;

      const dx = Math.abs(event.clientX - start.x);
      const dy = Math.abs(event.clientY - start.y);
      if (dx > slop && dx > dy) {
        clearTimeout(timer);
        active = true;
        return true;
      }
      if (dy > slop) {
        clearTimeout(timer);
        start = null;
      }
      return false;
    },

    end() {
      clearTimeout(timer);
      start = null;
      const was = active;
      active = false;
      return was;
    },
  };
}
