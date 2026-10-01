// omavoice-clipboard: paste dictated text without leaving it on the clipboard.
//
// Voxtype's own paste mode copies the text, sends the paste keys and leaves
// the text on the clipboard. Its restore option saves only the first MIME
// type of what was there and restores it after a fixed delay, whether or not
// the focused app has fetched the paste yet. This helper does the whole
// transaction itself over the ext-data-control Wayland protocol:
//
//   1. snapshot every MIME type of the current clipboard, in memory only
//   2. offer the text (plus x-kde-passwordManagerHint, so clipboard history
//      watchers skip this short-lived offer)
//   3. send the paste keys with wtype
//   4. wait until the focused app has actually read the offer, or a timeout
//   5. put the snapshot back with all its types and keep serving it in the
//      background until something else takes the clipboard, like wl-copy
//
// If anything else takes the clipboard while the paste is in flight, the
// snapshot is not restored over it. Nothing is written to disk and no
// clipboard or dictation content is ever printed; the result line only has
// counts and flags.
//
// Usage:
//   omavoice-clipboard paste [--keys shift+insert] [--settle-ms 120]
//                            [--wait-ms 2000] [--paste-cmd CMD]   < text
//   omavoice-clipboard dump   > snapshot     current clipboard, all types
//   omavoice-clipboard load   < snapshot     take the clipboard with it
//   omavoice-clipboard types                 MIME types on the clipboard
//
// --paste-cmd runs CMD with sh instead of wtype (for tests: a command that
// reads the clipboard the way an app does on paste).
//
// Snapshot format: "OMVCLIP1\n", u32 count, then per item a NUL terminated
// MIME type, a u64 length and the bytes (little endian).
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#include "ext-data-control-v1-client-protocol.h"

#define MAX_TYPES 64
#define SNAPSHOT_CAP (64u << 20)   // total bytes kept from the old clipboard
#define TEXT_CAP (8u << 20)        // largest text accepted on stdin
#define HINT_TYPE "x-kde-passwordManagerHint"

struct item {
  char *mime;
  char *data;
  size_t len;
};

struct snapshot {
  struct item items[MAX_TYPES];
  int n;
  int had_selection;  // something was on the clipboard
  int skipped;        // types not kept (timeout, too big, unreadable)
  size_t bytes;
};

struct offer {
  struct ext_data_control_offer_v1 *obj;
  char *mimes[MAX_TYPES];
  int n;
};

struct source {
  struct ext_data_control_source_v1 *obj;
  const struct snapshot *snap;  // restore source
  const char *text;             // paste source
  size_t text_len;
  int cancelled;
  int sends;
  int64_t last_send_ms;
  int64_t count_after_ms;       // only sends after this time count
  int sends_after;
};

static struct wl_display *display;
static struct wl_seat *seat;
static struct ext_data_control_manager_v1 *manager;
static struct ext_data_control_device_v1 *device;
static struct offer *selection;
static int device_finished;

static int64_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void die(const char *code) {
  printf("{\"ok\":false,\"error\":\"%s\"}\n", code);
  fflush(stdout);
  exit(2);
}

// ---------------------------------------------------------------- offers

static void offer_mime(void *data, struct ext_data_control_offer_v1 *obj, const char *mime) {
  (void)obj;
  struct offer *o = data;
  if (o->n < MAX_TYPES) o->mimes[o->n++] = strdup(mime);
}

static const struct ext_data_control_offer_v1_listener offer_listener = { .offer = offer_mime };

static void free_offer(struct offer *o) {
  if (!o) return;
  ext_data_control_offer_v1_destroy(o->obj);
  for (int i = 0; i < o->n; i++) free(o->mimes[i]);
  free(o);
}

static void device_data_offer(void *data, struct ext_data_control_device_v1 *dev,
                              struct ext_data_control_offer_v1 *obj) {
  (void)data; (void)dev;
  struct offer *o = calloc(1, sizeof *o);
  o->obj = obj;
  ext_data_control_offer_v1_add_listener(obj, &offer_listener, o);
}

