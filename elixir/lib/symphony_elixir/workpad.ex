defmodule SymphonyElixir.Workpad do
  @moduledoc """
  Builds and recognizes the persistent Linear workpad comment body.
  """

  @header "## Codex Workpad"

  @spec header() :: String.t()
  def header, do: @header

  @spec bootstrap_body(String.t()) :: String.t()
  def bootstrap_body(environment_stamp) when is_binary(environment_stamp) do
    """
    #{@header}

    ```text
    #{String.trim(environment_stamp)}
    ```

    ### Plan

    - [ ] 1\. Parent task
      - [ ] 1.1 Child task
      - [ ] 1.2 Child task
    - [ ] 2\. Parent task

    ### Acceptance Criteria

    - [ ] Criterion 1
    - [ ] Criterion 2

    ### Validation

    - [ ] targeted tests: `<command>`

    ### Notes

    - Bootstrap created by Symphony.
    """
    |> String.trim_trailing()
  end

  @spec workpad_comment?(String.t() | nil) :: boolean()
  def workpad_comment?(body) when is_binary(body) do
    String.starts_with?(String.trim_leading(body), @header)
  end

  def workpad_comment?(_body), do: false
end
