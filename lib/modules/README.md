# scat modules

Every `*.sh` file in this directory is sourced at startup (TUI mode only).
Modules add screens to the server detail view (key `m`) without changing the
core files.

Contract:

- File `lib/modules/<id>.sh`, functions named `mod_<id>_*`.
- Register with `sc_module_register <id> "<label>" <view-function>`.
- The view function gets the server name as `$1`, runs its own key loop
  (`sc_read_key`, `sc_ui_begin_frame` / `sc_ui_end_frame`, `sc_view_pager`)
  and returns on Esc/q.
- Remote commands go through `sc_ssh_run_script <server> <timeout> <script-file> <out> <err>`
  so they keep BatchMode, timeouts and connection reuse. Temp files belong in
  `$SC_RUNTIME_DIR`.

Planned: `docker.sh` (containers: list, logs, start/stop/restart) and
`kubernetes.sh` (pods). `docker.sh.example` is a skeleton showing the wiring.
It is not loaded because it does not end in `.sh`.