static void device_selection(void *data, struct ext_data_control_device_v1 *dev,
                             struct ext_data_control_offer_v1 *obj) {
  (void)data; (void)dev;
  struct offer *o = obj ? ext_data_control_offer_v1_get_user_data(obj) : NULL;
  if (selection && selection != o) free_offer(selection);
  selection = o;
}

static void device_primary(void *data, struct ext_data_control_device_v1 *dev,
                           struct ext_data_control_offer_v1 *obj) {
  (void)data; (void)dev;
  // The primary selection is never touched; drop its offer.
  if (obj && (!selection || selection->obj != obj)) free_offer(ext_data_control_offer_v1_get_user_data(obj));
}

static void device_finished_ev(void *data, struct ext_data_control_device_v1 *dev) {
  (void)data; (void)dev;
  device_finished = 1;
}

static const struct ext_data_control_device_v1_listener device_listener = {
  .data_offer = device_data_offer,
  .selection = device_selection,
  .finished = device_finished_ev,
  .primary_selection = device_primary,
};

// ---------------------------------------------------------------- registry

static void registry_global(void *data, struct wl_registry *reg, uint32_t name,
                            const char *iface, uint32_t version) {
  (void)data; (void)version;
  if (!seat && strcmp(iface, wl_seat_interface.name) == 0)
    seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
  else if (strcmp(iface, ext_data_control_manager_v1_interface.name) == 0)
    manager = wl_registry_bind(reg, name, &ext_data_control_manager_v1_interface, 1);
}

static void registry_remove(void *data, struct wl_registry *reg, uint32_t name) {
  (void)data; (void)reg; (void)name;
}

static const struct wl_registry_listener registry_listener = { registry_global, registry_remove };

static void connect_wayland(void) {
  display = wl_display_connect(NULL);
  if (!display) die("no-wayland");
  struct wl_registry *reg = wl_display_get_registry(display);
  wl_registry_add_listener(reg, &registry_listener, NULL);
  wl_display_roundtrip(display);
  if (!seat) die("no-seat");
  if (!manager) die("no-data-control");
  device = ext_data_control_manager_v1_get_data_device(manager, seat);
  ext_data_control_device_v1_add_listener(device, &device_listener, NULL);
  // The compositor sends the current selection right after the device is made.
  wl_display_roundtrip(display);
  wl_display_roundtrip(display);
}

// Dispatch Wayland events for up to `ms`, or until done() says stop.
static void dispatch_for(int ms, int (*done)(void *), void *arg) {
  int64_t deadline = now_ms() + ms;
  for (;;) {
    while (wl_display_prepare_read(display) != 0) wl_display_dispatch_pending(display);
    wl_display_flush(display);
    int64_t left = deadline - now_ms();
    if (left <= 0 || (done && done(arg))) {
      wl_display_cancel_read(display);
      return;
    }
    struct pollfd p = { wl_display_get_fd(display), POLLIN, 0 };
    int r = poll(&p, 1, left > 20 ? 20 : (int)left);
    if (r > 0) {
      if (wl_display_read_events(display) < 0) return;
      wl_display_dispatch_pending(display);
    } else {
      wl_display_cancel_read(display);
      if (r < 0 && errno != EINTR) return;
    }
    if (done && done(arg)) return;
  }
}

// ---------------------------------------------------------------- snapshot

// X11 meta targets that XWayland can surface; they are not data.
static int meta_target(const char *m) {
  static const char *skip[] = { "TARGETS", "MULTIPLE", "TIMESTAMP", "SAVE_TARGETS", "DELETE", "INCR", NULL };
  for (int i = 0; skip[i]; i++) if (strcmp(m, skip[i]) == 0) return 1;
  return 0;
}

