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

Optional hooks (all get the server name; see `lib/modules.sh`):

- `mod_<id>_available` decides whether `m` offers the module for a server
  (otherwise it sets a reason in `REPLY`).
- `mod_<id>_detail_tick` and `mod_<id>_detail_draw` add a section below the
  processes of the detail view; the processes shrink to 5 rows then.
- `mod_<id>_detail_refresh` reacts to `r`, `mod_<id>_cleanup` stops
  background jobs on exit.

Remote scripts belong in `lib/remote/`, not here: every `*.sh` file in this
directory is sourced.

`docker.sh` shows Docker containers read only (status, health, CPU, memory).
`drives.sh` uses hooks only (no entry under `m`): a Drives section after
Disks and a warning in the STATUS column of the list
(`mod_<id>_detail_after_disks`, `mod_<id>_list_tick`, `mod_<id>_list_status`).
Planned: `kubernetes.sh` (pods).
