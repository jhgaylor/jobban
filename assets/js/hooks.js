import Sortable from "../vendor/sortable.esm"
import confetti from "../vendor/confetti.mjs"

// Drag-and-drop for a kanban column. The element is the <ul> of cards;
// columns share the "board" group so cards can move between stages.
export const BoardColumn = {
  mounted() {
    this.sortable = new Sortable(this.el, {
      group: "board",
      animation: 200,
      easing: "cubic-bezier(0.22, 1, 0.36, 1)",
      delay: 60,
      delayOnTouchOnly: true,
      forceFallback: true,
      fallbackOnBody: true,
      fallbackClass: "drag-dragging",
      ghostClass: "drag-ghost",
      chosenClass: "drag-chosen",
      dragClass: "drag-dragging",
      onStart: () => document.body.classList.add("is-dragging"),
      onEnd: (evt) => {
        document.body.classList.remove("is-dragging")
        if (evt.from === evt.to && evt.oldIndex === evt.newIndex) return
        this.pushEvent("move_job", {
          id: evt.item.dataset.jobId,
          stage_id: evt.to.dataset.stageId,
          index: evt.newIndex,
        })
      },
    })
  },
  destroyed() {
    this.sortable?.destroy()
  },
}

// Fires a two-cannon confetti volley when the server pushes "celebrate"
// (a card landed in the Offer column).
export const Celebrate = {
  mounted() {
    this.handleEvent("celebrate", () => {
      const fire = (x, angle) =>
        confetti({
          particleCount: 90,
          spread: 70,
          startVelocity: 55,
          origin: { x, y: 0.9 },
          angle,
          colors: ["#a78bfa", "#34d399", "#fbbf24", "#60a5fa", "#f472b6"],
        })
      fire(0.1, 60)
      fire(0.9, 120)
      setTimeout(() => fire(0.5, 90), 250)
    })
  },
}

export const AutoFocus = {
  mounted() {
    this.el.focus()
  },
}

// Cmd/Ctrl+Enter submits the surrounding form — newlines stay newlines.
export const SubmitOnMetaEnter = {
  mounted() {
    this.el.addEventListener("keydown", (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault()
        this.el.form.requestSubmit()
      }
    })
  },
}

// Clears info flashes after a beat (clicking a flash dismisses it).
export const AutoDismiss = {
  mounted() {
    this.timer = setTimeout(() => this.el.click(), 2500)
  },
  destroyed() {
    clearTimeout(this.timer)
  },
}
