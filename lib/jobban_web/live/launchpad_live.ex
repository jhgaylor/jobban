defmodule JobbanWeb.LaunchpadLive do
  use JobbanWeb, :live_view

  @moduledoc """
  The private prep view for the wishlist→applied gap, built as one flow rather
  than a pile of features: pick the highest-leverage way in for each company and
  walk through doing it, so you apply with an edge instead of cold.

  The main view is a **priority queue** — listings ranked by fit/excitement/aging
  (`Board.list_launchpad/0`), each row showing the recommended way in
  (`queue_route/1`) and the single next action (`next_action_label/1`, mirroring
  the detail's "Do this next" lead). The detail modal is a runway: a "Do this
  next" lead card, then three ordered beats — **1 · Size it up** (the briefing),
  **2 · The plan** (the full checklist, every step grouped by play), and
  **3 · Reach out** (who to find, generated, flowing into your saved contacts).
  The strategist (`Jobban.Strategist`) rates every way-in for leverage and
  auto-populates the recommended plays' steps.

  Admin-only — everything here is the strategic layer the public board hides, so
  the whole page redirects non-admins rather than partially gating.
  """

  alias Jobban.Board
  alias Jobban.Board.Plays
  alias Jobban.Briefing
  alias Jobban.Networking
  alias Jobban.Strategist

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
  def mount(_params, session, socket) do
    if JobbanWeb.Auth.admin_session?(session) do
      if connected?(socket), do: Board.subscribe()

      {:ok,
       socket
       |> assign(
         page_title: "Launchpad",
         admin?: true,
         selected_id: nil,
         contact_form: nil,
         assessing?: false,
         generating_guide?: false,
         briefing?: false,
         drafting_for: nil,
         draft: nil,
         open_sections: MapSet.new()
       )
       |> assign_jobs()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Log in to use the Launchpad")
       |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_info({:board_changed}, socket) do
    socket = assign_jobs(socket)

    socket =
      if socket.assigns.selected_id && selected(socket.assigns) == nil do
        assign(socket, selected_id: nil, contact_form: nil, draft: nil, drafting_for: nil)
      else
        socket
      end

    {:noreply, socket}
  end

  # Defense in depth — mount already redirects non-admins, but never trust the
  # client. Every mutating event funnels through this guard first.
  @write_events ~w(select_job close_detail reassess add_task toggle_task delete_task
                   add_contact validate_contact delete_contact toggle_reached
                   generate_guide draft_outreach close_draft generate_brief toggle_section)

  @impl true
  def handle_event(event, _params, %{assigns: %{admin?: false}} = socket)
      when event in @write_events do
    {:noreply, put_flash(socket, :error, "Log in to make changes")}
  end

  def handle_event("select_job", %{"id" => id}, socket) do
    case Board.get_job(to_int(id)) do
      nil ->
        {:noreply, socket}

      job ->
        {:noreply,
         assign(socket,
           selected_id: job.id,
           contact_form: blank_contact_form(),
           draft: nil,
           drafting_for: nil,
           open_sections: MapSet.new()
         )}
    end
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, selected_id: nil, contact_form: nil, draft: nil, drafting_for: nil)}
  end

  def handle_event("generate_guide", _params, socket) do
    job = current_job(socket)

    cond do
      job == nil ->
        {:noreply, socket}

      Networking.enabled?() ->
        {:noreply,
         socket
         |> assign(generating_guide?: true)
         |> start_async(:guide, fn -> Networking.guide(job) end)}

      true ->
        {:noreply, put_flash(socket, :error, "Networking help needs an OpenRouter key")}
    end
  end

  def handle_event("generate_brief", _params, socket) do
    job = current_job(socket)

    cond do
      job == nil ->
        {:noreply, socket}

      Briefing.enabled?() ->
        {:noreply,
         socket
         |> assign(briefing?: true)
         |> start_async(:brief, fn -> Briefing.brief(job) end)}

      true ->
        {:noreply, put_flash(socket, :error, "Briefings need an OpenRouter key")}
    end
  end

  def handle_event("draft_outreach", params, socket) do
    job = current_job(socket)
    target = resolve_target(job, params)

    cond do
      job == nil or target == nil ->
        {:noreply, socket}

      Networking.enabled?() ->
        who = target[:name] || target[:label]

        {:noreply,
         socket
         |> assign(draft: nil, drafting_for: who)
         |> start_async(:draft, fn -> {who, Networking.draft(job, target)} end)}

      true ->
        {:noreply, put_flash(socket, :error, "Drafting needs an OpenRouter key")}
    end
  end

  def handle_event("close_draft", _params, socket) do
    {:noreply, assign(socket, draft: nil, drafting_for: nil)}
  end

  def handle_event("toggle_section", %{"section" => key}, socket) do
    {:noreply,
     update(socket, :open_sections, fn open ->
       if MapSet.member?(open, key), do: MapSet.delete(open, key), else: MapSet.put(open, key)
     end)}
  end

  def handle_event("reassess", _params, socket) do
    job = current_job(socket)

    cond do
      job == nil ->
        {:noreply, socket}

      Strategist.enabled?() ->
        {:noreply,
         socket
         |> assign(assessing?: true)
         |> start_async(:assess, fn -> Strategist.assess(job) end)}

      true ->
        {:noreply, put_flash(socket, :error, "The strategist needs an OpenRouter key")}
    end
  end

  def handle_event("add_task", %{"task" => %{"title" => title}}, socket) do
    if String.trim(title) != "" do
      {:ok, _} = Board.add_task(current_job(socket), title)
    end

    {:noreply, socket}
  end

  def handle_event("toggle_task", %{"id" => id}, socket) do
    {:ok, _} = id |> to_int() |> Board.get_task!() |> Board.toggle_task()
    {:noreply, socket}
  end

  def handle_event("delete_task", %{"id" => id}, socket) do
    {:ok, _} = id |> to_int() |> Board.get_task!() |> Board.delete_task()
    {:noreply, socket}
  end

  def handle_event("add_contact", %{"contact" => params}, socket) do
    case Board.add_contact(current_job(socket), params) do
      {:ok, _contact} -> {:noreply, assign(socket, contact_form: blank_contact_form())}
      {:error, changeset} -> {:noreply, assign(socket, contact_form: to_form(changeset))}
    end
  end

  def handle_event("validate_contact", %{"contact" => params}, socket) do
    form =
      %Jobban.Board.Contact{}
      |> Board.change_contact(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, contact_form: form)}
  end

  def handle_event("delete_contact", %{"id" => id}, socket) do
    {:ok, _} = id |> to_int() |> Board.get_contact!() |> Board.delete_contact()
    {:noreply, socket}
  end

  def handle_event("toggle_reached", %{"id" => id}, socket) do
    {:ok, _} = id |> to_int() |> Board.get_contact!() |> Board.toggle_contact_reached()
    {:noreply, socket}
  end

  @impl true
  def handle_async(:assess, {:ok, {:ok, _job}}, socket) do
    {:noreply, socket |> assign(assessing?: false) |> put_flash(:info, "Re-assessed the plays")}
  end

  def handle_async(:assess, {:ok, {:error, _reason}}, socket) do
    {:noreply,
     socket |> assign(assessing?: false) |> put_flash(:error, "Couldn't re-assess this listing")}
  end

  def handle_async(:assess, {:exit, _reason}, socket) do
    {:noreply,
     socket |> assign(assessing?: false) |> put_flash(:error, "Assessment crashed — try again")}
  end

  def handle_async(:guide, {:ok, {:ok, _job}}, socket) do
    {:noreply,
     socket |> assign(generating_guide?: false) |> put_flash(:info, "Mapped out who to reach")}
  end

  def handle_async(:guide, {:ok, {:error, _reason}}, socket) do
    {:noreply,
     socket
     |> assign(generating_guide?: false)
     |> put_flash(:error, "Couldn't map out contacts — try again")}
  end

  def handle_async(:guide, {:exit, _reason}, socket) do
    {:noreply,
     socket |> assign(generating_guide?: false) |> put_flash(:error, "That crashed — try again")}
  end

  def handle_async(:draft, {:ok, {who, {:ok, message}}}, socket) do
    {:noreply, assign(socket, drafting_for: nil, draft: Map.put(message, :who, who))}
  end

  def handle_async(:draft, {:ok, {_who, {:error, _reason}}}, socket) do
    {:noreply,
     socket |> assign(drafting_for: nil) |> put_flash(:error, "Couldn't draft that — try again")}
  end

  def handle_async(:draft, {:exit, _reason}, socket) do
    {:noreply,
     socket |> assign(drafting_for: nil) |> put_flash(:error, "Draft crashed — try again")}
  end

  def handle_async(:brief, {:ok, {:ok, _job}}, socket) do
    {:noreply, socket |> assign(briefing?: false) |> put_flash(:info, "Briefing ready")}
  end

  def handle_async(:brief, {:ok, {:error, _reason}}, socket) do
    {:noreply,
     socket
     |> assign(briefing?: false)
     |> put_flash(:error, "Couldn't write a briefing — try again")}
  end

  def handle_async(:brief, {:exit, _reason}, socket) do
    {:noreply,
     socket |> assign(briefing?: false) |> put_flash(:error, "Briefing crashed — try again")}
  end

  ## Internals

  # Resolve a draft target from either a generated networking target or a saved
  # contact, into the `%{label, title_hint, name}` map the drafter expects.
  defp resolve_target(nil, _params), do: nil

  defp resolve_target(job, %{"target-id" => id}) do
    case Enum.find(job.networking_targets, &(&1.id == to_int(id))) do
      nil -> nil
      t -> %{label: t.label, title_hint: t.title_hint}
    end
  end

  defp resolve_target(job, %{"contact-id" => id}) do
    case Enum.find(job.contacts, &(&1.id == to_int(id))) do
      nil -> nil
      c -> %{name: c.name, label: c.role || "Contact", title_hint: c.role}
    end
  end

  defp resolve_target(_job, _params), do: nil

  defp assign_jobs(socket), do: assign(socket, jobs: Board.list_launchpad())

  defp current_job(socket), do: Board.get_job(socket.assigns.selected_id)

  defp blank_contact_form, do: to_form(Board.change_contact(%Jobban.Board.Contact{}))

  defp selected(%{selected_id: nil}), do: nil
  defp selected(%{selected_id: id, jobs: jobs}), do: Enum.find(jobs, &(&1.id == id))

  @impl true
  def render(assigns) do
    assigns = assign(assigns, job: selected(assigns), plays: Plays.all())

    ~H"""
    <div class="h-dvh flex flex-col bg-board overflow-hidden">
      <header class="flex items-center gap-4 px-4 sm:px-6 pt-4 pb-3 shrink-0">
        <div class="flex items-center gap-3 min-w-0">
          <div class="grid place-items-center size-10 rounded-xl bg-gradient-to-br from-sky-500 to-cyan-400 shadow-lg shadow-sky-500/30">
            <.icon name="hero-rocket-launch" class="size-5 text-white" />
          </div>
          <div class="min-w-0">
            <h1 class="text-xl font-bold tracking-tight leading-none">Launchpad</h1>
            <p class="text-xs opacity-50 mt-1 truncate">
              {length(@jobs)} {if length(@jobs) == 1, do: "listing", else: "listings"} · which way in for each
            </p>
          </div>
        </div>
        <div class="ml-auto flex items-center gap-2 sm:gap-3">
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm gap-1.5 opacity-60 hover:opacity-100">
            <.icon name="hero-view-columns-micro" class="size-3.5" /> Board
          </.link>
          <Layouts.theme_toggle />
          <.link
            href={~p"/logout"}
            method="delete"
            class="btn btn-ghost btn-sm gap-1.5 opacity-60 hover:opacity-100"
          >
            <.icon name="hero-arrow-right-start-on-rectangle-micro" class="size-3.5" /> Log out
          </.link>
        </div>
      </header>

      <main class="flex-1 overflow-auto px-4 sm:px-6 pb-6">
        <div class="max-w-2xl mx-auto">
          <ul :if={@jobs != []} class="space-y-2">
            <li :for={job <- @jobs}>
              <button
                type="button"
                phx-click="select_job"
                phx-value-id={job.id}
                class="w-full text-left rounded-xl bg-base-100 border border-base-content/8 shadow-sm hover:border-base-content/20 hover:bg-base-content/[0.02] transition-colors p-3.5 flex items-center gap-3.5"
              >
                <.company_avatar company={job.company} class="size-10 text-sm" />
                <div class="min-w-0 flex-1">
                  <div class="flex items-center gap-1.5 min-w-0">
                    <span class="font-semibold truncate">{job.company}</span>
                    <.fit_badge job={job} />
                    <span class="text-xs opacity-50 truncate">· {job.title}</span>
                  </div>
                  <div class={["flex items-center gap-1 mt-0.5 text-xs", queue_route_color(job)]}>
                    <.icon name={queue_route_icon(job)} class="size-3 shrink-0" />
                    <span class="truncate font-medium">{queue_route(job)}</span>
                  </div>
                  <div class="flex items-center gap-1.5 mt-1.5 text-sm">
                    <.icon name="hero-arrow-right-micro" class="size-3.5 opacity-40 shrink-0" />
                    <span class="truncate">{next_action_label(job)}</span>
                  </div>
                </div>
                <.progress_meter job={job} />
              </button>
            </li>
          </ul>

          <div :if={@jobs == []} class="text-center py-20 opacity-50">
            <.icon name="hero-check-circle" class="size-10 mx-auto mb-3 opacity-40" />
            <p class="text-sm">Nothing waiting on prep — every wishlist is launched.</p>
          </div>
        </div>
      </main>

      <.detail
        :if={@job}
        job={@job}
        plays={@plays}
        contact_form={@contact_form}
        assessing?={@assessing?}
        generating_guide?={@generating_guide?}
        briefing?={@briefing?}
        drafting_for={@drafting_for}
        draft={@draft}
        open_sections={@open_sections}
      />
      <Layouts.flash_group flash={@flash} />
    </div>
    """
  end

  # Queue row: the recommended way in, classified once into :unassessed /
  # :front (cold apply) / :side (a higher-leverage play).
  defp queue_route_kind(job) do
    cond do
      job.job_plays == [] ->
        :unassessed

      true ->
        case top_play(job) do
          nil -> :front
          %{slug: "apply"} -> :front
          top -> {:side, top.slug}
        end
    end
  end

  defp queue_route(job) do
    case queue_route_kind(job) do
      :unassessed -> "Not assessed yet"
      :front -> "Front door · cold apply"
      {:side, slug} -> "Side door · #{play_name(slug)}"
    end
  end

  defp queue_route_color(job) do
    case queue_route_kind(job) do
      :unassessed -> "opacity-50"
      :front -> "opacity-60"
      {:side, _} -> "text-sky-500"
    end
  end

  defp queue_route_icon(job) do
    case queue_route_kind(job) do
      :unassessed -> "hero-sparkles-micro"
      :front -> "hero-arrow-right-end-on-rectangle-micro"
      {:side, _} -> "hero-arrow-trending-up-micro"
    end
  end

  # The single next action, as a short label for the queue row (mirrors the
  # detail's "Do this next" lead).
  defp next_action_label(job) do
    case compute_next_move(job) do
      :assess -> "Size it up"
      {:guide, _company} -> "Map out who to reach"
      {:task, task, _why} -> task.title
      {:run, name} -> "Start the #{name} play"
      :done -> "Ready — drag into Applied"
    end
  end

  attr :job, :map, required: true

  defp progress_meter(assigns) do
    total = length(assigns.job.tasks)
    done = Enum.count(assigns.job.tasks, & &1.done)
    pct = if total == 0, do: 0, else: round(done / total * 100)
    assigns = assign(assigns, total: total, done: done, pct: pct)

    ~H"""
    <div class="shrink-0 w-14 text-right">
      <div class="text-xs tabular-nums opacity-60">{@done}/{@total}</div>
      <div class="mt-1 h-1.5 rounded-full bg-base-content/10 overflow-hidden">
        <div
          class={[
            "h-full rounded-full",
            if(@total > 0 && @done == @total, do: "bg-emerald-500", else: "bg-primary")
          ]}
          style={"width: #{@pct}%"}
        >
        </div>
      </div>
    </div>
    """
  end

  attr :job, :map, required: true
  attr :plays, :list, required: true
  attr :contact_form, :any, required: true
  attr :assessing?, :boolean, required: true
  attr :generating_guide?, :boolean, required: true
  attr :briefing?, :boolean, required: true
  attr :drafting_for, :string, default: nil
  attr :draft, :map, default: nil
  attr :open_sections, :any, required: true

  defp detail(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 grid place-items-center p-4 sm:p-6 bg-black/40 backdrop-blur-sm animate-fade-in"
      role="dialog"
      aria-modal="true"
      phx-window-keydown={!@draft && "close_detail"}
      phx-key="escape"
    >
      <div
        class="w-full max-w-2xl max-h-full overflow-y-auto rounded-2xl bg-base-100 shadow-2xl border border-base-content/10 animate-pop-in"
        phx-click-away={!@draft && "close_detail"}
      >
        <div class="flex items-start gap-3.5 p-5 pb-4 border-b border-base-content/8">
          <.company_avatar company={@job.company} class="size-12 text-base" />
          <div class="min-w-0 flex-1">
            <h3 class="font-bold text-lg leading-tight truncate">{@job.company}</h3>
            <p class="text-sm opacity-70 truncate">{@job.title}</p>
            <p class="text-xs opacity-50 mt-1 flex items-center gap-1.5 flex-wrap">
              <span class="badge badge-xs border-0 bg-sky-500/15 text-sky-400 font-medium">
                {route_label(@job)}
              </span>
              <span>· {aging_label(@job)}</span>
              <a
                :if={@job.url}
                href={@job.url}
                target="_blank"
                rel="noopener noreferrer"
                class="link link-hover inline-flex items-center gap-0.5"
              >
                <.icon name="hero-arrow-top-right-on-square-micro" class="size-3" /> posting
              </a>
            </p>
          </div>
          <div class="flex items-center gap-1">
            <button
              :if={Strategist.enabled?()}
              type="button"
              class="btn btn-ghost btn-xs gap-1 opacity-60 hover:opacity-100"
              phx-click="reassess"
              disabled={@assessing?}
              title="Re-run the strategist (replaces auto-generated steps)"
            >
              <.icon
                name={if @assessing?, do: "hero-arrow-path-micro", else: "hero-sparkles-micro"}
                class={["size-3.5", @assessing? && "animate-spin"]}
              /> {if @assessing?, do: "Assessing…", else: "Re-assess"}
            </button>
            <button
              type="button"
              class="btn btn-ghost btn-sm btn-circle"
              phx-click="close_detail"
              aria-label="Close"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>
        </div>

        <.next_move job={@job} assessing?={@assessing?} generating_guide?={@generating_guide?} />

        <%!-- Step 1 · Size it up (the briefing) --%>
        <.section
          key="briefing"
          title="1 · Size it up"
          accent="text-cyan-400"
          open={@open_sections}
          summary={briefing_summary(@job)}
        >
          <:actions>
            <button
              :if={Briefing.enabled?()}
              type="button"
              class="btn btn-ghost btn-xs gap-1 opacity-70 hover:opacity-100"
              phx-click="generate_brief"
              disabled={@briefing?}
            >
              <.icon
                name={if @briefing?, do: "hero-arrow-path-micro", else: "hero-sparkles-micro"}
                class={["size-3", @briefing? && "animate-spin"]}
              />
              {cond do
                @briefing? -> "Writing…"
                @job.job_brief -> "Refresh"
                true -> "Generate"
              end}
            </button>
          </:actions>

          <p :if={is_nil(@job.job_brief)} class="text-sm opacity-60 italic leading-snug">
            Generate a rundown of what {@job.company} does, where this role sits, and why it matters to them.
          </p>

          <div :if={@job.job_brief} class="space-y-3">
            <.brief_part
              :if={@job.job_brief.company_overview}
              label="What they do"
              text={@job.job_brief.company_overview}
            />
            <.brief_part
              :if={@job.job_brief.role_in_company}
              label="The role here"
              text={@job.job_brief.role_in_company}
            />
            <.brief_part
              :if={@job.job_brief.strategic_value}
              label="Why it matters to them"
              text={@job.job_brief.strategic_value}
            />
          </div>
        </.section>

        <%!-- Step 2 · The plan — the whole checklist, always visible, done included --%>
        <div class="mx-5 mt-4">
          <div class="flex items-center gap-2 mb-2.5">
            <span class="text-xs font-semibold uppercase tracking-wider opacity-70">
              2 · The plan
            </span>
            <span :if={@job.tasks != []} class="text-xs opacity-50 tabular-nums">
              {Enum.count(@job.tasks, & &1.done)}/{length(@job.tasks)}
            </span>
            <button
              :if={Strategist.enabled?()}
              type="button"
              class="btn btn-ghost btn-xs gap-1 ml-auto opacity-70 hover:opacity-100"
              phx-click="reassess"
              disabled={@assessing?}
              title="Re-run the strategist (replaces auto-generated steps)"
            >
              <.icon
                name={if @assessing?, do: "hero-arrow-path-micro", else: "hero-sparkles-micro"}
                class={["size-3", @assessing? && "animate-spin"]}
              />
              {if @assessing?, do: "Assessing…", else: "Re-assess"}
            </button>
          </div>

          <p :if={@job.job_plays == []} class="text-sm opacity-60 italic leading-snug mb-2">
            Not assessed yet — {if Strategist.enabled?(),
              do: "hit Re-assess to rate the ways in and lay out the steps.",
              else: "set an OpenRouter key to enable the strategist."}
          </p>

          <div class="space-y-3.5">
            <div :for={{play, tasks, leverage, rationale} <- checklist_groups(@job)}>
              <div class="flex items-center gap-1.5">
                <span class="text-sm font-medium">{play.name}</span>
                <.leverage_badge :if={leverage} leverage={leverage} />
              </div>
              <p :if={rationale} class="text-xs opacity-55 leading-snug mt-0.5 mb-1.5">
                {rationale}
              </p>
              <.task_list tasks={tasks} empty="" />
            </div>

            <div>
              <p class="text-sm font-medium mb-1.5">Other steps</p>
              <.task_list tasks={freeform_tasks(@job)} empty="No extra steps." />
              <form phx-submit="add_task" class="flex gap-2 mt-2">
                <input
                  name="task[title]"
                  placeholder="Add your own step…"
                  autocomplete="off"
                  class="input input-xs flex-1 bg-base-100"
                />
                <button type="submit" class="btn btn-soft btn-xs">
                  <.icon name="hero-plus-micro" class="size-4" />
                </button>
              </form>
            </div>
          </div>
        </div>

        <%!-- Step 3 · Reach out — who to find (generated) flowing into saved contacts --%>
        <.section
          key="people"
          title="3 · Reach out"
          accent="text-indigo-400"
          open={@open_sections}
          summary={outreach_summary(@job)}
        >
          <:actions>
            <button
              :if={Networking.enabled?()}
              type="button"
              class="btn btn-ghost btn-xs gap-1 opacity-70 hover:opacity-100"
              phx-click="generate_guide"
              disabled={@generating_guide?}
            >
              <.icon
                name={if @generating_guide?, do: "hero-arrow-path-micro", else: "hero-sparkles-micro"}
                class={["size-3", @generating_guide? && "animate-spin"]}
              />
              {cond do
                @generating_guide? -> "Mapping…"
                @job.networking_targets == [] -> "Find people"
                true -> "Refresh"
              end}
            </button>
          </:actions>

          <p class="text-[10px] font-semibold uppercase tracking-wider opacity-50 mb-1.5">
            Who to reach
          </p>
          <p
            :if={@job.networking_targets == [] && !@generating_guide?}
            class="text-sm opacity-60 italic leading-snug mb-3"
          >
            Find out who to contact at {@job.company} and exactly how to find them.
          </p>

          <ul class="space-y-2.5">
            <li :for={t <- @job.networking_targets} class="rounded-lg bg-base-100/60 p-3">
              <div class="flex items-center gap-2 flex-wrap">
                <span class="font-semibold text-sm">{t.label}</span>
                <span :if={t.title_hint} class="badge badge-ghost badge-xs">{t.title_hint}</span>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs ml-auto gap-1 opacity-70 hover:opacity-100"
                  phx-click="draft_outreach"
                  phx-value-target-id={t.id}
                  disabled={@drafting_for != nil}
                >
                  <.icon
                    name={
                      if @drafting_for == t.label,
                        do: "hero-arrow-path-micro",
                        else: "hero-pencil-square-micro"
                    }
                    class={["size-3", @drafting_for == t.label && "animate-spin"]}
                  /> Draft
                </button>
              </div>
              <p :if={t.why} class="text-xs opacity-70 mt-1 leading-snug">{t.why}</p>
              <div
                :if={t.referral_path}
                class="mt-2 rounded-md bg-emerald-500/8 border border-emerald-500/15 p-2.5 text-xs leading-relaxed"
              >
                <p class="font-semibold uppercase tracking-wider text-[10px] text-emerald-500/80 mb-1 flex items-center gap-1">
                  <.icon name="hero-arrow-trending-up-micro" class="size-3" /> Turn it into a referral
                </p>
                <p class="opacity-80 whitespace-pre-line">{t.referral_path}</p>
              </div>
              <div
                :if={t.how_to_find}
                class="mt-2 rounded-md bg-base-200/60 p-2.5 text-xs leading-relaxed"
              >
                <p class="font-semibold uppercase tracking-wider text-[10px] opacity-50 mb-1">
                  How to find
                </p>
                <p class="opacity-80 whitespace-pre-line">{t.how_to_find}</p>
              </div>
            </li>
          </ul>

          <p class="text-[10px] font-semibold uppercase tracking-wider opacity-50 mt-4 mb-1.5">
            Your contacts
          </p>
          <ul class="space-y-2.5 mb-4">
            <li
              :for={contact <- @job.contacts}
              class="flex items-start gap-2.5 group/contact rounded-lg bg-base-100/60 p-2.5"
            >
              <button
                type="button"
                phx-click="toggle_reached"
                phx-value-id={contact.id}
                class={[
                  "grid place-items-center size-6 rounded-full shrink-0 mt-px transition-colors",
                  if(contact.reached_out_at,
                    do: "bg-emerald-500/20 text-emerald-500",
                    else: "bg-base-content/10 opacity-50 hover:opacity-100"
                  )
                ]}
                title={
                  if contact.reached_out_at,
                    do: "Reached out #{Calendar.strftime(contact.reached_out_at, "%b %-d")}",
                    else: "Mark as reached out"
                }
              >
                <.icon name="hero-paper-airplane-micro" class="size-3" />
              </button>
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-1.5 flex-wrap">
                  <span class="font-semibold text-sm">{contact.name}</span>
                  <span :if={contact.role} class="badge badge-ghost badge-xs">{contact.role}</span>
                  <span :if={contact.relationship} class="text-xs opacity-50">
                    · {contact.relationship}
                  </span>
                </div>
                <div class="flex items-center gap-3 mt-1 text-xs">
                  <a
                    :if={contact.email}
                    href={"mailto:#{contact.email}"}
                    class="link link-hover opacity-70"
                  >
                    {contact.email}
                  </a>
                  <a
                    :if={contact.linkedin_url}
                    href={contact.linkedin_url}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="link link-hover opacity-70 inline-flex items-center gap-0.5"
                  >
                    <.icon name="hero-link-micro" class="size-3" /> LinkedIn
                  </a>
                </div>
                <p :if={contact.notes} class="text-xs opacity-60 mt-1 whitespace-pre-line">
                  {contact.notes}
                </p>
              </div>
              <button
                type="button"
                phx-click="draft_outreach"
                phx-value-contact-id={contact.id}
                disabled={@drafting_for != nil}
                class="btn btn-ghost btn-xs gap-1 opacity-70 hover:opacity-100 shrink-0"
                title="Draft outreach to this contact"
              >
                <.icon
                  name={
                    if @drafting_for == contact.name,
                      do: "hero-arrow-path-micro",
                      else: "hero-pencil-square-micro"
                  }
                  class={["size-3", @drafting_for == contact.name && "animate-spin"]}
                /> Draft
              </button>
              <button
                type="button"
                phx-click="delete_contact"
                phx-value-id={contact.id}
                data-confirm={"Remove #{contact.name}?"}
                class="opacity-0 group-hover/contact:opacity-50 hover:!opacity-100 transition-opacity shrink-0"
                aria-label="Delete contact"
              >
                <.icon name="hero-trash-micro" class="size-3.5" />
              </button>
            </li>
          </ul>

          <.form
            for={@contact_form}
            phx-change="validate_contact"
            phx-submit="add_contact"
            class="space-y-2"
          >
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
              <input
                name="contact[name]"
                value={@contact_form[:name].value}
                placeholder="Name"
                autocomplete="off"
                class="input input-sm bg-base-100"
              />
              <input
                name="contact[role]"
                value={@contact_form[:role].value}
                placeholder="Role — recruiter, hiring mgr, on team…"
                autocomplete="off"
                class="input input-sm bg-base-100"
              />
              <input
                name="contact[relationship]"
                value={@contact_form[:relationship].value}
                placeholder="Relationship — cold, warm, ex-colleague…"
                autocomplete="off"
                class="input input-sm bg-base-100"
              />
              <input
                name="contact[email]"
                value={@contact_form[:email].value}
                placeholder="Email"
                autocomplete="off"
                class="input input-sm bg-base-100"
              />
              <input
                name="contact[linkedin_url]"
                value={@contact_form[:linkedin_url].value}
                placeholder="LinkedIn URL"
                autocomplete="off"
                class="input input-sm bg-base-100 sm:col-span-2"
              />
            </div>
            <textarea
              name="contact[notes]"
              rows="2"
              placeholder="Notes — how you know them, what to ask…"
              class="textarea textarea-sm w-full leading-snug bg-base-100"
            >{Phoenix.HTML.Form.normalize_value("textarea", @contact_form[:notes].value)}</textarea>
            <div class="flex justify-end">
              <button type="submit" class="btn btn-soft btn-sm gap-1">
                <.icon name="hero-user-plus-micro" class="size-4" /> Add contact
              </button>
            </div>
          </.form>
        </.section>

        <div class="h-2"></div>
      </div>
    </div>

    <%!-- Outreach draft overlay (sits above the detail modal) --%>
    <div
      :if={@draft}
      class="fixed inset-0 z-[60] grid place-items-center p-4 sm:p-6 bg-black/50 backdrop-blur-sm animate-fade-in"
      phx-window-keydown="close_draft"
      phx-key="escape"
    >
      <div
        class="w-full max-w-xl max-h-full overflow-y-auto rounded-2xl bg-base-100 shadow-2xl border border-base-content/10 animate-pop-in"
        phx-click-away="close_draft"
      >
        <div class="flex items-center gap-2 p-5 pb-3 border-b border-base-content/8">
          <.icon name="hero-pencil-square-micro" class="size-4 text-indigo-400" />
          <h3 class="font-bold truncate">Outreach to {@draft.who}</h3>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-circle ml-auto"
            phx-click="close_draft"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div class="p-5 space-y-4">
          <div>
            <div class="flex items-center gap-2 mb-1.5">
              <h4 class="text-xs font-semibold uppercase tracking-wider opacity-50 flex items-center gap-1">
                <.icon name="hero-chat-bubble-left-right-micro" class="size-3.5" /> LinkedIn
              </h4>
              <button
                id="copy-linkedin"
                phx-hook="Copy"
                data-copy={@draft.linkedin}
                class="btn btn-xs btn-soft gap-1 ml-auto"
              >
                <.icon name="hero-clipboard-document-micro" class="size-3" />
                <span data-copy-label>Copy</span>
              </button>
            </div>
            <p class="text-sm whitespace-pre-line bg-base-200/50 rounded-lg p-3 leading-relaxed">
              {@draft.linkedin}
            </p>
          </div>

          <div>
            <div class="flex items-center gap-2 mb-1.5">
              <h4 class="text-xs font-semibold uppercase tracking-wider opacity-50 flex items-center gap-1">
                <.icon name="hero-envelope-micro" class="size-3.5" /> Email
              </h4>
              <button
                id="copy-email"
                phx-hook="Copy"
                data-copy={email_clipboard(@draft)}
                class="btn btn-xs btn-soft gap-1 ml-auto"
              >
                <.icon name="hero-clipboard-document-micro" class="size-3" />
                <span data-copy-label>Copy</span>
              </button>
            </div>
            <div class="bg-base-200/50 rounded-lg p-3">
              <p :if={@draft.email_subject != ""} class="text-sm font-semibold mb-1.5">
                {@draft.email_subject}
              </p>
              <p class="text-sm whitespace-pre-line leading-relaxed opacity-90">
                {@draft.email_body}
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp email_clipboard(%{email_subject: subject, email_body: body}) do
    case String.trim(subject || "") do
      "" -> body
      s -> "Subject: #{s}\n\n#{body}"
    end
  end

  # The lead: the single next action and why, computed from the plays + steps.
  attr :job, :map, required: true
  attr :assessing?, :boolean, required: true
  attr :generating_guide?, :boolean, required: true

  defp next_move(assigns) do
    assigns = assign(assigns, :move, compute_next_move(assigns.job))

    ~H"""
    <div class="mx-5 mt-4 rounded-xl bg-primary/10 border border-primary/25 p-4">
      <p class="text-[10px] font-semibold uppercase tracking-wider text-primary mb-2 flex items-center gap-1">
        <.icon name="hero-bolt-micro" class="size-3" /> Do this next
      </p>
      <%= case @move do %>
        <% :assess -> %>
          <div class="flex items-center gap-2.5">
            <p class="text-sm font-medium flex-1 leading-snug">
              Assess this listing to see the best way in — usually better than a cold apply.
            </p>
            <button
              :if={Strategist.enabled?()}
              type="button"
              class="btn btn-primary btn-xs shrink-0"
              phx-click="reassess"
              disabled={@assessing?}
            >
              {if @assessing?, do: "Assessing…", else: "Assess"}
            </button>
          </div>
        <% {:guide, company} -> %>
          <div class="flex items-center gap-2.5">
            <p class="text-sm font-medium flex-1 leading-snug">
              Networking is your highest-leverage way in — map out who to reach at {company}.
            </p>
            <button
              :if={Networking.enabled?()}
              type="button"
              class="btn btn-primary btn-xs shrink-0"
              phx-click="generate_guide"
              disabled={@generating_guide?}
            >
              {if @generating_guide?, do: "Mapping…", else: "Find people"}
            </button>
          </div>
        <% {:task, task, why} -> %>
          <label class="flex items-start gap-2.5 cursor-pointer">
            <input
              type="checkbox"
              phx-click="toggle_task"
              phx-value-id={task.id}
              class="checkbox checkbox-sm checkbox-primary mt-0.5 shrink-0"
            />
            <span class="min-w-0">
              <span class="block text-sm font-medium leading-snug">{task.title}</span>
              <span :if={why} class="text-xs opacity-60 leading-snug">{why}</span>
            </span>
          </label>
        <% :done -> %>
          <p class="text-sm font-medium flex items-center gap-1.5">
            <.icon name="hero-check-circle-micro" class="size-4 text-emerald-500" />
            Prep's done — drag it into Applied.
          </p>
        <% {:run, name} -> %>
          <p class="text-sm font-medium leading-snug">
            Start the <span class="font-semibold">{name}</span> play — open “The plan” below.
          </p>
      <% end %>
    </div>
    """
  end

  # A collapsible section: header (chevron + title + collapsed summary + actions)
  # with the body shown only when its key is in @open_sections.
  attr :key, :string, required: true
  attr :title, :string, required: true
  attr :accent, :string, default: "text-base-content/70"
  attr :summary, :string, default: nil
  attr :open, :any, required: true
  slot :actions
  slot :inner_block, required: true

  defp section(assigns) do
    assigns = assign(assigns, :open?, MapSet.member?(assigns.open, assigns.key))

    ~H"""
    <div class="mx-5 mt-2.5 rounded-xl border border-base-content/10 bg-base-200/40 overflow-hidden">
      <div class="flex items-center gap-2 px-4 py-2.5">
        <button
          type="button"
          phx-click="toggle_section"
          phx-value-section={@key}
          class="flex items-center gap-2 flex-1 min-w-0 text-left"
        >
          <.icon
            name={if @open?, do: "hero-chevron-down-micro", else: "hero-chevron-right-micro"}
            class="size-4 opacity-40 shrink-0"
          />
          <span class={["text-xs font-semibold uppercase tracking-wider shrink-0", @accent]}>
            {@title}
          </span>
          <span :if={@summary && !@open?} class="text-xs opacity-50 truncate">· {@summary}</span>
        </button>
        {render_slot(@actions)}
      </div>
      <div :if={@open?} class="px-4 pb-4">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  ## Next-move + section logic

  defp compute_next_move(job) do
    top = top_play(job)
    task = next_task(job)

    cond do
      job.job_plays == [] -> :assess
      top && top.slug == "networking" && job.networking_targets == [] -> {:guide, job.company}
      task -> {:task, task, move_why(job, task)}
      job.tasks != [] -> :done
      top -> {:run, play_name(top.slug)}
      true -> :done
    end
  end

  defp top_play(job) do
    job.job_plays
    |> Enum.filter(&Plays.recommended?(&1.leverage))
    |> Enum.sort_by(fn p ->
      {leverage_rank(p.leverage), if(p.slug == "apply", do: 1, else: 0)}
    end)
    |> List.first()
  end

  defp next_task(job) do
    lev = Map.new(job.job_plays, &{&1.slug, &1.leverage})

    job.tasks
    |> Enum.reject(& &1.done)
    |> Enum.sort_by(fn t -> {leverage_rank(lev[t.play_slug]), t.position} end)
    |> List.first()
  end

  defp move_why(job, task) do
    case Enum.find(job.job_plays, &(&1.slug == task.play_slug)) do
      nil ->
        nil

      p ->
        "#{play_name(p.slug)} · #{p.leverage} leverage" <>
          if(p.rationale, do: " — #{p.rationale}", else: "")
    end
  end

  defp leverage_rank("high"), do: 0
  defp leverage_rank("medium"), do: 1
  defp leverage_rank("low"), do: 2
  defp leverage_rank(_), do: 3

  defp briefing_summary(%{job_brief: nil}), do: "not generated"
  defp briefing_summary(_), do: "ready"

  # Every step grouped by its play, in catalog order — only plays that have
  # steps. Each: {play, sorted tasks, leverage, rationale}. Done tasks included
  # (the checklist shows them struck-through and stays uncheckable).
  defp checklist_groups(job) do
    by_play = Enum.group_by(job.tasks, & &1.play_slug)
    jp = Map.new(job.job_plays, &{&1.slug, &1})

    Plays.all()
    |> Enum.map(fn play -> {play, Map.get(by_play, play.slug, [])} end)
    |> Enum.reject(fn {_play, tasks} -> tasks == [] end)
    |> Enum.map(fn {play, tasks} ->
      j = jp[play.slug]
      {play, Enum.sort_by(tasks, & &1.position), j && j.leverage, j && j.rationale}
    end)
  end

  defp outreach_summary(job) do
    reach = length(job.networking_targets)
    saved = length(job.contacts)

    parts =
      [reach > 0 && "#{reach} to reach", saved > 0 && "#{saved} saved"]
      |> Enum.filter(& &1)

    if parts == [], do: "no one yet", else: Enum.join(parts, " · ")
  end

  attr :label, :string, required: true
  attr :text, :string, required: true

  defp brief_part(assigns) do
    ~H"""
    <div>
      <p class="font-semibold uppercase tracking-wider text-[10px] opacity-50 mb-1">{@label}</p>
      <p class="text-sm leading-relaxed opacity-85 whitespace-pre-line">{@text}</p>
    </div>
    """
  end

  attr :tasks, :list, required: true
  attr :empty, :string, default: ""

  defp task_list(assigns) do
    ~H"""
    <ul class="space-y-1.5">
      <li :for={task <- @tasks} class="flex items-center gap-2.5 group/task">
        <input
          type="checkbox"
          checked={task.done}
          phx-click="toggle_task"
          phx-value-id={task.id}
          class="checkbox checkbox-xs checkbox-success"
        />
        <span class={["text-sm flex-1 leading-snug", task.done && "line-through opacity-40"]}>
          {task.title}
        </span>
        <button
          type="button"
          phx-click="delete_task"
          phx-value-id={task.id}
          class="opacity-0 group-hover/task:opacity-50 hover:!opacity-100 transition-opacity"
          aria-label="Delete step"
        >
          <.icon name="hero-x-mark-micro" class="size-3.5" />
        </button>
      </li>
    </ul>
    <p :if={@tasks == [] && @empty != ""} class="text-xs opacity-40 italic">{@empty}</p>
    """
  end

  attr :leverage, :string, required: true

  defp leverage_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-xs border-0 font-semibold uppercase tracking-wide",
      leverage_badge_class(@leverage)
    ]}>
      {@leverage}
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

  attr :job, :map, required: true

  defp fit_badge(assigns) do
    ~H"""
    <span
      :if={@job.fit_score}
      class={[
        "badge badge-xs gap-1 border-0 font-semibold tabular-nums shrink-0",
        fit_color(@job.fit_score)
      ]}
      title={@job.fit_summary}
      aria-label={"Fit #{@job.fit_score} of 5"}
    >
      fit {@job.fit_score}
    </span>
    """
  end

  ## Logic helpers

  defp route_label(job) do
    recommended =
      Enum.filter(job.job_plays, &(Plays.recommended?(&1.leverage) and &1.slug != "apply"))

    cond do
      job.job_plays == [] -> "Not assessed yet"
      recommended == [] -> "Front door — cold apply"
      true -> "Side door — " <> Enum.map_join(recommended, ", ", &play_name(&1.slug))
    end
  end

  defp freeform_tasks(job), do: Enum.filter(job.tasks, &is_nil(&1.play_slug))

  defp play_name(slug) do
    case Plays.get(slug) do
      nil -> slug
      play -> play.name
    end
  end

  defp leverage_badge_class("high"), do: "bg-emerald-500/15 text-emerald-400"
  defp leverage_badge_class("medium"), do: "bg-amber-500/15 text-amber-400"
  defp leverage_badge_class("low"), do: "bg-zinc-500/15 text-zinc-400"
  defp leverage_badge_class(_), do: "bg-base-content/10 opacity-50"

  defp fit_color(score) when score >= 4, do: "bg-emerald-500/15 text-emerald-500"
  defp fit_color(3), do: "bg-amber-500/15 text-amber-500"
  defp fit_color(_), do: "bg-rose-500/15 text-rose-500"

  defp aging_label(job) do
    case DateTime.diff(DateTime.utc_now(), job.stage_entered_at, :day) do
      0 -> "added today"
      1 -> "1 day in #{String.downcase(job.stage.name)}"
      days -> "#{days} days in #{String.downcase(job.stage.name)}"
    end
  end

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

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_binary(value), do: String.to_integer(value)
end