// Read one MIME type of the current selection into memory.
static int receive(struct offer *o, const char *mime, char **out, size_t *len, int64_t deadline, size_t cap) {
  int fds[2];
  if (pipe2(fds, O_CLOEXEC) < 0) return -1;
  ext_data_control_offer_v1_receive(o->obj, mime, fds[1]);
  wl_display_flush(display);
  close(fds[1]);
  size_t size = 0, alloc = 4096;
  char *buf = malloc(alloc);
  int ok = -1;
  for (;;) {
    int64_t left = deadline - now_ms();
    if (left <= 0) break;
    struct pollfd p = { fds[0], POLLIN, 0 };
    int r = poll(&p, 1, (int)left);
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) break;
    if (size == alloc) {
      alloc *= 2;
      buf = realloc(buf, alloc);
    }
    ssize_t got = read(fds[0], buf + size, alloc - size);
    if (got < 0 && (errno == EINTR || errno == EAGAIN)) continue;
    if (got < 0) break;
    if (got == 0) { ok = 0; break; }
    size += (size_t)got;
    if (size > cap) break;
  }
  close(fds[0]);
  if (ok != 0) { free(buf); return -1; }
  *out = buf;
  *len = size;
  return 0;
}

static void take_snapshot(struct snapshot *s, int budget_ms) {
  memset(s, 0, sizeof *s);
  if (!selection) return;
  s->had_selection = 1;
  int64_t end = now_ms() + budget_ms;
  for (int i = 0; i < selection->n && s->n < MAX_TYPES; i++) {
    const char *m = selection->mimes[i];
    if (meta_target(m)) continue;
    int dup = 0;
    for (int j = 0; j < s->n; j++) if (strcmp(s->items[j].mime, m) == 0) dup = 1;
    if (dup) continue;
    // Each type gets at most 600 ms of the shared budget.
    int64_t deadline = now_ms() + 600;
    if (deadline > end) deadline = end;
    char *data = NULL;
    size_t len = 0;
    if (now_ms() >= end || receive(selection, m, &data, &len, deadline, SNAPSHOT_CAP - s->bytes) != 0) {
      s->skipped++;
      continue;
    }
    s->items[s->n].mime = strdup(m);
    s->items[s->n].data = data;
    s->items[s->n].len = len;
    s->bytes += len;
    s->n++;
  }
}

// ---------------------------------------------------------------- sources

static void write_all(int fd, const char *data, size_t len) {
  while (len > 0) {
    ssize_t w = write(fd, data, len);
    if (w < 0 && errno == EINTR) continue;
    if (w <= 0) return;
    data += w;
    len -= (size_t)w;
  }
}

static void source_send(void *data, struct ext_data_control_source_v1 *obj, const char *mime, int32_t fd) {
  (void)obj;
  struct source *src = data;
  src->sends++;
  src->last_send_ms = now_ms();
  if (src->count_after_ms && src->last_send_ms >= src->count_after_ms && strcmp(mime, HINT_TYPE) != 0)
    src->sends_after++;
  // Each reader is served from a detached grandchild, so a slow reader can
  // never stall the event loop and no zombie is left behind.
  pid_t pid = fork();
  if (pid > 0) {
    waitpid(pid, NULL, 0);
    close(fd);
    return;
  }
  if (pid == 0 && fork() != 0) _exit(0);
  if (pid == 0) {
    int flags = fcntl(fd, F_GETFL);
    if (flags >= 0) fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
    if (src->snap) {
      for (int i = 0; i < src->snap->n; i++) {
        if (strcmp(src->snap->items[i].mime, mime) == 0) {
          write_all(fd, src->snap->items[i].data, src->snap->items[i].len);
          break;
        }
      }
    } else if (strcmp(mime, HINT_TYPE) == 0) {
      write_all(fd, "secret", 6);
    } else {
      write_all(fd, src->text, src->text_len);
    }
    _exit(0);
  }
  close(fd);
}

