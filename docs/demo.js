/* Animated scat demo for the website: a made-up server list, the cursor
 * moves to a server, Enter opens its detail view with live-looking metrics,
 * Esc goes back, and the next server is picked. All names and values are
 * invented; addresses are from the documentation ranges 192.0.2.0/24 and
 * 203.0.113.0/24.
 *
 * Frames are 80x24 like the real minimum terminal. ScatDemo.frame() builds
 * one frame as HTML from a plain state object and has no DOM access, so it
 * can be checked outside a browser. With prefers-reduced-motion the server
 * list is shown as a still frame and nothing moves. */
(function (global) {
  "use strict";

  var COLS = 80, ROWS = 24;
  var EIGHTHS = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"];

  // Groups A-Z, servers A-Z within a group, ungrouped last (as scat sorts).
  var SERVERS = [
    { group: "lab", name: "lab-ci", target: "ci@192.0.2.30:22", os: "Linux 6.8.0", cores: 8,
      cpu: 64, mem: 71, swap: 12, load: 3.10, up: "4d 7h", procs: 241,
      disks: [["/", 39.1, 48], ["/srv/cache", 476, 82]],
      nics: [["eth0", 38.2, 9.6], ["eth1", 0.4, 0.1]],
      top: [["4312", "ci", "build-runner"], ["4398", "ci", "test-worker"], ["1220", "root", "cron"], ["988", "root", "sshd"]] },
    { group: "lab", name: "lab-edge", target: "192.0.2.31", os: "Linux 6.6.0", cores: 2,
      cpu: 9, mem: 33, swap: 0, load: 0.21, up: "31d 2h", procs: 96,
      disks: [["/", 14.6, 22]],
      nics: [["eth0", 1.2, 0.8], ["wlan0", 0.1, 0.0]],
      top: [["611", "root", "edge-proxy"], ["702", "nobody", "metrics-agent"], ["455", "root", "sshd"], ["1", "root", "init"]] },
    { group: "production", name: "db-01", target: "db@203.0.113.20:22", os: "Linux 6.8.0", cores: 16,
      cpu: 41, mem: 84, swap: 6, load: 5.42, up: "88d 1h", procs: 312,
      disks: [["/", 39.1, 35], ["/var/lib/db", 953, 61]],
      nics: [["eth0", 22.7, 31.5], ["eth1", 6.3, 6.1]],
      top: [["2201", "db", "db-server"], ["2240", "db", "db-writer"], ["3012", "backup", "dump-job"], ["988", "root", "sshd"]] },
    { group: "production", name: "web-01", target: "deploy@203.0.113.10:22", os: "Linux 6.8.0", cores: 4,
      cpu: 23, mem: 46, swap: 2, load: 0.84, up: "12d 3h", procs: 183,
      disks: [["/", 39.1, 41], ["/var", 95.3, 63]],
      nics: [["eth0", 12.4, 31.0], ["eth1", 0.3, 0.2]],
      top: [["1840", "www", "app-server"], ["1903", "www", "app-server"], ["2117", "www", "queue-worker"], ["988", "root", "sshd"]] },
    { group: "production", name: "web-02", target: "deploy@203.0.113.11:22", os: "Linux 6.8.0", cores: 4,
      cpu: 37, mem: 52, swap: 2, load: 1.12, up: "12d 3h", procs: 191,
      disks: [["/", 39.1, 44], ["/var", 95.3, 58]],
      nics: [["eth0", 18.9, 47.2], ["eth1", 0.5, 0.3]],
      top: [["1851", "www", "app-server"], ["1877", "www", "app-server"], ["2120", "www", "queue-worker"], ["1220", "root", "cron"]] },
    { group: "", name: "backup-01", target: "backup@192.0.2.40:22", os: "Linux 6.1.0", cores: 2,
      cpu: 12, mem: 28, swap: 0, load: 0.30, up: "140d 9h", procs: 88,
      disks: [["/", 29.3, 18], ["/backup", 3725, 77]],
      nics: [["eth0", 62.0, 0.9]],
      top: [["5120", "backup", "backup-job"], ["5133", "backup", "compress"], ["988", "root", "sshd"], ["1", "root", "init"]] }
  ];

  // --- text helpers ----------------------------------------------------------

  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  function rep(ch, n) { return n > 0 ? new Array(n + 1).join(ch) : ""; }
  function fit(s, n) {
    s = String(s);
    if (s.length > n) return n > 1 ? s.slice(0, n - 1) + "…" : s.slice(0, n);
    return s + rep(" ", n - s.length);
  }
  function right(s, n) { s = String(s); return s.length >= n ? s.slice(0, n) : rep(" ", n - s.length) + s; }

  // A row is a list of [text, class] segments, padded to COLS on output.
  function Row() { this.segs = []; this.len = 0; }
  Row.prototype.add = function (text, cls) {
    text = String(text);
    if (this.len + text.length > COLS) text = text.slice(0, COLS - this.len);
    if (text) { this.segs.push([text, cls || ""]); this.len += text.length; }
    return this;
  };
  Row.prototype.html = function (fill) {
    var out = "", i, s;
    if (this.len < COLS) this.segs.push([rep(" ", COLS - this.len), fill || ""]);
    for (i = 0; i < this.segs.length; i++) {
      s = this.segs[i];
      out += s[1] ? '<span class="' + s[1] + '">' + esc(s[0]) + "</span>" : esc(s[0]);
    }
    return out;
  };
  Row.prototype.text = function () {
    var out = "", i;
    for (i = 0; i < this.segs.length; i++) out += this.segs[i][0];
    return out + rep(" ", COLS - this.len);
  };

  // Usage bar: whole cells, like scat's CPU/memory/disk bars.
  function bar(pct, w) {
    var full = Math.max(0, Math.min(w, Math.round(pct * w / 100)));
    return [rep("█", full), rep("░", w - full)];
  }
  // Rate bar: 100 MB/s fills it, eighth-cell steps, any traffic shows a step.
  function rateBar(mbs, w) {
    var units = Math.round(mbs * w * 8 / 100), max = w * 8;
    if (units > max) units = max;
    if (mbs > 0 && units === 0) units = 1;
    var head = rep("█", Math.floor(units / 8)) + EIGHTHS[units % 8];
    return [head, rep("░", w - Math.ceil(units / 8))];
  }
  function fmt2(v) { return (Math.round(v * 100) / 100).toFixed(2); }
  function size(gib) {
    if (gib < 1) return Math.round(gib * 1024) + "M";
    return gib >= 100 ? Math.round(gib) + "G" : gib.toFixed(1) + "G";
  }
  function clock(sec) {
    var h = Math.floor(sec / 3600) % 24, m = Math.floor(sec / 60) % 60, s = sec % 60;
    return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s;
  }

  function header(left, rightText) {
    var r = new Row();
    r.add(fit(" scat · " + left, COLS - rightText.length - 2), "inv").add(rightText + "  ", "inv");
    return r.html("inv");
  }
  function footer(keys, pressed) {
    var r = new Row(), i;
    for (i = 0; i < keys.length; i += 2) {
      r.add(" ", "inv");
      r.add(keys[i], keys[i] === pressed ? "key-down" : "inv b");
      r.add(" " + keys[i + 1] + " ", "inv");
    }
    return r.html("inv");
  }

  // --- frames ------------------------------------------------------------------

  // state: { view: "list"|"detail", sel: server index, t: seconds on the clock,
  //          live: per-server values {cpu, mem, load, nics:[[rx, tx]]}, pressed: key }
  function listFrame(st) {
    var rows = [], i, s, r, lastGroup = null, v, g;
    rows.push(header("Servers", SERVERS.length + " servers · " + clock(st.t)));
    r = new Row();
    // At 80 columns scat has no room for the TARGET column (it needs 40 free).
    r.add("   " + fit("NAME", 16) + " " + right("CPU", 5) + " " + right("MEM", 5) + " " +
          right("LOAD", 6) + " " + right("UPTIME", 8) + " STATUS", "d");
    rows.push(r.html());
    for (i = 0; i < SERVERS.length; i++) {
      s = SERVERS[i];
      g = s.group || "ungrouped";
      if (g !== lastGroup) {
        rows.push(new Row().add(" ── " + g + " ──", "k b").html());
        lastGroup = g;
      }
      v = st.live[i];
      r = new Row();
      var on = i === st.sel, cls = on ? (st.pressed === "⏎" ? "flash" : "sel") : "";
      r.add(on ? "▶" : " ", cls);
      r.add("●", (on ? cls + " " : "") + "ok");
      r.add(" ", cls);
      r.add(fit(s.name, 16), (cls ? cls + " " : "") + "b");
      r.add(" " + right(Math.round(v.cpu) + "%", 5) + " " + right(Math.round(v.mem) + "%", 5) + " " +
            right(v.load.toFixed(2), 6) + " " + right(s.up, 8) + " ", cls);
      r.add(fit(s.os, COLS - r.len), (cls ? cls + " " : "") + "d");
      rows.push(r.html(cls));
    }
    while (rows.length < ROWS - 2) rows.push(new Row().html());
    rows.push(new Row().html());
    rows.push(footer(["↑↓", "move", "⏎", "details", "a", "add", "e", "edit", "d", "delete", "s", "ssh",
                      "r", "refresh", "?", "help", "q", "quit"], st.pressed));
    return rows;
  }

  function barLine(label, pct, text) {
    var b = bar(pct, 26), r = new Row();
    r.add("  " + fit(label, 12), "b").add(b[0], pct >= 90 ? "h" : pct >= 75 ? "w" : "ok").add(b[1], "d");
    r.add(" " + right(Math.round(pct) + "%", 5) + "  ").add(text, "d");
    return r.html();
  }

  function detailFrame(st) {
    var s = SERVERS[st.sel], v = st.live[st.sel], rows = [], r, i, rx, tx, d;
    rows.push(header(s.name, "online · " + clock(st.t)));
    rows.push(new Row().add(" " + s.target + (s.group ? "  [" + s.group + "]" : ""), "b").html());
    rows.push(new Row().add(" Linux · kernel " + s.os.replace("Linux ", "") + " · host " + s.name + " · up " + s.up, "d").html());
    rows.push(new Row().html());
    rows.push(barLine("CPU", v.cpu, s.cores + " cores  usr " + (v.cpu * 0.76).toFixed(1) + " sys " + (v.cpu * 0.21).toFixed(1)));
    rows.push(barLine("Memory", v.mem, size(s.cores * 2 * v.mem / 100) + " / " + size(s.cores * 2)));
    rows.push(barLine("Swap", s.swap, s.swap ? size(2 * s.swap / 100) + " / 2.0G" : "no swap"));
    rows.push(new Row().add("  " + fit("Load", 12), "b").add(v.load.toFixed(2) + " " + (v.load * 0.9).toFixed(2) + " " +
              (v.load * 0.8).toFixed(2) + "   " + s.procs + " processes").html());
    rows.push(new Row().html());
    rows.push(new Row().add("  Disks", "b").html());
    for (i = 0; i < 2; i++) {
      d = s.disks[i];
      if (d) rows.push(barLine(d[0], d[2], size(d[1] * d[2] / 100) + " / " + size(d[1])));
      else rows.push(new Row().html());
    }
    rows.push(new Row().html());
    rows.push(new Row().add("  Network", "b").html());
    for (i = 0; i < 2; i++) {
      if (!s.nics[i]) { rows.push(new Row().html()); continue; }
      rx = rateBar(v.nics[i][0], 12);
      tx = rateBar(v.nics[i][1], 13);
      r = new Row();
      r.add("  " + fit(s.nics[i][0], 12), "b").add(rx[0], "rx").add(rx[1], "d").add(" ").add(tx[0], "tx").add(tx[1], "d");
      r.add(" rx " + right(fmt2(v.nics[i][0]), 6) + "  tx " + right(fmt2(v.nics[i][1]), 6) + " MB/s", "d");
      rows.push(r.html());
    }
    rows.push(new Row().html());
    rows.push(new Row().add("  " + right("PID", 7) + " " + fit("USER", 10) + " " + right("CPU%", 6) + " " +
              right("MEM%", 6) + " " + right("RSS", 7) + " COMMAND", "b").html());
    for (i = 0; i < 4; i++) {
      var p = s.top[i], share = [0.42, 0.27, 0.12, 0.03][i];
      rows.push(new Row().add("  " + right(p[0], 7) + " " + fit(p[1], 10) + " " + right((v.cpu * share).toFixed(1), 6) + " " +
                right((v.mem * share / 3).toFixed(1), 6) + " " + right(["412M", "388M", "96.4M", "4.1M"][i], 7) + " " + p[2]).html());
    }
    while (rows.length < ROWS - 2) rows.push(new Row().html());
    rows.push(new Row().html());
    rows.push(footer(["p", "processes", "s", "ssh", "x", "snippets", "e", "edit", "m", "modules",
                      "r", "refresh", "esc", "back"], st.pressed));
    return rows;
  }

  function frame(st) { return (st.view === "detail" ? detailFrame(st) : listFrame(st)).join("\n"); }

  // Resting values, and values that drift around them over time.
  function baseLive() {
    var out = [], i, s;
    for (i = 0; i < SERVERS.length; i++) {
      s = SERVERS[i];
      out.push({ cpu: s.cpu, mem: s.mem, load: s.load, nics: s.nics.map(function (n) { return [n[1], n[2]]; }) });
    }
    return out;
  }
  function drift(base, phase, amp, lo, hi) {
    var v = base * (1 + amp * Math.sin(phase) + amp * 0.5 * Math.sin(phase * 2.3 + 1));
    return Math.max(lo, Math.min(hi, v));
  }
  // Values at time t (seconds); fill (0..1) scales them up when a view opens.
  function liveAt(t, fill) {
    var out = baseLive(), i, j, o;
    for (i = 0; i < out.length; i++) {
      o = out[i];
      o.cpu = drift(o.cpu, t * 0.9 + i, 0.25, 1, 99) * fill;
      o.mem = drift(o.mem, t * 0.3 + i * 2, 0.04, 1, 99) * fill;
      o.load = drift(o.load, t * 0.5 + i, 0.15, 0, 64);
      for (j = 0; j < o.nics.length; j++) {
        o.nics[j][0] = drift(o.nics[j][0], t * 1.3 + i + j, 0.35, 0, 125) * fill;
        o.nics[j][1] = drift(o.nics[j][1], t * 1.1 + i * 3 + j, 0.35, 0, 125) * fill;
      }
    }
    return out;
  }

  global.ScatDemo = { frame: frame, liveAt: liveAt, servers: SERVERS, COLS: COLS, ROWS: ROWS,
                      textOf: function (html) { return html.replace(/<[^>]*>/g, "").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&"); } };

  // --- browser driver ------------------------------------------------------------

  if (typeof document === "undefined") return;

  var screen = document.getElementById("demo-screen");
  if (!screen) return;

  var clock0 = 12 * 3600 + 3 * 60 + 55;
  var picks = [4, 0, 2, 5];               // web-02, lab-ci, db-01, backup-01
  var reduce = global.matchMedia ? global.matchMedia("(prefers-reduced-motion: reduce)") : null;
  var timer = null, start = 0, st = null;

  function draw() { screen.innerHTML = frame(st); }

  // Script of one round: [duration ms, action]. Actions change the state;
  // the detail view also animates continuously between steps.
  function round(pick) {
    var steps = [[900, function () { st.view = "list"; st.pressed = ""; }]], k, d = pick > st.sel ? 1 : -1;
    for (k = st.sel; k !== pick; k += d) {
      steps.push([380, (function (to) { return function () { st.sel = to; }; })(k + d)]);
    }
    steps.push([500, function () {}]);
    steps.push([260, function () { st.pressed = "⏎"; }]);
    steps.push([7000, function () { st.view = "detail"; st.pressed = ""; st.opened = Date.now(); }]);
    steps.push([300, function () { st.pressed = "esc"; }]);
    return steps;
  }

  function run() {
    var n = 0, steps = round(picks[0]), i = 0;
    function next() {
      steps[i][1]();
      draw();
      var wait = steps[i][0];
      i++;
      if (i >= steps.length) { n = (n + 1) % picks.length; steps = round(picks[n]); i = 0; }
      timer = setTimeout(next, wait);
    }
    next();
  }

  // Values follow the clock; a freshly opened detail view fills up first.
  function tick() {
    var now = Date.now(), t = (now - start) / 1000, fill = 1;
    if (st.view === "detail" && st.opened) fill = Math.min(1, (now - st.opened) / 900);
    st.t = clock0 + Math.floor(t);
    st.live = liveAt(t, fill);
    draw();
  }

  function stop() {
    clearTimeout(timer);
    clearInterval(st && st.ival);
    timer = null;
  }

  function still() {
    stop();
    st = { view: "list", sel: 4, t: clock0, live: liveAt(0, 1), pressed: "" };
    draw();
  }

  function play() {
    stop();
    start = Date.now();
    st = { view: "list", sel: 0, t: clock0, live: liveAt(0, 1), pressed: "", opened: 0 };
    st.ival = setInterval(tick, 150);
    run();
  }

  function decide() {
    if (reduce && reduce.matches) still(); else play();
  }

  // Pause while the tab is hidden; follow changes of the motion setting.
  document.addEventListener("visibilitychange", function () {
    if (document.hidden) stop(); else decide();
  });
  if (reduce) {
    if (reduce.addEventListener) reduce.addEventListener("change", decide);
    else if (reduce.addListener) reduce.addListener(decide);
  }
  decide();
})(this);
