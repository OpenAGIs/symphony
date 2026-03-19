defmodule SymphonyElixir.LocalTrackerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Local

  test "local tracker fetches candidate issues from a file-backed store" do
    tracker_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "issues.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_active_states: ["Todo", "In Progress"]
    )

    File.write!(
      tracker_path,
      Jason.encode!(
        %{
          "issues" => [
            %{
              "id" => "issue-1",
              "identifier" => "LOC-1",
              "title" => "First local issue",
              "description" => "todo body",
              "priority" => 1,
              "state" => "Todo",
              "labels" => ["Infra", "Backend"],
              "assigned_to_worker" => true
            },
            %{
              "id" => "issue-2",
              "identifier" => "LOC-2",
              "title" => "Blocked local issue",
              "state" => "Done",
              "assigned_to_worker" => true
            }
          ]
        },
        pretty: true
      )
    )

    assert {:ok, [%Issue{id: "issue-1", identifier: "LOC-1", labels: ["infra", "backend"]}]} =
             Local.fetch_candidate_issues()

    assert {:ok, [%Issue{id: "issue-2", state: "Done"}]} =
             Local.fetch_issues_by_states(["Done"])

    assert {:ok, [%Issue{id: "issue-1"}]} = Local.fetch_issue_states_by_ids(["issue-1"])
  end

  test "local tracker persists comments and state transitions" do
    tracker_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "issues.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(
      tracker_path,
      Jason.encode!(
        %{
          "issues" => [
            %{
              "id" => "issue-1",
              "identifier" => "LOC-1",
              "title" => "Track state",
              "state" => "Todo"
            }
          ]
        },
        pretty: true
      )
    )

    assert :ok = Local.create_comment("issue-1", "first note")
    assert :ok = Local.update_issue_state("issue-1", "In Progress")

    {:ok, payload} = File.read(tracker_path)
    decoded = Jason.decode!(payload)
    [issue] = decoded["issues"]

    assert issue["state"] == "In Progress"
    assert [%{"body" => "first note", "created_at" => created_at}] = issue["comments"]
    assert is_binary(created_at)
    assert is_binary(issue["updated_at"])
  end

  test "local tracker creates issues with generated ids and accepts identifier-based updates" do
    tracker_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "issues.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(tracker_path, Jason.encode!(%{"issues" => []}, pretty: true))

    assert {:ok,
            %Issue{
              id: "local-1",
              identifier: "LOCAL-1",
              title: "Move the remaining workflow entrypoints local",
              priority: 1,
              state: "Todo",
              labels: ["go", "migration"]
            }} =
             Local.create_issue(%{
               "title" => "Move the remaining workflow entrypoints local",
               "priority" => "1",
               "labels" => ["Go", "Migration"]
             })

    assert :ok = Local.update_issue_state("LOCAL-1", "Done")
    assert :ok = Local.create_comment("LOCAL-1", "migration finished")

    assert {:ok, [%Issue{id: "local-1", state: "Done"}]} = Local.list_issues()

    {:ok, payload} = File.read(tracker_path)
    decoded = Jason.decode!(payload)
    [issue] = decoded["issues"]

    assert issue["identifier"] == "LOCAL-1"
    assert issue["state"] == "Done"
    assert [%{"body" => "migration finished"}] = Enum.map(issue["comments"], &Map.take(&1, ["body"]))
  end

  test "local tracker stores attachment metadata and resolves uploaded files" do
    tracker_dir = Path.dirname(Workflow.workflow_file_path())
    tracker_path = Path.join(tracker_dir, "issues.json")
    upload_source = Path.join(tracker_dir, "scope-notes.md")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(tracker_path, Jason.encode!(%{"issues" => []}, pretty: true))
    File.write!(upload_source, "# local scope\r\n\r\nmove attachments into the tracker\r\n")

    assert {:ok, attachment} = Local.store_attachment(upload_source, "../scope-notes.md")
    assert attachment["filename"] == "scope-notes.md"
    assert attachment["content_type"] == "text/markdown"
    assert is_integer(attachment["byte_size"])
    assert Path.type(attachment["path"]) == :relative

    assert {:ok, %Issue{identifier: "LOCAL-1", attachments: [stored_attachment]}} =
             Local.create_issue(%{
               "title" => "Keep uploaded specs inside the local tracker",
               "attachments" => [attachment]
             })

    assert stored_attachment["filename"] == "scope-notes.md"

    assert {:ok,
            %{
              path: attachment_path,
              filename: "scope-notes.md",
              content_type: "text/markdown",
              preview_kind: :text
            }} = Local.fetch_attachment_file("LOCAL-1", stored_attachment["id"])

    assert File.read!(attachment_path) == "# local scope\n\nmove attachments into the tracker\n"
    assert Local.attachment_preview_kind(stored_attachment) == :text

    {:ok, payload} = File.read(tracker_path)
    decoded = Jason.decode!(payload)
    [issue] = decoded["issues"]
    [persisted_attachment] = issue["attachments"]

    assert persisted_attachment["filename"] == "scope-notes.md"
    assert persisted_attachment["path"] == stored_attachment["path"]
  end

  test "local tracker normalizes attachment payloads and surfaces attachment errors" do
    tracker_dir = Path.dirname(Workflow.workflow_file_path())
    tracker_path = Path.join(tracker_dir, "issues.json")
    upload_source = Path.join(tracker_dir, "upload.txt")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(
      tracker_path,
      Jason.encode!(
        %{
          "issues" => [
            %{
              "id" => "issue-raw-1",
              "identifier" => "LOCAL-RAW-1",
              "title" => "Raw attachment payload",
              "state" => "Todo",
              "attachments" => [
                %{
                  "id" => 9,
                  "filename" => 101,
                  "content_type" => "  ",
                  "byte_size" => "12",
                  "path" => "stored/raw.txt",
                  "uploaded_at" => 123
                },
                %{
                  "id" => "attachment-invalid-size",
                  "filename" => "invalid-size.txt",
                  "byte_size" => "oops",
                  "path" => "stored/invalid-size.txt"
                },
                %{"filename" => "missing-fields"},
                "noise"
              ]
            }
          ]
        },
        pretty: true
      )
    )

    assert {:ok, [%Issue{attachments: [attachment, invalid_size_attachment]}]} = Local.list_issues()
    assert attachment["id"] == "9"
    assert attachment["filename"] == "101"
    assert attachment["content_type"] == nil
    assert attachment["byte_size"] == 12
    assert attachment["uploaded_at"] == "123"
    assert invalid_size_attachment["byte_size"] == nil

    assert {:error, :invalid_issue_attachments} =
             Local.create_issue(%{"title" => "Bad attachments", "attachments" => "oops"})

    File.write!(upload_source, "attachment cleanup")

    assert {:ok, attachment_without_type} = Local.store_attachment(upload_source, "two-arity.txt")
    assert attachment_without_type["content_type"] == "text/plain"
    assert :ok = Local.discard_attachment(attachment_without_type)

    assert {:ok, cleanup_attachment} = Local.store_attachment(upload_source, "   ", "   ")
    assert cleanup_attachment["filename"] == "attachment.txt"
    assert cleanup_attachment["content_type"] == "text/plain"
    assert :ok = Local.discard_attachment(cleanup_attachment)

    assert {:error, {:unsupported_attachment_type, "script.py"}} =
             Local.store_attachment(upload_source, "script.py", "text/x-python")

    invalid_text_source = Path.join(tracker_dir, "broken.txt")
    File.write!(invalid_text_source, <<255, 254, 0>>)

    assert {:error, :invalid_attachment_text_encoding} =
             Local.store_attachment(invalid_text_source, "broken.txt", "text/plain")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert {:error, :missing_local_tracker_path} = Local.store_attachment(upload_source, "missing-path.txt")

    bad_parent = Path.join(tracker_dir, "not-a-dir")
    File.write!(bad_parent, "no directory here")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: Path.join(bad_parent, "issues.json"),
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert {:error, {:local_tracker_attachment_write_failed, :enotdir}} =
             Local.store_attachment(upload_source, "bad-parent.txt")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert {:error, {:local_tracker_attachment_write_failed, :enoent}} =
             Local.store_attachment(Path.join(tracker_dir, "missing-upload.txt"), "missing-upload.txt")

    assert {:ok, stored_attachment} = Local.store_attachment(upload_source, "notes.txt", "text/plain")

    assert {:ok, %Issue{identifier: "LOCAL-1"}} =
             Local.create_issue(%{
               "title" => "Attachment error coverage",
               "attachments" => [stored_attachment]
             })

    assert {:error, :attachment_not_found} = Local.fetch_attachment_file("LOCAL-1", "missing-attachment")
    assert {:error, :issue_not_found} = Local.fetch_attachment_file("LOCAL-MISSING", stored_attachment["id"])
    assert :ok = Local.discard_attachment(%{"id" => "missing-path"})

    assert :ok = Local.discard_attachment(stored_attachment)
    assert {:error, :attachment_file_missing} = Local.fetch_attachment_file("LOCAL-1", stored_attachment["id"])

    assert {:ok, sibling_attachment} = Local.store_attachment(upload_source, "sibling.txt", "text/plain")

    attachment_dir =
      Path.join([
        Path.dirname(tracker_path),
        "issues_attachments",
        Path.dirname(sibling_attachment["path"])
      ])

    File.write!(Path.join(attachment_dir, "keep.txt"), "keep me")
    assert :ok = Local.discard_attachment(sibling_attachment)
    assert File.exists?(Path.join(attachment_dir, "keep.txt"))

    File.write!(
      tracker_path,
      Jason.encode!(
        %{
          "issues" => [
            %{
              "id" => "issue-escape-1",
              "identifier" => "LOCAL-ESCAPE-1",
              "title" => "Escape path",
              "state" => "Todo",
              "attachments" => [
                %{
                  "id" => "attachment-escape",
                  "filename" => "escape.txt",
                  "path" => "../escape.txt"
                }
              ]
            }
          ]
        },
        pretty: true
      )
    )

    assert {:error, :invalid_attachment_path} =
             Local.fetch_attachment_file("LOCAL-ESCAPE-1", "attachment-escape")
  end

  test "local tracker infers attachment extensions and preview kinds from content types" do
    tracker_dir = Path.dirname(Workflow.workflow_file_path())
    tracker_path = Path.join(tracker_dir, "issues.json")
    upload_source = Path.join(tracker_dir, "upload-without-extension")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(tracker_path, Jason.encode!(%{"issues" => []}, pretty: true))
    File.write!(upload_source, "%PDF-1.7\nfake fixture\n")

    assert {:ok, blank_filename_attachment} =
             Local.store_attachment(upload_source, "   ", "application/pdf")

    assert blank_filename_attachment["filename"] == "attachment.pdf"
    assert blank_filename_attachment["content_type"] == "application/pdf"
    assert :ok = Local.discard_attachment(blank_filename_attachment)

    assert {:ok, inferred_extension_attachment} =
             Local.store_attachment(upload_source, "report", "application/pdf")

    assert inferred_extension_attachment["filename"] == "report.pdf"
    assert inferred_extension_attachment["content_type"] == "application/pdf"
    assert :ok = Local.discard_attachment(inferred_extension_attachment)

    assert Local.attachment_preview_kind(%{"filename" => nil, "content_type" => "text/plain"}) ==
             :text

    assert Local.attachment_preview_kind(%{"filename" => nil, "content_type" => "image/png"}) ==
             :image

    assert Local.attachment_preview_kind(%{"filename" => nil, "content_type" => "application/pdf"}) ==
             :pdf

    assert Local.attachment_preview_kind(%{
             "filename" => nil,
             "content_type" => "application/octet-stream"
           }) == :download

    assert Local.attachment_preview_kind(%{"filename" => nil, "content_type" => nil}) == :download
  end

  test "local tracker exposes attachment config and infers content type when metadata is blank" do
    tracker_dir = Path.dirname(Workflow.workflow_file_path())
    tracker_path = Path.join(tracker_dir, "issues.json")
    attachment_root = Path.join(tracker_dir, "issues_attachments")
    raw_attachment_path = Path.join(attachment_root, "stored/raw")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert "application/pdf" in Local.attachment_upload_accepts()
    assert ".md" in Local.attachment_allowed_extensions()
    assert Local.attachment_max_file_size() == 20_000_000

    File.mkdir_p!(Path.dirname(raw_attachment_path))
    File.write!(raw_attachment_path, "raw attachment")

    File.write!(
      tracker_path,
      Jason.encode!(
        %{
          "issues" => [
            %{
              "id" => "issue-raw-fetch-1",
              "identifier" => "LOCAL-RAW-FETCH-1",
              "title" => "Infer content type on fetch",
              "state" => "Todo",
              "attachments" => [
                %{
                  "id" => "attachment-raw-txt",
                  "filename" => "raw",
                  "content_type" => "   ",
                  "path" => "stored/raw"
                }
              ]
            }
          ]
        },
        pretty: true
      )
    )

    assert {:ok,
            %{
              path: ^raw_attachment_path,
              filename: "raw",
              content_type: nil,
              preview_kind: :download
            }} = Local.fetch_attachment_file("LOCAL-RAW-FETCH-1", "attachment-raw-txt")
  end

  test "local tracker surfaces attachment validation and filesystem failures" do
    tracker_dir = Path.dirname(Workflow.workflow_file_path())
    tracker_path = Path.join(tracker_dir, "issues.json")
    text_source = Path.join(tracker_dir, "attachment-source.txt")
    pdf_source = Path.join(tracker_dir, "attachment-source.pdf")
    directory_source = Path.join(tracker_dir, "attachment-directory.txt")
    oversized_source = Path.join(tracker_dir, "attachment-too-large.txt")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(tracker_path, Jason.encode!(%{"issues" => []}, pretty: true))
    File.write!(text_source, "filesystem failure coverage")
    File.write!(pdf_source, "%PDF-1.7\nfixture\n")
    File.mkdir_p!(directory_source)

    oversized_limit = Local.attachment_max_file_size()
    oversized_size = oversized_limit + 1
    File.write!(oversized_source, :binary.copy(<<0>>, oversized_size))

    assert {:error, {:attachment_too_large, ^oversized_size, ^oversized_limit}} =
             Local.store_attachment(oversized_source, "oversized.txt", "text/plain")

    assert {:error, {:local_tracker_attachment_write_failed, :eisdir}} =
             Local.store_attachment(directory_source, "directory.txt", "text/plain")

    long_text_filename = String.duplicate("a", 260) <> ".txt"

    assert {:error, {:local_tracker_attachment_write_failed, :enametoolong}} =
             Local.store_attachment(text_source, long_text_filename, "text/plain")

    long_pdf_filename = String.duplicate("b", 260) <> ".pdf"

    assert {:error, {:local_tracker_attachment_write_failed, :enametoolong}} =
             Local.store_attachment(pdf_source, long_pdf_filename, "application/pdf")
  end

  test "local tracker treats a missing file as an empty queue and surfaces invalid payloads" do
    tracker_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "missing-issues.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert {:ok, []} = Local.fetch_candidate_issues()

    File.write!(tracker_path, ~s({"issues": {"not": "a-list"}}))

    assert {:error, :invalid_local_tracker_payload} = Local.fetch_candidate_issues()
  end

  test "local tracker atomically claims and releases issues for distributed runs" do
    tracker_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "issues.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(
      tracker_path,
      Jason.encode!(
        %{
          "issues" => [
            %{
              "id" => "issue-lease-1",
              "identifier" => "LOC-L1",
              "title" => "Leased issue",
              "state" => "Todo"
            },
            %{
              "id" => "issue-lease-1b",
              "identifier" => "LOC-L1B",
              "title" => "Sibling issue",
              "state" => "Todo"
            }
          ]
        },
        pretty: true
      )
    )

    assert :ok = Local.claim_issue("issue-lease-1", "runtime-a", ttl_ms: 60_000)

    assert {:error, {:issue_claimed, "runtime-a", lease_expires_at}} =
             Local.claim_issue("issue-lease-1", "runtime-b", ttl_ms: 60_000)

    assert is_binary(lease_expires_at)
    assert {:ok, [%Issue{id: "issue-lease-1b", claimed_by: nil}]} = Local.fetch_candidate_issues()

    assert {:ok, [%Issue{id: "issue-lease-1", claimed_by: "runtime-a", lease_expires_at: %DateTime{}}]} =
             Local.fetch_issue_states_by_ids(["issue-lease-1"])

    assert {:error, {:issue_claimed, "runtime-a", ^lease_expires_at}} =
             Local.release_issue_claim("issue-lease-1", "runtime-b")

    assert :ok = Local.release_issue_claim("issue-lease-1", "runtime-a")

    assert {:ok, candidates} = Local.fetch_candidate_issues()
    assert Enum.map(candidates, & &1.id) == ["issue-lease-1", "issue-lease-1b"]
  end

  test "local tracker lets expired claims return to the candidate pool" do
    tracker_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "issues.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(
      tracker_path,
      Jason.encode!(
        %{
          "issues" => [
            %{
              "id" => "issue-lease-2",
              "identifier" => "LOC-L2",
              "title" => "Expiring issue",
              "state" => "Todo"
            }
          ]
        },
        pretty: true
      )
    )

    assert :ok = Local.claim_issue("issue-lease-2", "runtime-a", ttl_ms: 1)
    Process.sleep(10)

    assert {:ok, [%Issue{id: "issue-lease-2"}]} = Local.fetch_candidate_issues()
    assert :ok = Local.claim_issue("issue-lease-2", "runtime-b", ttl_ms: 60_000)

    assert {:ok, [%Issue{id: "issue-lease-2", claimed_by: "runtime-b"}]} =
             Local.fetch_issue_states_by_ids(["issue-lease-2"])
  end

  test "local tracker renews same-owner claims, supports force release, and surfaces missing refs" do
    tracker_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "issues.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(
      tracker_path,
      Jason.encode!(
        %{
          "issues" => [
            %{
              "id" => "issue-lease-3",
              "identifier" => "LOC-L3",
              "title" => "Renewable issue",
              "state" => "Todo"
            }
          ]
        },
        pretty: true
      )
    )

    assert {:error, :issue_not_found} = Local.claim_issue("missing", "runtime-a")
    assert {:error, :issue_not_found} = Local.release_issue_claim("missing", "runtime-a")

    assert :ok = Local.claim_issue("issue-lease-3", "runtime-a")
    assert {:ok, [%Issue{lease_expires_at: first_expiry}]} = Local.fetch_issue_states_by_ids(["issue-lease-3"])
    assert %DateTime{} = first_expiry

    Process.sleep(10)
    assert :ok = Local.claim_issue("issue-lease-3", "runtime-a", ttl_ms: 60_000)

    assert {:ok, [%Issue{claimed_by: "runtime-a", lease_expires_at: renewed_expiry}]} =
             Local.fetch_issue_states_by_ids(["issue-lease-3"])

    assert %DateTime{} = renewed_expiry
    refute DateTime.compare(renewed_expiry, first_expiry) == :eq

    assert :ok = Local.release_issue_claim("issue-lease-3")

    assert {:ok, [%Issue{claimed_by: nil, lease_expires_at: nil}]} =
             Local.fetch_issue_states_by_ids(["issue-lease-3"])
  end

  test "local tracker normalizes raw payloads and keyword attrs" do
    tracker_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "issues.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(
      tracker_path,
      Jason.encode!(
        [
          %{
            "id" => 123,
            "identifier" => "LOC-3",
            "title" => 456,
            "description" => 789,
            "priority" => "oops",
            "state" => "Todo",
            "labels" => ["API"],
            "blocked_by" => ["LOC-1"],
            "created_at" => "bad",
            "updated_at" => "bad"
          },
          "noise"
        ],
        pretty: true
      )
    )

    assert {:ok, [%Issue{} = normalized]} = Local.list_issues()
    assert normalized.id == "123"
    assert normalized.title == "456"
    assert normalized.description == "789"
    assert normalized.priority == nil
    assert normalized.labels == ["api"]
    assert normalized.blocked_by == ["LOC-1"]
    assert normalized.created_at == nil
    assert normalized.updated_at == nil
    assert {:ok, [%Issue{id: "123"}]} = Local.fetch_issues_by_states([" todo ", 42])
    assert :ok = Local.update_issue_state("LOC-3", "Done")

    assert {:ok,
            %Issue{
              identifier: "LOCAL-1",
              description: "123",
              labels: ["ops", "nil"],
              blocked_by: ["1", "LOC-9"],
              assigned_to_worker: false,
              state: "Todo"
            }} =
             Local.create_issue(
               title: "Keyword issue",
               description: 123,
               labels: [:Ops, nil, 1, "  "],
               blocked_by: [1, " ", "LOC-9"],
               assigned_to_worker: "false",
               priority: nil,
               branch_name: :feature_local,
               assignee_id: 42,
               url: "https://example.test/issues/1"
             )

    assert {:ok, %Issue{labels: ["5"], blocked_by: []}} =
             Local.create_issue(%{
               "title" => "Scalar labels",
               "labels" => 5,
               "blocked_by" => [" "],
               "assigned_to_worker" => false,
               "description" => []
             })

    assert {:ok, %Issue{assigned_to_worker: true, labels: ["go", "migration"]}} =
             Local.create_issue(%{
               "title" => "String labels",
               "labels" => " Go , Migration ",
               "assigned_to_worker" => "true",
               "description" => "   "
             })
  end

  test "local tracker surfaces validation, duplicate, decode, read, and write errors" do
    tracker_root = Path.dirname(Workflow.workflow_file_path())
    tracker_path = Path.join(tracker_root, "issues.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(tracker_path, Jason.encode!(%{"issues" => []}, pretty: true))

    assert {:error, :missing_issue_title} = Local.create_issue(%{})
    assert {:error, :invalid_issue_priority} = Local.create_issue(%{"title" => "Bad priority", "priority" => "oops"})
    assert {:error, :invalid_assigned_to_worker} = Local.create_issue(%{"title" => "Bad worker", "assigned_to_worker" => "maybe"})

    assert {:ok, %Issue{id: "local-1", identifier: "LOCAL-1"}} =
             Local.create_issue(%{"title" => "First"})

    assert {:error, {:duplicate_issue_field, "identifier", "LOCAL-1"}} =
             Local.create_issue(%{"title" => "Duplicate", "identifier" => "LOCAL-1"})

    File.write!(tracker_path, "{")
    assert {:error, {:local_tracker_decode_failed, _reason}} = Local.fetch_candidate_issues()

    unreadable_path = Path.join(tracker_root, "issues-dir")
    File.mkdir_p!(unreadable_path)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: unreadable_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert {:error, {:local_tracker_read_failed, reason}} = Local.fetch_candidate_issues()
    assert reason in [:eisdir, :eperm]

    readonly_dir = Path.join(tracker_root, "readonly")
    File.mkdir_p!(readonly_dir)
    File.chmod!(readonly_dir, 0o555)

    on_exit(fn ->
      File.chmod!(readonly_dir, 0o755)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: Path.join(readonly_dir, "issues.json"),
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert {:error, {:local_tracker_write_failed, _reason}} =
             Local.create_issue(%{"title" => "Cannot persist"})
  end

  test "local tracker reports a missing tracker path" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert {:error, :missing_local_tracker_path} = Local.fetch_candidate_issues()
  end
end
