defmodule Coherence.Socket do

  use Coherence.Config

  import Coherence.Authentication.Utils, only: [random_string: 1]
  import Coherence.{Controller, EmailService, InvitationService,  LockableService,
    PasswordService, TrackableService}

  alias Coherence.{ConfirmableService, Messages, Schemas}

  @endpoint Module.concat(Config.web_module, Endpoint)
  @schema Module.concat(Config.module, Schemas)

  @type socket :: Phoenix.Socket.t
  @type params :: Map.t

  @doc """
  Allows to block / unblock users
  """
  def block_users(socket, %{ "users" => users, "reason" => reason }) do
    exclude_me = Enum.member? users, user_id(socket)
    users = if exclude_me,
      do: List.delete(users, user_id(socket)),
      else: users

    case Config.user_schema.validate_blocked(reason) do
      {:ok, changes } ->
        case Schemas.update_users(users, changes) do
          {count, users} ->
            broadcast "users_updated", %{users: render_users(users)}
            if exclude_me do
              return_ok socket, "You have successfully updated #{count} users! No changes were made on your account."
            else
              return_ok socket, "You have successfully updated #{count} users!"
            end
          _ ->
            return_error socket, "Something went wrong while updating users!"
        end
      {:error, flash } ->
        return_error(socket, flash)
    end
  end

  @doc """
  Create the new user account.
  Create and send a confirmation, if this option is enabled.
  Broadcasts updated user to feedback channel, if this option is enabled.
  """
  @spec create_user(socket, params) :: {:reply, {atom, Map.t}, socket}
  def create_user(socket, params) do
    case Schemas.create_user params do
      {:ok, user} ->
        broadcast "user_created", render_user(user)
        case ConfirmableService.send_confirmation(user) do
          {:ok, flash}    -> return_ok(socket, flash)
          {:error, flash} -> return_error(socket, flash)
        end
      {:error, changeset} ->
        return_error socket, %{errors: error_map(changeset)}
    end
  end

  @doc """
  Allows to change own password, email or name though the /settings page
  """
  def update_profile(socket, params) do
    case Schemas.get_user(user_id(socket)) do
      nil ->
        return_error(socket, Messages.backend().invalid_request())
      user ->
        Config.user_schema.changeset(user, params, :settings)
        |> Schemas.update
        |> case do
            {:ok, user} ->
              broadcast "users_updated", %{users: [render_user(user)]}
              if params["current_password"], do:
                track_password_reset(user, Config.user_schema.trackable_table?)
              return_ok(socket, Messages.backend().account_updated_successfully())
            {:error, changeset} ->
              return_error socket, %{errors: error_map(changeset)}
          end
    end
  end

  @doc """
  Resends a confirmation email with a new token to the account with given email
  """
  def create_confirmation(socket, params) do
    changeset = Config.user_schema.changeset(params, :email)
    if Map.has_key?(error_map(changeset), :email) do
      return_error socket, %{errors: error_map(changeset)}
    else
      case Schemas.get_user_by_email params["email"] do
        nil ->
          return_error(socket, Messages.backend().could_not_find_that_email_address())
        user ->
          if Config.user_schema.confirmed?(user) do
            return_error(socket, Messages.backend().account_already_confirmed())
          else
            case ConfirmableService.send_confirmation(user) do
              {:ok, flash}    -> return_ok(socket, flash)
              {:error, flash} -> return_error(socket, flash)
            end
          end
      end
    end
  end

  @doc """
  Handle the user's click on the confirm link in the confirmation email.
  Validate that the confirmation token has not expired and sets `confirmation_sent_at`
  field to nil, marking the user as confirmed.
  """
  @spec handle_confirmation(socket, params) :: {:reply, {atom, Map.t}, socket}
  def handle_confirmation(socket, %{"token" => token}) do
    case Schemas.get_by_user confirmation_token: token do
      nil ->
        return_error socket, Messages.backend().invalid_confirmation_token()
      user ->
        if ConfirmableService.expired? user do
          return_error socket, Messages.backend().confirmation_token_expired()
        else
          changeset = Config.user_schema.changeset(user, %{
            confirmation_token: nil,
            confirmed_at: NaiveDateTime.utc_now(),
          })
          case Config.repo.update(changeset) do
            {:ok, user} ->
              broadcast "users_updated", %{users: [render_user(user)]}
              return_ok socket, Messages.backend().user_account_confirmed_successfully()
            {:error, _changeset} ->
              return_error socket, Messages.backend().problem_confirming_user_account()
          end
        end
    end
  end

  @doc """
  Create the recovery token and send the email
  """
  @spec create_recover(socket, params) :: {:reply, {atom, Map.t}, socket}
  def create_recover(socket, %{"email" => email} = params) do
    cs = Config.user_schema.changeset(params, :email)
    if Map.has_key?(error_map(cs), :email) do
      return_error socket, %{errors: error_map(cs)}
    else
      case Schemas.get_user_by_email email do
        nil ->
          return_error(socket, Messages.backend().could_not_find_that_email_address())
        user ->
          token = random_string 48
          # update database
          Config.repo.update! Config.user_schema.changeset(user, %{
            reset_password_token: token,
            reset_password_sent_at: NaiveDateTime.utc_now()
          }, :password)
          # send token via email
          if Config.mailer?() do
            send_user_email :password, user, password_url(token)
            return_ok(socket, Messages.backend().reset_email_sent())
          else
            return_error(socket, Messages.backend().mailer_required())
          end
      end
    end
  end

  @doc """
  Verify the new password and update the database
  """
  @spec handle_recover(socket, params) :: {:reply, {atom, Map.t}, socket}
  def handle_recover(socket, params) do
    user_schema = Config.user_schema
    case Schemas.get_by_user reset_password_token: params["token"] do
      nil -> return_error(socket, Messages.backend().invalid_reset_token())
      user ->
        if expired? user.reset_password_sent_at, days: Config.reset_token_expire_days do
          :password
          |> changeset(user_schema, user, clear_password_params())
          |> Schemas.update
          return_error(socket, Messages.backend().password_reset_token_expired())
        else
          params = clear_password_params params
          :password
          |> changeset(user_schema, user, params)
          |> Schemas.update
          |> case do
            {:ok, user} ->
              track_password_reset(user, user_schema.trackable_table?)
              return_ok(socket, Messages.backend().password_updated_successfully())
            {:error, changeset} ->
              return_error socket, %{errors: error_map(changeset)}
          end
        end
    end
  end

  @doc """
  Create and send the unlock token.
  """
  @spec create_unlock(socket, params) :: {:reply, {:ok | :error, Map.t}, socket}
  def create_unlock(socket, params) do
    user_schema = Config.user_schema()
    email = params["email"]
    password = params["password"]
    user = Schemas.get_user_by_email(email)

    if user != nil and user_schema.checkpw(password, Map.get(user, Config.password_hash)) do
      case unlock_token(user) do
        {:ok, user} ->
          if user_schema.locked?(user) do
            case send_unlock_email(user) do
              {:ok, flash} -> return_ok socket, flash
              {:error, flash} -> return_error socket, flash
            end
          else
            return_error socket, Messages.backend().your_account_is_not_locked()
          end
        {:error, changeset} ->
          return_error socket, %{errors: error_map(changeset)}
      end
    else
      return_error socket, Messages.backend().invalid_email_or_password()
    end
  end

  @doc """
  Handle the unlock link click.
  """
  @spec handle_unlock(socket, params) :: {:reply, {:ok | :error, Map.t}, socket}
  def handle_unlock(socket, params) do
    user_schema = Config.user_schema
    token = params["id"]
    case Schemas.get_by_user unlock_token: token do
      nil ->
        return_error socket, Messages.backend().invalid_unlock_token()
      user ->
        if user_schema.locked? user do
          unlock! user
          track_unlock_token(user, user_schema.trackable_table?)
          return_ok socket, Messages.backend().your_account_has_been_unlocked()
        else
          clear_unlock_values(user, user_schema)
          return_error socket, Messages.backend().account_is_not_locked()
        end
    end
  end

  @doc """
  Generate and send an invitation token.
  Creates a new invitation token, save it to the database and send
  the invitation email.
  """
  @spec create_invitations(socket, params) :: {:reply, {:ok | :error, Map.t}, socket}
  def create_invitations(socket, %{"invitations" => invitations}) do
    result = for i <- invitations do
      {name, email} = {Enum.at(i, 0), Enum.at(i, 1)}
      changeset = Schemas.change_invitation %{"name" => name, "email" => email}
      case Schemas.get_user_by_email email do
        nil ->
          token = random_string 48
          url = invitation_url(token) <> "/edit"
          changeset = Ecto.Changeset.put_change(changeset, :token, token)

          case Schemas.create_invitation changeset do
            {:ok, invitation} ->
              send_user_email :invitation, invitation, url
              1
            {:error, _changeset} ->
              case Schemas.get_by_invitation email: email do
                nil -> -1
                _invitation -> 0
              end
          end
        _ -> 0
      end
    end

    # count created invitations, already registered users and unknown errors
    successes = count(result, 1)
    errors_registered = count(result, 0)
    errors_unknown = count(result, -1)

    fb = "#{successes}/#{length(invitations)} users successfully invited."

    fb = if errors_registered > 0,
      do: fb <> "<br>#{errors_registered} users ignored (already registered or invited).",
      else: fb

    fb = if errors_unknown > 0,
      do: fb <> "<br>#{errors_unknown} users were not invited because of an unknown error.",
      else: fb
    return_ok socket, fb
  end

  defp count(list, val), do: Enum.count(list, fn(x) -> x == val end)

  defp broadcast(event, data) do
    apply @endpoint, :broadcast, [ Config.feedback_channel, event, data ]
  end

  defp user_id(socket), do: Map.get(socket.assigns, :user_id, nil)

  # return flash message or map
  defp return_ok(socket, data) when is_binary(data), do: {:reply, {:ok, %{ flash: data}}, socket}
  defp return_ok(socket, data) when is_map(data),    do: {:reply, {:ok, data}, socket}

  defp return_error(socket, data) when is_binary(data), do: {:reply, {:error, %{ flash: data}}, socket}
  defp return_error(socket, data) when is_map(data),    do: {:reply, {:error, data}, socket}

  # formats user struct(s) and returns a (list of) map(s) with appropriate fields
  defp render_user(user), do: apply @schema, :render_user, [ user ]
  defp render_users(users), do: apply @schema, :render_users, [ users ]

  # Generates a map with all invalid fields and their first error
  defp error_map(changeset), do:
    Map.new(changeset.errors, fn ({k, v}) -> {k, elem(v, 0)} end)
end
