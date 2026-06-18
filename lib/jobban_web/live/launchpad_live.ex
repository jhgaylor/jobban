defmodule JobbanWeb.LaunchpadLive do
  use JobbanWeb, :live_view

  @moduledoc """
  The private prep view for the wishlist→applied gap. A matrix of listings ×
  plays: for each listing the strategist rates every way-in (networking, pitch,
  build, blog, cold apply) for leverage and auto-populates the recommended
  plays' steps. The matrix shows which listings need which plays at a glance;
  the detail panel works one listing's plays, steps, and contacts.

  Admin-only — everything here is the strategic layer the public board hides, so
  the whole page redirects non-admins rather than partially gating.
  """

  alias Jobban.Board
  alias Jobban.Board.Plays
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
         assessing?: false
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
        assign(socket, selected_id: nil, contact_form: nil)
      else
        socket
      end

    {:noreply, socket}
  end

  # Defense in depth — mount already redirects non-admins, but never trust the
  # client. Every mutating event funnels through this guard first.
  @write_events ~w(select_job close_detail reassess add_task toggle_task delete_task
                   add_contact validate_contact delete_contact toggle_reached)

  @impl true
  def handle_event(event, _params, %{assigns: %{admin?: false}} = socket)
      when event in @write_events do
    {:noreply, put_flash(socket, :error, "Log in to make changes")}
  end

  def handle_event("select_job", %{"id" => id}, socket) do
    case Board.get_job(to_int(id)) do
      nil -> {:noreply, socket}
      job -> {:noreply, assign(socket, selected_id: job.id, contact_form: blank_contact_form())}
    end
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, selected_id: nil, contact_form: nil)}
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

  ## Internals

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
            <p class="text-xs opacity-50 mt-1 truncate">which listing needs which way in</p>
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
        <div class="max-w-3xl mx-auto">
          <div
            :if={@jobs != []}
            class="rounded-2xl bg-base-100 border border-base-content/8 shadow-sm overflow-x-auto"
          >
            <table class="w-full table-fixed text-sm border-collapse">
              <thead>
                <tr class="border-b border-base-content/10 text-[10px] uppercase tracking-wider opacity-50">
                  <th class="text-left font-semibold py-2.5 pl-4 pr-2">Listing</th>
                  <th
                    :for={{play, idx} <- Enum.with_index(@plays)}
                    class={[
                      "font-semibold w-12 text-center",
                      if(idx == 0,
                        do: "border-l-2 border-base-content/10",
                        else: "border-l border-base-content/5"
                      )
                    ]}
                    title={play.name}
                  >
                    {play.short}
                  </th>
                  <th class="font-semibold w-16 px-3 text-right border-l-2 border-base-content/10">
                    Prep
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={job <- @jobs}
                  phx-click="select_job"
                  phx-value-id={job.id}
                  class="border-b border-base-content/5 last:border-0 cursor-pointer hover:bg-base-content/[0.05] odd:bg-base-content/[0.015] transition-colors"
                >
                  <td class="py-2 pl-4 pr-3 max-w-0">
                    <div class="flex items-center gap-2.5 min-w-0">
                      <.company_avatar company={job.company} class="size-8 text-[11px]" />
                      <div class="min-w-0">
                        <div class="flex items-center gap-1.5 min-w-0">
                          <span class="font-semibold truncate">{job.company}</span>
                          <.fit_badge job={job} />
                        </div>
                        <p class="text-xs opacity-55 truncate">{job.title}</p>
                      </div>
                    </div>
                  </td>
                  <td
                    :for={{play, idx} <- Enum.with_index(@plays)}
                    class={[
                      "text-center",
                      if(idx == 0,
                        do: "border-l-2 border-base-content/10",
                        else: "border-l border-base-content/5"
                      )
                    ]}
                  >
                    <.play_cell job={job} slug={play.slug} />
                  </td>
                  <td class="text-right px-3 tabular-nums text-xs opacity-60 whitespace-nowrap border-l-2 border-base-content/10">
                    {progress_label(job)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div :if={@jobs == []} class="text-center py-20 opacity-50">
            <.icon name="hero-check-circle" class="size-10 mx-auto mb-3 opacity-40" />
            <p class="text-sm">Nothing waiting on prep — every wishlist is launched.</p>
          </div>

          <div
            :if={@jobs != []}
            class="flex flex-wrap items-center gap-x-4 gap-y-1 mt-3 px-1 text-[11px] opacity-50"
          >
            <span class="flex items-center gap-1">
              <span class="text-emerald-400 font-bold">●</span> high
            </span>
            <span class="flex items-center gap-1">
              <span class="text-amber-400 font-bold">●</span> medium
            </span>
            <span class="flex items-center gap-1">
              <span class="text-zinc-400 font-bold">●</span> low
            </span>
            <span class="flex items-center gap-1"><span class="font-bold">◐</span> in progress</span>
            <span class="flex items-center gap-1">
              <span class="text-emerald-400 font-bold">✓</span> done
            </span>
            <span class="flex items-center gap-1"><span>·</span> skip</span>
            <span class="flex items-center gap-1"><span>–</span> not assessed</span>
          </div>
        </div>
      </main>

      <.detail
        :if={@job}
        job={@job}
        plays={@plays}
        contact_form={@contact_form}
        assessing?={@assessing?}
      />
      <Layouts.flash_group flash={@flash} />
    </div>
    """
  end

  attr :job, :map, required: true
  attr :slug, :string, required: true

  defp play_cell(assigns) do
    {state, leverage} = play_state(assigns.job, assigns.slug)
    jp = Enum.find(assigns.job.job_plays, &(&1.slug == assigns.slug))

    assigns =
      assign(assigns, state: state, color: leverage_color(leverage), title: jp && jp.rationale)

    ~H"""
    <span
      class={["inline-block py-2 text-base font-bold select-none leading-none", @color]}
      title={@title}
    >
      <%= case @state do %>
        <% :done -> %>
          ✓
        <% :in_progress -> %>
          ◐
        <% :recommended -> %>
          ●
        <% :skip -> %>
          <span class="opacity-30">·</span>
        <% :unassessed -> %>
          <span class="opacity-30">–</span>
      <% end %>
    </span>
    """
  end

  attr :job, :map, required: true
  attr :plays, :list, required: true
  attr :contact_form, :any, required: true
  attr :assessing?, :boolean, required: true

  defp detail(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 grid place-items-center p-4 sm:p-6 bg-black/40 backdrop-blur-sm animate-fade-in"
      role="dialog"
      aria-modal="true"
      phx-window-keydown="close_detail"
      phx-key="escape"
    >
      <div
        class="w-full max-w-2xl max-h-full overflow-y-auto rounded-2xl bg-base-100 shadow-2xl border border-base-content/10 animate-pop-in"
        phx-click-away="close_detail"
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

        <p
          :if={@job.job_plays == []}
          class="mx-5 mt-4 rounded-xl bg-base-200/60 p-4 text-sm opacity-60 italic"
        >
          Not assessed yet — {if Strategist.enabled?(),
            do: "hit Re-assess to have the strategist rate the plays.",
            else: "set an OpenRouter key to enable the strategist."}
        </p>

        <%!-- One card per play, in catalog order --%>
        <.play_card :for={play <- @plays} job={@job} play={play} />

        <%!-- Freeform steps not tied to a play --%>
        <div class="mx-5 mt-4 rounded-xl bg-base-200/50 border border-base-content/8 p-4">
          <h4 class="text-xs font-semibold uppercase tracking-wider opacity-50 flex items-center gap-1.5 mb-3">
            <.icon name="hero-plus-circle-micro" class="size-3.5" /> Other steps
          </h4>
          <.task_list tasks={freeform_tasks(@job)} empty="No extra steps." />
          <form phx-submit="add_task" class="flex gap-2 mt-3">
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

        <%!-- Contacts --%>
        <div class="mx-5 my-4 rounded-xl bg-indigo-500/8 border border-indigo-500/15 p-4">
          <h4 class="text-xs font-semibold uppercase tracking-wider text-indigo-400 flex items-center gap-1.5 mb-3">
            <.icon name="hero-users-micro" class="size-3.5" /> Contacts
          </h4>

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
        </div>
      </div>
    </div>
    """
  end

  attr :job, :map, required: true
  attr :play, :map, required: true

  defp play_card(assigns) do
    jp = Enum.find(assigns.job.job_plays, &(&1.slug == assigns.play.slug))
    tasks = tasks_for(assigns.job, assigns.play.slug)
    assigns = assign(assigns, jp: jp, tasks: tasks)

    ~H"""
    <div :if={@jp} class={["mx-5 mt-4 rounded-xl border p-4", play_panel_class(@jp.leverage)]}>
      <div class="flex items-center gap-2 mb-1.5">
        <h4 class="text-sm font-semibold flex items-center gap-1.5">{@play.name}</h4>
        <.leverage_badge leverage={@jp.leverage} />
      </div>
      <p :if={@jp.rationale} class="text-xs opacity-70 leading-snug mb-2.5">{@jp.rationale}</p>

      <.task_list :if={@tasks != []} tasks={@tasks} empty="" />
      <p :if={@tasks == [] && @jp.leverage != "skip"} class="text-xs opacity-40 italic">
        No specific steps suggested.
      </p>
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

  defp play_state(job, slug) do
    jp = Enum.find(job.job_plays, &(&1.slug == slug))
    tasks = tasks_for(job, slug)

    state =
      cond do
        jp == nil -> :unassessed
        jp.leverage == "skip" -> :skip
        tasks != [] and Enum.all?(tasks, & &1.done) -> :done
        Enum.any?(tasks, & &1.done) -> :in_progress
        true -> :recommended
      end

    {state, jp && jp.leverage}
  end

  defp route_label(job) do
    recommended =
      Enum.filter(job.job_plays, &(Plays.recommended?(&1.leverage) and &1.slug != "apply"))

    cond do
      job.job_plays == [] -> "Not assessed yet"
      recommended == [] -> "Front door — cold apply"
      true -> "Side door — " <> Enum.map_join(recommended, ", ", &play_name(&1.slug))
    end
  end

  defp tasks_for(job, slug), do: Enum.filter(job.tasks, &(&1.play_slug == slug))
  defp freeform_tasks(job), do: Enum.filter(job.tasks, &is_nil(&1.play_slug))

  defp progress_label(job) do
    total = length(job.tasks)
    done = Enum.count(job.tasks, & &1.done)
    "#{done}/#{total}"
  end

  defp play_name(slug) do
    case Plays.get(slug) do
      nil -> slug
      play -> play.name
    end
  end

  defp leverage_color("high"), do: "text-emerald-400"
  defp leverage_color("medium"), do: "text-amber-400"
  defp leverage_color("low"), do: "text-zinc-400"
  defp leverage_color(_), do: "opacity-30"

  defp leverage_badge_class("high"), do: "bg-emerald-500/15 text-emerald-400"
  defp leverage_badge_class("medium"), do: "bg-amber-500/15 text-amber-400"
  defp leverage_badge_class("low"), do: "bg-zinc-500/15 text-zinc-400"
  defp leverage_badge_class(_), do: "bg-base-content/10 opacity-50"

  defp play_panel_class("skip"), do: "border-base-content/8 bg-base-200/40 opacity-60"
  defp play_panel_class(_), do: "border-base-content/10 bg-base-200/50"

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