static void source_cancelled(void *data, struct ext_data_control_source_v1 *obj) {
  (void)obj;
  struct source *src = data;
  src->cancelled = 1;
}

static const struct ext_data_control_source_v1_listener source_listener = { source_send, source_cancelled };

static struct source *make_source(void) {
  struct source *src = calloc(1, sizeof *src);
  src->obj = ext_data_control_manager_v1_create_data_source(manager);
  ext_data_control_source_v1_add_listener(src->obj, &source_listener, src);
  return src;
}

static struct source *restore_source(const struct snapshot *s) {
  struct source *src = make_source();
  src->snap = s;
  for (int i = 0; i < s->n; i++) ext_data_control_source_v1_offer(src->obj, s->items[i].mime);
  return src;
}

static int is_cancelled(void *arg) { return ((struct source *)arg)->cancelled || device_finished; }

// Keep serving the source from a detached child until something else takes
// the clipboard. The parent returns at once.
static void serve_in_background(struct source *src) {
  fflush(stdout);
  pid_t pid = fork();
  if (pid != 0) return;
  setsid();
  int null = open("/dev/null", O_RDWR);
  dup2(null, 0);
  dup2(null, 1);
  dup2(null, 2);
  while (!is_cancelled(src)) {
    dispatch_for(60000, is_cancelled, src);
    if (wl_display_get_error(display)) break;
  }
  _exit(0);
}

// ---------------------------------------------------------------- snapshot io

static void put(const void *p, size_t n) { fwrite(p, 1, n, stdout); }

static void cmd_dump(void) {
  connect_wayland();
  struct snapshot s;
  take_snapshot(&s, 3000);
  put("OMVCLIP1\n", 9);
  uint32_t n = (uint32_t)s.n;
  put(&n, 4);
  for (int i = 0; i < s.n; i++) {
    put(s.items[i].mime, strlen(s.items[i].mime) + 1);
    uint64_t len = s.items[i].len;
    put(&len, 8);
    put(s.items[i].data, s.items[i].len);
  }
  fflush(stdout);
}

static size_t read_all(int fd, char **out, size_t cap) {
  size_t size = 0, alloc = 65536;
  char *buf = malloc(alloc);
  for (;;) {
    if (size == alloc) {
      if (alloc >= cap) break;
      alloc *= 2;
      buf = realloc(buf, alloc);
    }
    ssize_t got = read(fd, buf + size, alloc - size);
    if (got < 0 && errno == EINTR) continue;
    if (got <= 0) break;
    size += (size_t)got;
  }
  *out = buf;
  return size;
}

static int parse_snapshot(const char *buf, size_t len, struct snapshot *s) {
  memset(s, 0, sizeof *s);
  if (len < 13 || memcmp(buf, "OMVCLIP1\n", 9) != 0) return -1;
  uint32_t n;
  memcpy(&n, buf + 9, 4);
  size_t pos = 13;
  for (uint32_t i = 0; i < n && s->n < MAX_TYPES; i++) {
    const char *nul = memchr(buf + pos, 0, len - pos);
    if (!nul || (size_t)(nul - buf) + 9 > len) return -1;
    char *mime = strdup(buf + pos);
    pos = (size_t)(nul - buf) + 1;
    uint64_t l;
    memcpy(&l, buf + pos, 8);
    pos += 8;
    if (l > len - pos) { free(mime); return -1; }
    s->items[s->n].mime = mime;
    s->items[s->n].data = malloc(l ? l : 1);
    memcpy(s->items[s->n].data, buf + pos, l);
    s->items[s->n].len = l;
    s->n++;
    pos += l;
  }
  s->had_selection = s->n > 0;
  return 0;
}

