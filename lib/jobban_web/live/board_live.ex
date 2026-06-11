defmodule JobbanWeb.BoardLive do
  use JobbanWeb, :live_view

  alias Jobban.Board
  alias Jobban.Board.Job

  @sources ["LinkedIn", "Referral", "Company site", "Recruiter", "Hacker News", "Job board", "Other"]

  @stage_styles %{
    "wishlist" => %{dot: "bg-violet-400", glow: "shadow-violet-500/20", count: "text-violet-400"},
    "applied" => %{dot: "bg-sky-400", glow: "shadow-sky-500/20", count: "text-sky-400"},
    "interviewing" => %{dot: "bg-amber-400", glow: "shadow-amber-500/20", count: "text-amber-400"},
    "offer" => %{dot: "bg-emerald-400", glow: "shadow-emerald-500/20", count: "text-emerald-400"},
    "rejected" => %{dot: "bg-rose-400/70", glow: "shadow-rose-500/10", count: "text-rose-400/80"}
  }
  @default_style %{dot: "bg-zinc-400", glow: "shadow-zinc-500/20", count: "text-zinc-400"}

  @avatar_gradients [
    "from-violet-500 to-fuchsia-500",
    "from-sky-500 to-cyan-400",
    "from-emerald-500 to-lime-400",
    "from-amber-500 to-orange-500",
    "from-rose-500 to-pink-500",
    "from-indigo-500 to-blue-500",
    "from-teal-500 to-emerald-400",
    "from-fuchsia-500 to-rose-400"
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Board.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Board", quick_add: nil, quick_add_seq: 0, selected_job: nil, form: nil)
     |> assign_board()}
  end

  @impl true
  def handle_info({:board_changed}, socket) do
    socket = assign_board(socket)

    socket =
      case socket.assigns.selected_job do
        nil ->
          socket

        %Job{id: id} ->
          case Board.get_job(id) do
            nil -> assign(socket, selected_job: nil, form: nil)
            job -> assign(socket, selected_job: job)
          end
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("move_job", %{"id" => id, "stage_id" => stage_id, "index" => index}, socket) do
    case Board.get_job(to_int(id)) do
      nil ->
        {:noreply, socket}

      job ->
        to_stage = Board.get_stage!(to_int(stage_id))
        entered_offer? = job.stage_id != to_stage.id and to_stage.slug == "offer"
        {:ok, _job} = Board.move_job(job, to_stage.id, to_int(index))

        socket = if entered_offer?, do: push_event(socket, "celebrate", %{}), else: socket
        {:noreply, socket}
    end
  end

  def handle_event("open_quick_add", %{"stage-id" => stage_id}, socket) do
    {:noreply, assign(socket, quick_add: to_int(stage_id))}
  end

  def handle_event("cancel_quick_add", _params, socket) do
    {:noreply, assign(socket, quick_add: nil)}
  end

  def handle_event("create_job", %{"job" => params}, socket) do
    case Board.create_job(params) do
      {:ok, _job} ->
        {:noreply, update(socket, :quick_add_seq, &(&1 + 1))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Company and role title are required")}
    end
  end

  def handle_event("open_job", %{"id" => id}, socket) do
    case Board.get_job(to_int(id)) do
      nil -> {:noreply, socket}
      job -> {:noreply, assign(socket, selected_job: job, form: to_form(Board.change_job(job)))}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, selected_job: nil, form: nil)}
  end

  def handle_event("validate_job", %{"job" => params}, socket) do
    form =
      socket.assigns.selected_job
      |> Board.change_job(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save_job", %{"job" => params}, socket) do
    case Board.update_job(socket.assigns.selected_job, params) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(selected_job: nil, form: nil)
         |> put_flash(:info, "Saved")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("delete_job", _params, socket) do
    {:ok, _} = Board.delete_job(socket.assigns.selected_job)
    {:noreply, assign(socket, selected_job: nil, form: nil)}
  end

  def handle_event("add_note", %{"note" => %{"body" => body}}, socket) do
    if String.trim(body) != "" do
      {:ok, _} = Board.add_note(socket.assigns.selected_job, body)
    end

    {:noreply, socket}
  end

  defp assign_board(socket) do
    assign(socket, stages: Board.list_stages(), stats: Board.stats())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="board-root" phx-hook="Celebrate" class="h-dvh flex flex-col bg-board overflow-hidden">
      <header class="flex items-center gap-4 px-4 sm:px-6 pt-4 pb-3 shrink-0">
        <div class="flex items-center gap-3 min-w-0">
          <div class="grid place-items-center size-10 rounded-xl bg-gradient-to-br from-violet-500 to-fuchsia-500 shadow-lg shadow-violet-500/30">
            <.icon name="hero-briefcase" class="size-5 text-white" />
          </div>
          <div class="min-w-0">
            <h1 class="text-xl font-bold tracking-tight leading-none">jobban</h1>
            <p class="text-xs opacity-50 mt-1 truncate">wishlist → offer, one drag at a time</p>
          </div>
        </div>
        <div class="ml-auto flex items-center gap-2 sm:gap-3">
          <div class="hidden md:flex items-center gap-2">
            <.stat_pill value={@stats.total} label="tracked" />
            <.stat_pill value={@stats.in_flight} label="in flight" />
            <.stat_pill value={@stats.interviewing} label="interviewing" />
            <.stat_pill value={@stats.offers} label={if @stats.offers == 1, do: "offer 🎉", else: "offers"} />
          </div>
          <Layouts.theme_toggle />
        </div>
      </header>

      <main class="flex-1 overflow-x-auto overflow-y-hidden px-4 sm:px-6 pb-4">
        <div class="flex gap-4 h-full min-w-max">
          <.stage_column
            :for={stage <- @stages}
            stage={stage}
            quick_add={@quick_add}
            quick_add_seq={@quick_add_seq}
          />
        </div>
      </main>

      <.job_modal :if={@selected_job} job={@selected_job} form={@form} />
      <Layouts.flash_group flash={@flash} />
    </div>
    """
  end

  attr :stage, :map, required: true
  attr :quick_add, :integer, default: nil
  attr :quick_add_seq, :integer, default: 0

  defp stage_column(assigns) do
    assigns = assign(assigns, :style, stage_style(assigns.stage.slug))

    ~H"""
    <section class="w-[19rem] xl:w-80 flex flex-col rounded-2xl bg-base-200/70 backdrop-blur border border-base-content/5 shadow-xl shadow-black/5 min-h-0">
      <header class="flex items-center gap-2.5 px-4 pt-3.5 pb-2.5 shrink-0">
        <span class={["size-2.5 rounded-full shadow-md", @style.dot, @style.glow]} />
        <h2 class="font-semibold text-sm tracking-wide">{@stage.name}</h2>
        <span class={["text-xs font-bold tabular-nums", @style.count]}>{length(@stage.jobs)}</span>
        <button
          type="button"
          class="ml-auto btn btn-ghost btn-xs btn-circle opacity-50 hover:opacity-100 transition-opacity"
          phx-click="open_quick_add"
          phx-value-stage-id={@stage.id}
          aria-label={"Add job to #{@stage.name}"}
        >
          <.icon name="hero-plus" class="size-4" />
        </button>
      </header>

      <form
        :if={@quick_add == @stage.id}
        id={"quick-add-#{@stage.id}-#{@quick_add_seq}"}
        phx-submit="create_job"
        class="px-3 pb-2 space-y-2 animate-pop-in"
      >
        <input type="hidden" name="job[stage_id]" value={@stage.id} />
        <input
          id={"quick-add-company-#{@stage.id}-#{@quick_add_seq}"}
          phx-hook="AutoFocus"
          name="job[company]"
          placeholder="Company"
          required
          autocomplete="off"
          class="input input-sm w-full"
        />
        <input
          name="job[title]"
          placeholder="Role title"
          required
          autocomplete="off"
          class="input input-sm w-full"
        />
        <div class="flex gap-2">
          <button type="submit" class="btn btn-primary btn-xs flex-1">Add</button>
          <button type="button" class="btn btn-ghost btn-xs" phx-click="cancel_quick_add">
            Cancel
          </button>
        </div>
      </form>

      <ul
        id={"stage-#{@stage.id}"}
        phx-hook="BoardColumn"
        data-stage-id={@stage.id}
        class="board-column flex-1 overflow-y-auto px-3 pb-3 space-y-2.5 min-h-16"
      >
        <.job_card :for={job <- @stage.jobs} job={job} stage_slug={@stage.slug} />
      </ul>
    </section>
    """
  end

  attr :job, :map, required: true
  attr :stage_slug, :string, required: true

  defp job_card(assigns) do
    ~H"""
    <li
      id={"job-#{@job.id}"}
      data-job-id={@job.id}
      phx-click="open_job"
      phx-value-id={@job.id}
      class={[
        "job-card group cursor-grab rounded-xl bg-base-100 border border-base-content/8 p-3.5 shadow-sm",
        "hover:shadow-lg hover:-translate-y-0.5 hover:border-base-content/15 transition-all duration-200",
        @stage_slug == "rejected" && "opacity-60 hover:opacity-90"
      ]}
    >
      <div class="flex items-start gap-2.5">
        <.company_avatar company={@job.company} />
        <div class="min-w-0 flex-1">
          <p class="font-semibold text-sm leading-tight truncate">{@job.company}</p>
          <p class="text-xs opacity-70 leading-snug mt-0.5 line-clamp-2">{@job.title}</p>
        </div>
        <a
          :if={@job.url}
          href={@job.url}
          target="_blank"
          rel="noopener noreferrer"
          onclick="event.stopPropagation()"
          class="opacity-0 group-hover:opacity-60 hover:!opacity-100 transition-opacity shrink-0 mt-0.5"
          aria-label="Open job posting"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
        </a>
      </div>

      <div :if={@job.location || @job.salary} class="flex flex-wrap gap-1.5 mt-2.5">
        <span :if={@job.location} class="badge badge-ghost badge-xs gap-1 py-2">
          <.icon name="hero-map-pin-micro" class="size-3 opacity-60" />{@job.location}
        </span>
        <span :if={@job.salary} class="badge badge-ghost badge-xs gap-1 py-2">
          <.icon name="hero-banknotes-micro" class="size-3 opacity-60" />{@job.salary}
        </span>
      </div>

      <div class="flex items-center justify-between mt-2.5">
        <.stars value={@job.excitement} class="text-[10px]" />
        <.stage_age job={@job} stage_slug={@stage_slug} />
      </div>
    </li>
    """
  end

  attr :job, :map, required: true
  attr :stage_slug, :string, required: true

  defp stage_age(assigns) do
    days = days_in_stage(assigns.job)
    settled? = assigns.stage_slug in ["offer", "rejected", "wishlist"]

    color =
      cond do
        settled? or days < 3 -> "opacity-40"
        days < 7 -> "text-amber-500 opacity-90"
        true -> "text-rose-500 opacity-90"
      end

    assigns = assign(assigns, days: days, color: color)

    ~H"""
    <span class={["text-[10px] font-medium tabular-nums flex items-center gap-1", @color]}>
      <.icon name="hero-clock-micro" class="size-3" />
      {if @days == 0, do: "today", else: "#{@days}d"}
    </span>
    """
  end

  attr :company, :string, required: true
  attr :class, :string, default: "size-8 text-[11px]"

  defp company_avatar(assigns) do
    ~H"""
    <span class={[
      "grid place-items-center rounded-lg bg-gradient-to-br text-white font-bold shrink-0 shadow-sm select-none",
      avatar_gradient(@company),
      @class
    ]}>
      {initials(@company)}
    </span>
    """
  end

  attr :value, :integer, required: true
  attr :class, :string, default: ""

  defp stars(assigns) do
    ~H"""
    <span class={["tracking-tight select-none", @class]} aria-label={"Excitement #{@value} of 5"}>
      <span class="text-amber-400">{String.duplicate("★", @value)}</span>
      <span class="opacity-25">{String.duplicate("★", 5 - @value)}</span>
    </span>
    """
  end

  attr :value, :integer, required: true
  attr :label, :string, required: true

  defp stat_pill(assigns) do
    ~H"""
    <div class="flex items-baseline gap-1.5 rounded-full bg-base-200/80 border border-base-content/5 px-3 py-1.5">
      <span class="text-sm font-bold tabular-nums">{@value}</span>
      <span class="text-xs opacity-60">{@label}</span>
    </div>
    """
  end

  attr :job, :map, required: true
  attr :form, :any, required: true

  defp job_modal(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 grid place-items-center p-4 sm:p-6 bg-black/40 backdrop-blur-sm animate-fade-in"
      role="dialog"
      aria-modal="true"
      phx-window-keydown="close_modal"
      phx-key="escape"
    >
      <div
        class="w-full max-w-2xl max-h-full overflow-y-auto rounded-2xl bg-base-100 shadow-2xl border border-base-content/10 animate-pop-in"
        phx-click-away="close_modal"
      >
        <div class="flex items-start gap-3.5 p-5 pb-4 border-b border-base-content/8">
          <.company_avatar company={@job.company} class="size-12 text-base" />
          <div class="min-w-0 flex-1">
            <h3 class="font-bold text-lg leading-tight truncate">{@job.company}</h3>
            <p class="text-sm opacity-70 truncate">{@job.title}</p>
            <p class="text-xs opacity-50 mt-1">
              {@job.stage.name} · {days_label(days_in_stage(@job))}
            </p>
          </div>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-circle"
            phx-click="close_modal"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <.form
          for={@form}
          id="job-form"
          phx-change="validate_job"
          phx-submit="save_job"
          class="p-5 pt-4 space-y-1"
        >
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-4">
            <.input field={@form[:company]} label="Company" />
            <.input field={@form[:title]} label="Role title" />
            <.input field={@form[:location]} label="Location" placeholder="Remote, Austin, …" />
            <.input field={@form[:salary]} label="Salary" placeholder="$150k–180k" />
            <.input field={@form[:url]} label="Posting URL" placeholder="https://…" />
            <.input field={@form[:source]} type="select" label="Source" prompt="Where'd you find it?" options={sources()} />
            <.input field={@form[:applied_on]} type="date" label="Applied on" />
            <div class="fieldset mb-2">
              <label class="label" for="job-excitement">Excitement</label>
              <div id="job-excitement" class="rating rating-sm mt-1.5">
                <input
                  :for={i <- 1..5}
                  type="radio"
                  name={@form[:excitement].name}
                  value={i}
                  checked={excitement_value(@form) == i}
                  class="mask mask-star-2 bg-amber-400"
                  aria-label={"#{i} star#{if i > 1, do: "s"}"}
                />
              </div>
            </div>
          </div>
          <.input field={@form[:notes]} type="textarea" label="Notes" rows="3" />

          <div class="flex items-center gap-2 pt-2">
            <button type="submit" class="btn btn-primary btn-sm px-6">Save</button>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="close_modal">Cancel</button>
            <button
              type="button"
              class="btn btn-ghost btn-sm text-error ml-auto"
              phx-click="delete_job"
              data-confirm={"Remove #{@job.company} — #{@job.title} from the board?"}
            >
              <.icon name="hero-trash-micro" class="size-4" /> Remove
            </button>
          </div>
        </.form>

        <div class="px-5 pb-5">
          <h4 class="text-xs font-semibold uppercase tracking-wider opacity-50 mb-3">Activity</h4>

          <form id={"note-form-#{length(@job.activities)}"} phx-submit="add_note" class="flex gap-2 mb-4">
            <input
              name="note[body]"
              placeholder="Log a note — call, follow-up, gut feeling…"
              autocomplete="off"
              class="input input-sm flex-1"
            />
            <button type="submit" class="btn btn-soft btn-sm">
              <.icon name="hero-plus-micro" class="size-4" /> Note
            </button>
          </form>

          <ol class="space-y-2.5">
            <li :for={activity <- @job.activities} class="flex items-start gap-2.5 text-sm">
              <span class="grid place-items-center size-6 rounded-full bg-base-200 shrink-0 mt-px">
                <.icon name={activity_icon(activity.kind)} class="size-3 opacity-60" />
              </span>
              <p class="flex-1 leading-snug opacity-85">{activity.body}</p>
              <span class="text-xs opacity-40 tabular-nums shrink-0 mt-0.5">
                {relative_time(activity.inserted_at)}
              </span>
            </li>
          </ol>
          <p :if={@job.activities == []} class="text-sm opacity-40 italic">No activity yet.</p>
        </div>
      </div>
    </div>
    """
  end

  ## Helpers

  defp sources, do: @sources

  defp stage_style(slug), do: Map.get(@stage_styles, slug, @default_style)

  defp avatar_gradient(company) do
    Enum.at(@avatar_gradients, :erlang.phash2(company, length(@avatar_gradients)))
  end

  defp initials(company) do
    company
    |> String.split(~r/[\s\-_]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  defp days_in_stage(%Job{stage_entered_at: entered}) do
    DateTime.diff(DateTime.utc_now(), entered, :day)
  end

  defp days_label(0), do: "entered today"
  defp days_label(1), do: "1 day in stage"
  defp days_label(days), do: "#{days} days in stage"

  defp excitement_value(form) do
    case form[:excitement].value do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _ -> 3
    end
  end

  defp activity_icon("created"), do: "hero-sparkles-micro"
  defp activity_icon("moved"), do: "hero-arrow-right-micro"
  defp activity_icon("note"), do: "hero-chat-bubble-bottom-center-text-micro"
  defp activity_icon(_), do: "hero-bolt-micro"

  defp relative_time(datetime) do
    seconds = DateTime.diff(DateTime.utc_now(), datetime)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      seconds < 86_400 * 30 -> "#{div(seconds, 86_400)}d ago"
      true -> Calendar.strftime(datetime, "%b %-d")
    end
  end

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_binary(value), do: String.to_integer(value)
end
