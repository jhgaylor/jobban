defmodule JobbanWeb.LaunchpadLive do
  use JobbanWeb, :live_view

  @moduledoc """
  The private prep view for the wishlist→applied gap: a prioritized worklist of
  jobs that still need work, each with its way-in playbook, readiness checklist,
  and contacts. Admin-only — everything here (approach, contacts, prep) is the
  strategic layer the public board deliberately hides, so the whole page is
  gated rather than partially hidden.
  """

  alias Jobban.Board
  alias Jobban.WayInSuggester

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
         way_in_form: nil,
         contact_form: nil,
         suggested_steps: [],
         suggesting?: false
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

    # If the selected job dropped off the worklist (deleted, or applied with
    # everything checked off), close the detail panel.
    socket =
      if socket.assigns.selected_id && selected(socket.assigns) == nil do
        assign(socket, selected_id: nil, way_in_form: nil, contact_form: nil, suggested_steps: [])
      else
        socket
      end

    {:noreply, socket}
  end

  # Defense in depth — mount already redirects non-admins, but never trust the
  # client. Every mutating event funnels through this guard first.
  @write_events ~w(select_job close_detail validate_way_in save_way_in suggest_way_in
                   add_task toggle_task delete_task add_suggested_step
                   add_contact validate_contact delete_contact toggle_reached)

  @impl true
  def handle_event(event, _params, %{assigns: %{admin?: false}} = socket)
      when event in @write_events do
    {:noreply, put_flash(socket, :error, "Log in to make changes")}
  end

  def handle_event("select_job", %{"id" => id}, socket) do
    case Board.get_job(to_int(id)) do
      nil -> {:noreply, socket}
      job -> {:noreply, open_detail(socket, job)}
    end
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply,
     assign(socket, selected_id: nil, way_in_form: nil, contact_form: nil, suggested_steps: [])}
  end

  def handle_event("validate_way_in", %{"job" => params}, socket) do
    form =
      current_job(socket)
      |> Board.change_job(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, way_in_form: form)}
  end

  def handle_event("save_way_in", %{"job" => params}, socket) do
    case Board.update_job(current_job(socket), params) do
      {:ok, job} ->
        {:noreply,
         socket
         |> assign(way_in_form: to_form(Board.change_job(job)), suggested_steps: [])
         |> put_flash(:info, "Way in saved")}

      {:error, changeset} ->
        {:noreply, assign(socket, way_in_form: to_form(changeset))}
    end
  end

  def handle_event("suggest_way_in", _params, socket) do
    job = current_job(socket)

    cond do
      job == nil ->
        {:noreply, socket}

      WayInSuggester.enabled?() ->
        {:noreply,
         socket
         |> assign(suggesting?: true)
         |> start_async(:suggest, fn -> WayInSuggester.suggest(job) end)}

      true ->
        {:noreply, put_flash(socket, :error, "AI suggestions need an OpenRouter key")}
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

  def handle_event("add_suggested_step", %{"title" => title}, socket) do
    {:ok, _} = Board.add_task(current_job(socket), title)
    {:noreply, update(socket, :suggested_steps, &List.delete(&1, title))}
  end

  def handle_event("add_contact", %{"contact" => params}, socket) do
    case Board.add_contact(current_job(socket), params) do
      {:ok, _contact} ->
        {:noreply, assign(socket, contact_form: blank_contact_form())}

      {:error, changeset} ->
        {:noreply, assign(socket, contact_form: to_form(changeset))}
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
  def handle_async(:suggest, {:ok, {:ok, %{approach: approach, steps: steps}}}, socket) do
    form =
      case current_job(socket) do
        nil -> socket.assigns.way_in_form
        job -> to_form(Board.change_job(job, %{"approach" => approach}))
      end

    {:noreply,
     socket
     |> assign(suggesting?: false, way_in_form: form, suggested_steps: steps)
     |> put_flash(:info, "Draft ready — review, tweak, then save")}
  end

  def handle_async(:suggest, {:ok, {:error, _reason}}, socket) do
    {:noreply,
     socket
     |> assign(suggesting?: false)
     |> put_flash(:error, "Couldn't draft a way in — write it by hand")}
  end

  def handle_async(:suggest, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(suggesting?: false)
     |> put_flash(:error, "AI suggestion crashed — write it by hand")}
  end

  ## Internals

  defp assign_jobs(socket), do: assign(socket, jobs: Board.list_launchpad())

  defp open_detail(socket, job) do
    assign(socket,
      selected_id: job.id,
      way_in_form: to_form(Board.change_job(job)),
      contact_form: blank_contact_form(),
      suggested_steps: []
    )
  end

  defp current_job(socket), do: Board.get_job(socket.assigns.selected_id)

  defp blank_contact_form do
    to_form(Board.change_contact(%Jobban.Board.Contact{}))
  end

  defp selected(%{selected_id: nil}), do: nil
  defp selected(%{selected_id: id, jobs: jobs}), do: Enum.find(jobs, &(&1.id == id))

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :job, selected(assigns))

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
              get every wishlist into the system the right way
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

      <main class="flex-1 overflow-y-auto px-4 sm:px-6 pb-6">
        <div class="max-w-3xl mx-auto space-y-2.5">
          <.job_row :for={job <- @jobs} job={job} />

          <div :if={@jobs == []} class="text-center py-20 opacity-50">
            <.icon name="hero-check-circle" class="size-10 mx-auto mb-3 opacity-40" />
            <p class="text-sm">Nothing waiting on prep — every wishlist is launched.</p>
          </div>
        </div>
      </main>

      <.detail
        :if={@job}
        job={@job}
        way_in_form={@way_in_form}
        contact_form={@contact_form}
        suggested_steps={@suggested_steps}
        suggesting?={@suggesting?}
      />
      <Layouts.flash_group flash={@flash} />
    </div>
    """
  end

  attr :job, :map, required: true

  defp job_row(assigns) do
    {done, total} = progress(assigns.job)
    assigns = assign(assigns, done: done, total: total, next: next_step(assigns.job))

    ~H"""
    <button
      type="button"
      phx-click="select_job"
      phx-value-id={@job.id}
      class="w-full text-left group rounded-2xl bg-base-100 border border-base-content/8 p-4 shadow-sm hover:shadow-lg hover:-translate-y-0.5 hover:border-base-content/15 transition-all duration-200"
    >
      <div class="flex items-start gap-3">
        <.company_avatar company={@job.company} class="size-10 text-sm" />
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2 min-w-0">
            <p class="font-semibold text-sm truncate">{@job.company}</p>
            <.stage_chip slug={@job.stage.slug} name={@job.stage.name} />
          </div>
          <p class="text-xs opacity-70 truncate mt-0.5">{@job.title}</p>
        </div>
        <div class="flex items-center gap-1.5 shrink-0">
          <.fit_badge job={@job} />
          <.stars value={@job.excitement} class="text-[10px]" />
        </div>
      </div>

      <div class="flex items-center gap-3 mt-3">
        <div class="flex-1 min-w-0">
          <div :if={@next} class="flex items-center gap-1.5 text-xs">
            <span class="font-semibold uppercase tracking-wider text-sky-500 text-[10px]">Next</span>
            <span class="truncate opacity-80">{@next}</span>
          </div>
          <div :if={!@next} class="flex items-center gap-1.5 text-xs text-emerald-500">
            <.icon name="hero-check-circle-micro" class="size-3.5" />
            <span class="opacity-90">Prep complete</span>
          </div>
        </div>

        <span
          :if={@job.contacts != []}
          class="badge badge-ghost badge-xs gap-1 py-2"
          title={"#{length(@job.contacts)} contact(s)"}
        >
          <.icon name="hero-users-micro" class="size-3 opacity-60" />{length(@job.contacts)}
        </span>

        <div class="flex items-center gap-2 shrink-0">
          <div class="w-16 h-1.5 rounded-full bg-base-content/10 overflow-hidden">
            <div
              class="h-full bg-emerald-500/70 rounded-full"
              style={"width: #{pct(@done, @total)}%"}
            />
          </div>
          <span class="text-[10px] font-semibold tabular-nums opacity-60">{@done}/{@total}</span>
        </div>
      </div>
    </button>
    """
  end

  attr :job, :map, required: true
  attr :way_in_form, :any, required: true
  attr :contact_form, :any, required: true
  attr :suggested_steps, :list, required: true
  attr :suggesting?, :boolean, required: true

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
            <p class="text-xs opacity-50 mt-1 flex items-center gap-1.5">
              <.stage_chip slug={@job.stage.slug} name={@job.stage.name} />
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
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-circle"
            phx-click="close_detail"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <%!-- Way in --%>
        <div class="mx-5 mt-4 rounded-xl bg-violet-500/8 border border-violet-500/15 p-4">
          <h4 class="text-xs font-semibold uppercase tracking-wider text-violet-400 flex items-center gap-1.5 mb-2">
            <.icon name="hero-map-micro" class="size-3.5" /> Way in
            <button
              :if={WayInSuggester.enabled?()}
              type="button"
              class="btn btn-ghost btn-xs ml-auto gap-1 opacity-60 hover:opacity-100"
              phx-click="suggest_way_in"
              disabled={@suggesting?}
            >
              <.icon
                name={if @suggesting?, do: "hero-arrow-path-micro", else: "hero-sparkles-micro"}
                class={["size-3", @suggesting? && "animate-spin"]}
              /> {if @suggesting?, do: "Drafting…", else: "Suggest"}
            </button>
          </h4>
          <.form for={@way_in_form} phx-change="validate_way_in" phx-submit="save_way_in">
            <textarea
              id="way-in-body"
              name={@way_in_form[:approach].name}
              rows="5"
              placeholder="Route in, the story to tell, the referral plan…"
              class="textarea textarea-sm w-full leading-snug bg-base-100"
            >{Phoenix.HTML.Form.normalize_value("textarea", @way_in_form[:approach].value)}</textarea>
            <div
              :if={@suggested_steps != []}
              class="flex flex-wrap gap-1.5 mt-2.5"
            >
              <span class="text-[10px] uppercase tracking-wider opacity-50 self-center">
                Suggested steps:
              </span>
              <button
                :for={step <- @suggested_steps}
                type="button"
                phx-click="add_suggested_step"
                phx-value-title={step}
                class="badge badge-sm gap-1 bg-violet-500/15 text-violet-400 border-0 hover:bg-violet-500/25"
              >
                <.icon name="hero-plus-micro" class="size-3" />{step}
              </button>
            </div>
            <div class="flex justify-end mt-2.5">
              <button type="submit" class="btn btn-primary btn-sm px-5">Save way in</button>
            </div>
          </.form>
        </div>

        <%!-- Checklist --%>
        <div class="mx-5 mt-4 rounded-xl bg-emerald-500/8 border border-emerald-500/15 p-4">
          <h4 class="text-xs font-semibold uppercase tracking-wider text-emerald-400 flex items-center gap-1.5 mb-3">
            <.icon name="hero-clipboard-document-check-micro" class="size-3.5" /> Checklist
            <span class="ml-auto tabular-nums opacity-70 normal-case tracking-normal">
              {elem(progress(@job), 0)}/{elem(progress(@job), 1)} done
            </span>
          </h4>

          <ul class="space-y-1.5">
            <li :for={task <- @job.tasks} class="flex items-center gap-2.5 group/task">
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
                aria-label="Delete task"
              >
                <.icon name="hero-x-mark-micro" class="size-3.5" />
              </button>
            </li>
          </ul>

          <form phx-submit="add_task" class="flex gap-2 mt-3">
            <input
              name="task[title]"
              placeholder="Add a step…"
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

  ## Presentation helpers

  attr :slug, :string, required: true
  attr :name, :string, required: true

  defp stage_chip(assigns) do
    color =
      case assigns.slug do
        "wishlist" -> "bg-violet-500/15 text-violet-400"
        "applied" -> "bg-sky-500/15 text-sky-400"
        _ -> "bg-base-content/10 opacity-70"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={["badge badge-xs border-0 font-medium shrink-0", @color]}>{@name}</span>
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
  attr :class, :string, default: ""

  defp fit_badge(assigns) do
    ~H"""
    <span
      :if={@job.fit_score}
      class={[
        "badge badge-xs gap-1 border-0 font-semibold tabular-nums py-2",
        fit_color(@job.fit_score),
        @class
      ]}
      title={@job.fit_summary}
      aria-label={"Fit #{@job.fit_score} of 5"}
    >
      <.icon name="hero-scale-micro" class="size-3" /> fit {@job.fit_score}
    </span>
    """
  end

  defp fit_color(score) when score >= 4, do: "bg-emerald-500/15 text-emerald-500"
  defp fit_color(3), do: "bg-amber-500/15 text-amber-500"
  defp fit_color(_), do: "bg-rose-500/15 text-rose-500"

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

  defp progress(job) do
    total = length(job.tasks)
    done = Enum.count(job.tasks, & &1.done)
    {done, total}
  end

  defp next_step(job) do
    case Enum.find(job.tasks, &(not &1.done)) do
      nil -> nil
      task -> task.title
    end
  end

  defp pct(_done, 0), do: 0
  defp pct(done, total), do: round(done / total * 100)

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