static void cmd_load(void) {
  char *buf;
  size_t len = read_all(0, &buf, SNAPSHOT_CAP + (1u << 20));
  static struct snapshot s;
  if (parse_snapshot(buf, len, &s) != 0) die("bad-snapshot");
  free(buf);
  connect_wayland();
  if (s.n == 0) {
    ext_data_control_device_v1_set_selection(device, NULL);
    wl_display_roundtrip(display);
    printf("{\"ok\":true,\"types\":0}\n");
    return;
  }
  struct source *src = restore_source(&s);
  ext_data_control_device_v1_set_selection(device, src->obj);
  wl_display_roundtrip(display);
  printf("{\"ok\":true,\"types\":%d}\n", s.n);
  serve_in_background(src);
}

static void cmd_types(void) {
  connect_wayland();
  if (selection)
    for (int i = 0; i < selection->n; i++) printf("%s\n", selection->mimes[i]);
}

// ---------------------------------------------------------------- paste

// "shift+insert" -> wtype -M shift -k Insert -m shift
static int wtype_args(const char *keys, char **argv, int max) {
  static char buf[256];
  snprintf(buf, sizeof buf, "%s", keys);
  char *parts[8];
  int n = 0;
  for (char *tok = strtok(buf, "+"); tok && n < 8; tok = strtok(NULL, "+")) parts[n++] = tok;
  if (n == 0) return -1;
  int a = 0;
  argv[a++] = "wtype";
  static char keyname[64];
  for (int i = 0; i < n - 1 && a < max - 6; i++) {
    char *m = parts[i];
    if (!strcasecmp(m, "ctrl") || !strcasecmp(m, "control")) m = "ctrl";
    else if (!strcasecmp(m, "super") || !strcasecmp(m, "meta") || !strcasecmp(m, "logo")) m = "logo";
    else if (!strcasecmp(m, "shift")) m = "shift";
    else if (!strcasecmp(m, "alt")) m = "alt";
    else return -1;
    argv[a++] = "-M";
    argv[a++] = m;
  }
  // wtype takes XKB keysym names: Insert, v, Return.
  const char *k = parts[n - 1];
  if (strlen(k) == 1) snprintf(keyname, sizeof keyname, "%c", k[0]);
  else snprintf(keyname, sizeof keyname, "%c%s", k[0] & ~0x20, k + 1);
  argv[a++] = "-k";
  argv[a++] = keyname;
  for (int i = n - 2; i >= 0 && a < max - 3; i--) {
    argv[a++] = "-m";
    argv[a++] = argv[1 + i * 2 + 1];
  }
  argv[a] = NULL;
  return 0;
}

struct child_wait { pid_t pid; int status; int done; };

static int child_done(void *arg) {
  struct child_wait *w = arg;
  if (w->done) return 1;
  int st;
  if (waitpid(w->pid, &st, WNOHANG) == w->pid) {
    w->done = 1;
    w->status = st;
  }
  return w->done;
}

struct paste_wait { struct source *src; int64_t key_ms; int64_t wait_ms; };

// Done once the app has read the offer and gone quiet, or on timeout, or
// when something else took the clipboard.
static int paste_done(void *arg) {
  struct paste_wait *w = arg;
  int64_t t = now_ms();
  if (w->src->cancelled || device_finished) return 1;
  if (w->src->sends_after > 0 && t - w->src->last_send_ms >= 200 && t - w->key_ms >= 250) return 1;
  return t - w->key_ms >= w->wait_ms;
}

