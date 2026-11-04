{
  python3,
  janet,
  jpm,
  callPackage,
  git,
  coreutils,
  nix,
  runCommand,
  ...
}: let
  deps = callPackage ../packages/hey-janet-deps.nix {inherit janet jpm;};
  supervisor = callPackage ../packages/process-supervisor.nix {};
  runtimePython = callPackage ../packages/hey-python.nix {};
  activator = callPackage ../packages/system-activation.nix {};
in
  runCommand "system-activation-check" {
    src = ../.;
    nativeBuildInputs = [python3 janet git coreutils nix];
  } ''
    export PYTHONDONTWRITEBYTECODE=1
    export JANET_PATH="${deps}/lib"
    export JANET_TREE="${deps}"
    export HEY_PROCESS_SUPERVISOR="${supervisor}/bin/nixi-process-supervisor"
    export HEY_RUNTIME_PYTHON="${runtimePython}/bin/python3"
    export NIXI_SYSTEM_ACTIVATOR="${activator}/bin/nixi-system-activate"
    python "$src/test_tools/test_system_activation.py"
    python "$src/test_tools/run_cli_tests.py" \
      test_sync_builds_as_caller_then_activates_fixed_output_without_caller_environment \
      test_sync_failed_build_or_activation_preserves_status_and_releases_roots_and_lock \
      test_sync_rejects_ambiguous_build_outputs_before_privilege \
      test_sync_dry_run_explain_and_unsupported_arguments_never_build_or_activate \
      test_sync_refuses_root_evaluation_and_build \
      test_sync_source_fallback_builds_activator_as_caller_and_rejects_mutable_helper \
      test_sync_check_and_vm_build_remain_unprivileged_and_explain_matches_action \
      test_normal_sync_never_logs_nix_config_at_any_verbosity \
      test_sync_doctor_accepts_missing_optional_nom \
      test_sync_plan_never_builds_activates_updates_locks_or_uses_nom \
      test_sync_plan_with_real_isolated_nix_refuses_evaluation_time_builds \
      test_sync_and_system_rollback_release_shared_lock_on_failure
    touch "$out"
  ''