static void cmd_paste(int argc, char **argv) {
  const char *keys = "shift+insert";
  const char *paste_cmd = NULL;
  int settle_ms = 120, wait_ms = 2000;
  for (int i = 2; i < argc; i++) {
    if (!strcmp(argv[i], "--keys") && i + 1 < argc) keys = argv[++i];
    else if (!strcmp(argv[i], "--paste-cmd") && i + 1 < argc) paste_cmd = argv[++i];
    else if (!strcmp(argv[i], "--settle-ms") && i + 1 < argc) settle_ms = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--wait-ms") && i + 1 < argc) wait_ms = atoi(argv[++i]);
    else die("bad-arguments");
  }
  char *text;
  size_t text_len = read_all(0, &text, TEXT_CAP);
  if (text_len == 0) die("empty-text");

  char *wargv[24];
  if (!paste_cmd && wtype_args(keys, wargv, 24) != 0) die("bad-keys");

  connect_wayland();
  static struct snapshot snap;
  int64_t t0 = now_ms();
  take_snapshot(&snap, 1500);
  int64_t snap_ms = now_ms() - t0;

  struct source *paste = make_source();
  paste->text = text;
  paste->text_len = text_len;
  static const char *text_types[] = { "text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT", HINT_TYPE, NULL };
  for (int i = 0; text_types[i]; i++) ext_data_control_source_v1_offer(paste->obj, text_types[i]);
  ext_data_control_device_v1_set_selection(device, paste->obj);
  wl_display_roundtrip(display);
  // Let the selection settle; clipboard watchers read it here, before the
  // keystroke, so their reads are not mistaken for the paste.
  dispatch_for(settle_ms, is_cancelled, paste);

  struct child_wait cw = { 0 };
  paste->count_after_ms = now_ms();
  struct paste_wait pw = { paste, paste->count_after_ms, wait_ms };
  cw.pid = fork();
  if (cw.pid == 0) {
    int null = open("/dev/null", O_RDWR);
    dup2(null, 0);
    dup2(null, 1);
    if (paste_cmd) execl("/bin/sh", "sh", "-c", paste_cmd, (char *)NULL);
    else execvp("wtype", wargv);
    _exit(127);
  }
  // Serve the offer while the keystroke is delivered.
  dispatch_for(5000, child_done, &cw);
  int key_ok = cw.done && WIFEXITED(cw.status) && WEXITSTATUS(cw.status) == 0;
  if (!cw.done) kill(cw.pid, SIGKILL);
  dispatch_for(wait_ms + 500, paste_done, &pw);

  int read_by_app = paste->sends_after > 0;
  int changed = paste->cancelled;
  int restored = 0;
  struct source *back = NULL;
  if (!changed) {
    if (snap.n > 0) {
      back = restore_source(&snap);
      ext_data_control_device_v1_set_selection(device, back->obj);
      restored = 1;
    } else {
      // The clipboard was empty (or could not be read): leave it empty
      // rather than holding the dictation.
      ext_data_control_device_v1_set_selection(device, NULL);
      restored = !snap.had_selection;
    }
    wl_display_roundtrip(display);
  }
  printf("{\"ok\":%s,\"keystroke\":%s,\"read_by_app\":%s,\"reads\":%d,\"clipboard_changed\":%s,"
         "\"restored\":%s,\"had_clipboard\":%s,\"types\":%d,\"skipped_types\":%d,\"bytes\":%zu,"
         "\"snapshot_ms\":%lld,\"wait_ms\":%lld}\n",
         key_ok ? "true" : "false", key_ok ? "true" : "false", read_by_app ? "true" : "false",
         paste->sends_after, changed ? "true" : "false", restored ? "true" : "false",
         snap.had_selection ? "true" : "false", snap.n, snap.skipped, snap.bytes,
         (long long)snap_ms, (long long)(now_ms() - pw.key_ms));
  if (back) serve_in_background(back);
  exit(key_ok ? 0 : 3);
}

int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
  signal(SIGCHLD, SIG_DFL);
  if (argc < 2) {
    fprintf(stderr, "usage: omavoice-clipboard paste|dump|load|types\n");
    return 2;
  }
  if (!strcmp(argv[1], "paste")) cmd_paste(argc, argv);
  else if (!strcmp(argv[1], "dump")) cmd_dump();
  else if (!strcmp(argv[1], "load")) cmd_load();
  else if (!strcmp(argv[1], "types")) cmd_types();
  else {
    fprintf(stderr, "unknown command %s\n", argv[1]);
    return 2;
  }
  return 0;
}
