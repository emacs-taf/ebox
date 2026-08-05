#include <emacs-module.h>

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <errno.h>
#include <io.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#endif

typedef struct {
  unsigned char *data;
  size_t len;
} ebox_native_bytes;

typedef bool (*ebox_readiness_signal_fn)(int32_t fd);
typedef void (*ebox_readiness_close_fn)(int32_t fd);

extern void *ebox_native_session_create(uint32_t workers,
                                        uint32_t max_jobs,
                                        uint32_t max_results,
                                        uint64_t max_result_bytes,
                                        ebox_native_bytes *error);
extern int64_t ebox_native_session_submit(void *session,
                                          uint64_t generation,
                                          const unsigned char *payload,
                                          size_t payload_len,
                                          ebox_native_bytes *error);
extern bool ebox_native_session_ready(void *session,
                                      uint64_t generation,
                                      int64_t key);
extern ebox_native_bytes ebox_native_session_take(void *session,
                                                  uint64_t generation,
                                                  int64_t key);
extern bool ebox_native_session_confirm_frame(void *session,
                                              uint64_t generation,
                                              int64_t key,
                                              uint64_t confirmed_revision,
                                              ebox_native_bytes *error);
extern bool ebox_native_session_attach_readiness_channel(
  void *session, int32_t fd, ebox_readiness_signal_fn signal,
  ebox_readiness_close_fn close);
extern void ebox_native_session_detach_readiness_channel(void *session);
extern void ebox_native_session_cancel(void *session, uint64_t generation);
extern ebox_native_bytes ebox_native_session_stats(void *session);
extern void ebox_native_session_release(void *session);
extern void ebox_native_session_finalize(void *session);
extern void ebox_native_bytes_free(ebox_native_bytes bytes);
extern bool ebox_native_layout_ready(void);
extern bool ebox_native_render_proof(const unsigned char *payload,
                                     size_t payload_len,
                                     ebox_native_bytes *output);

static emacs_value
ebox_nil(emacs_env *env)
{
  return env->intern(env, "nil");
}

static emacs_value
ebox_true(emacs_env *env)
{
  return env->intern(env, "t");
}

static emacs_value
ebox_signal_error(emacs_env *env, const char *message, size_t length)
{
  emacs_value string = env->make_string(env, message, (ptrdiff_t) length);
  emacs_value data = env->funcall(env, env->intern(env, "list"), 1, &string);
  env->non_local_exit_signal(env, env->intern(env, "error"), data);
  return ebox_nil(env);
}

static emacs_value
ebox_signal_native_error(emacs_env *env, ebox_native_bytes error,
                         const char *fallback)
{
  emacs_value result;
  if (error.data != NULL && error.len > 0)
    result = ebox_signal_error(env, (const char *) error.data, error.len);
  else
    result = ebox_signal_error(env, fallback, strlen(fallback));
  ebox_native_bytes_free(error);
  return result;
}

static bool
ebox_copy_string(emacs_env *env, emacs_value value,
                 unsigned char **output, size_t *output_len)
{
  ptrdiff_t required = 0;
  if (!env->copy_string_contents(env, value, NULL, &required) || required <= 0)
    return false;
  unsigned char *buffer = malloc((size_t) required);
  if (buffer == NULL) {
    static const char message[] = "Native reflow input allocation failed";
    ebox_signal_error(env, message, sizeof message - 1);
    return false;
  }
  ptrdiff_t available = required;
  if (!env->copy_string_contents(env, value, (char *) buffer, &available)) {
    free(buffer);
    return false;
  }
  *output = buffer;
  *output_len = (size_t) (available - 1);
  return true;
}

static void
ebox_session_finalizer(void *pointer)
{
  if (pointer != NULL)
    ebox_native_session_finalize(pointer);
}

static void *
ebox_session_pointer(emacs_env *env, emacs_value value)
{
  void *session = env->get_user_ptr(env, value);
  if (session == NULL) {
    static const char message[] = "Native reflow session has been released";
    ebox_signal_error(env, message, sizeof message - 1);
  }
  return session;
}

static emacs_value
ebox_module_version(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                    void *data)
{
  (void) nargs;
  (void) args;
  (void) data;
  static const char version[] = "7:2:9";
  return env->make_string(env, version, (ptrdiff_t) (sizeof version - 1));
}

static bool
ebox_signal_readiness_fd(int32_t fd)
{
  unsigned char byte = 1;
#ifdef _WIN32
  int written = _write(fd, &byte, 1);
#else
  ssize_t written = write(fd, &byte, 1);
#endif
  if (written == 1)
    return true;
  return errno == EAGAIN
#ifdef EWOULDBLOCK
         || errno == EWOULDBLOCK
#endif
         ;
}

static void
ebox_close_readiness_fd(int32_t fd)
{
#ifdef _WIN32
  (void) _close(fd);
#else
  (void) close(fd);
#endif
}

static bool
ebox_make_nonblocking(int32_t fd)
{
#ifdef _WIN32
  (void) fd;
  return false;
#else
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0)
    return false;
  if ((flags & O_NONBLOCK) != 0)
    return true;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
#endif
}

static emacs_value
ebox_module_layout_ready(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                         void *data)
{
  (void) nargs;
  (void) args;
  (void) data;
  return ebox_native_layout_ready() ? ebox_true(env) : ebox_nil(env);
}

static emacs_value
ebox_module_create_session(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                           void *data)
{
  (void) nargs;
  (void) data;
  uint32_t workers = (uint32_t) env->extract_integer(env, args[0]);
  uint32_t max_jobs = (uint32_t) env->extract_integer(env, args[1]);
  uint32_t max_results = (uint32_t) env->extract_integer(env, args[2]);
  uint64_t max_result_bytes = (uint64_t) env->extract_integer(env, args[3]);
  if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
    return ebox_nil(env);
  ebox_native_bytes error = {0};
  void *session = ebox_native_session_create(workers, max_jobs, max_results,
                                             max_result_bytes, &error);
  if (session == NULL)
    return ebox_signal_native_error(env, error,
                                    "Native reflow session creation failed");
  return env->make_user_ptr(env, ebox_session_finalizer, session);
}

static emacs_value
ebox_module_submit(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                   void *data)
{
  (void) nargs;
  (void) data;
  void *session = ebox_session_pointer(env, args[0]);
  uint64_t generation = (uint64_t) env->extract_integer(env, args[1]);
  if (session == NULL ||
      env->non_local_exit_check(env) != emacs_funcall_exit_return)
    return ebox_nil(env);
  unsigned char *payload = NULL;
  size_t payload_len = 0;
  if (!ebox_copy_string(env, args[2], &payload, &payload_len))
    return ebox_nil(env);
  ebox_native_bytes error = {0};
  int64_t accepted = ebox_native_session_submit(
    session, generation, payload, payload_len, &error);
  free(payload);
  if (accepted < 0)
    return ebox_signal_native_error(env, error,
                                    "Native reflow submission failed");
  return env->make_integer(env, accepted);
}

static emacs_value
ebox_module_ready(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                  void *data)
{
  (void) nargs;
  (void) data;
  void *session = ebox_session_pointer(env, args[0]);
  uint64_t generation = (uint64_t) env->extract_integer(env, args[1]);
  int64_t key = (int64_t) env->extract_integer(env, args[2]);
  if (session == NULL ||
      env->non_local_exit_check(env) != emacs_funcall_exit_return)
    return ebox_nil(env);
  return ebox_native_session_ready(session, generation, key)
           ? ebox_true(env) : ebox_nil(env);
}

static emacs_value
ebox_module_take(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                 void *data)
{
  (void) nargs;
  (void) data;
  void *session = ebox_session_pointer(env, args[0]);
  uint64_t generation = (uint64_t) env->extract_integer(env, args[1]);
  int64_t key = (int64_t) env->extract_integer(env, args[2]);
  if (session == NULL ||
      env->non_local_exit_check(env) != emacs_funcall_exit_return)
    return ebox_nil(env);
  ebox_native_bytes bytes = ebox_native_session_take(session, generation, key);
  if (bytes.data == NULL)
    return ebox_nil(env);
  emacs_value result = env->make_unibyte_string(
    env, (const char *) bytes.data, (ptrdiff_t) bytes.len);
  ebox_native_bytes_free(bytes);
  return result;
}

static emacs_value
ebox_module_render_proof(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                         void *data)
{
  (void) nargs;
  (void) data;
  unsigned char *payload = NULL;
  size_t payload_len = 0;
  if (!ebox_copy_string(env, args[0], &payload, &payload_len))
    return ebox_nil(env);
  ebox_native_bytes output = {0};
  bool ok = ebox_native_render_proof(payload, payload_len, &output);
  free(payload);
  if (!ok)
    return ebox_signal_native_error(env, output,
                                    "Native proof render failed");
  emacs_value result = env->make_unibyte_string(
    env, (const char *) output.data, (ptrdiff_t) output.len);
  ebox_native_bytes_free(output);
  return result;
}

static emacs_value
ebox_module_confirm_frame(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                          void *data)
{
  (void) nargs;
  (void) data;
  void *session = ebox_session_pointer(env, args[0]);
  uint64_t generation = (uint64_t) env->extract_integer(env, args[1]);
  int64_t key = (int64_t) env->extract_integer(env, args[2]);
  uint64_t confirmed_revision = (uint64_t) env->extract_integer(env, args[3]);
  if (session == NULL ||
      env->non_local_exit_check(env) != emacs_funcall_exit_return)
    return ebox_nil(env);
  ebox_native_bytes error = {0};
  bool confirmed = ebox_native_session_confirm_frame(
    session, generation, key, confirmed_revision, &error);
  if (!confirmed && error.data != NULL)
    return ebox_signal_native_error(env, error,
                                    "Native reflow confirmation failed");
  ebox_native_bytes_free(error);
  return confirmed ? ebox_true(env) : ebox_nil(env);
}

static emacs_value
ebox_module_attach_readiness_channel(emacs_env *env, ptrdiff_t nargs,
                                     emacs_value *args, void *data)
{
  (void) nargs;
  (void) data;
  void *session = ebox_session_pointer(env, args[0]);
  if (session == NULL ||
      env->non_local_exit_check(env) != emacs_funcall_exit_return)
    return ebox_nil(env);
  if (env->size < (ptrdiff_t) (offsetof(emacs_env, open_channel)
                               + sizeof env->open_channel) ||
      env->open_channel == NULL) {
    static const char message[] = "Native readiness channels are unsupported";
    return ebox_signal_error(env, message, sizeof message - 1);
  }
  int fd = env->open_channel(env, args[1]);
  if (fd < 0 || env->non_local_exit_check(env) != emacs_funcall_exit_return)
    return ebox_nil(env);
  if (!ebox_make_nonblocking(fd)) {
    static const char message[] = "Native readiness channel setup failed";
    ebox_close_readiness_fd((int32_t) fd);
    return ebox_signal_error(env, message, sizeof message - 1);
  }
  if (ebox_native_session_attach_readiness_channel(
        session, (int32_t) fd, ebox_signal_readiness_fd,
        ebox_close_readiness_fd))
    return ebox_true(env);
  ebox_close_readiness_fd((int32_t) fd);
  return ebox_nil(env);
}

static emacs_value
ebox_module_detach_readiness_channel(emacs_env *env, ptrdiff_t nargs,
                                     emacs_value *args, void *data)
{
  (void) nargs;
  (void) data;
  void *session = ebox_session_pointer(env, args[0]);
  if (session == NULL ||
      env->non_local_exit_check(env) != emacs_funcall_exit_return)
    return ebox_nil(env);
  ebox_native_session_detach_readiness_channel(session);
  return ebox_true(env);
}

static emacs_value
ebox_module_cancel(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                   void *data)
{
  (void) nargs;
  (void) data;
  void *session = ebox_session_pointer(env, args[0]);
  uint64_t generation = (uint64_t) env->extract_integer(env, args[1]);
  if (session == NULL ||
      env->non_local_exit_check(env) != emacs_funcall_exit_return)
    return ebox_nil(env);
  ebox_native_session_cancel(session, generation);
  return ebox_true(env);
}

static emacs_value
ebox_module_stats(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                  void *data)
{
  (void) nargs;
  (void) data;
  void *session = ebox_session_pointer(env, args[0]);
  if (session == NULL)
    return ebox_nil(env);
  ebox_native_bytes bytes = ebox_native_session_stats(session);
  if (bytes.data == NULL) {
    static const char message[] = "Native reflow stats failed";
    return ebox_signal_error(env, message, sizeof message - 1);
  }
  emacs_value result = env->make_string(
    env, (const char *) bytes.data, (ptrdiff_t) bytes.len);
  ebox_native_bytes_free(bytes);
  return result;
}

static emacs_value
ebox_module_release(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                    void *data)
{
  (void) nargs;
  (void) data;
  void *session = env->get_user_ptr(env, args[0]);
  if (session != NULL) {
    env->set_user_ptr(env, args[0], NULL);
    ebox_native_session_release(session);
  }
  return ebox_true(env);
}

static int
ebox_bind_function(emacs_env *env, const char *name, ptrdiff_t min_arity,
                   ptrdiff_t max_arity, emacs_function function,
                   const char *docstring)
{
  emacs_value symbol = env->intern(env, name);
  emacs_value callable = env->make_function(
    env, min_arity, max_arity, function, docstring, NULL);
  emacs_value arguments[] = {symbol, callable};
  env->funcall(env, env->intern(env, "defalias"), 2, arguments);
  return env->non_local_exit_check(env) == emacs_funcall_exit_return ? 0 : 1;
}

int
ebox_module_init_impl(struct emacs_runtime *runtime)
{
  if (runtime == NULL || runtime->get_environment == NULL)
    return 1;
  emacs_env *env = runtime->get_environment(runtime);
  if (env == NULL ||
      env->size < (ptrdiff_t) (offsetof(emacs_env, make_unibyte_string)
                               + sizeof env->make_unibyte_string))
    return 2;

  if (ebox_bind_function(env, "ebox-native--module-version", 0, 0,
                         ebox_module_version,
                         "Return the private Ebox native ABI version.") ||
      ebox_bind_function(env, "ebox-native--module-layout-ready-p", 0, 0,
                         ebox_module_layout_ready,
                         "Return non-nil when native layout is implemented.") ||
      ebox_bind_function(env, "ebox-native--module-create-session", 4, 4,
                         ebox_module_create_session,
                         "Create one bounded private native session.") ||
      ebox_bind_function(env, "ebox-native--module-submit", 3, 3,
                         ebox_module_submit,
                         "Submit one private native control batch.") ||
      ebox_bind_function(env, "ebox-native--module-ready-p", 3, 3,
                         ebox_module_ready,
                         "Return non-nil when a private result is ready.") ||
      ebox_bind_function(env, "ebox-native--module-take", 3, 3,
                         ebox_module_take,
                         "Take one private native result as bytes.") ||
      ebox_bind_function(env, "ebox-native--module-render-proof", 1, 1,
                         ebox_module_render_proof,
                         "Render one private native proof synchronously.") ||
      ebox_bind_function(env, "ebox-native--module-confirm-frame", 4, 4,
                         ebox_module_confirm_frame,
                         "Confirm one published native layout frame.") ||
      ebox_bind_function(env, "ebox-native--module-attach-readiness-channel",
                         2, 2, ebox_module_attach_readiness_channel,
                         "Attach one native readiness pipe process.") ||
      ebox_bind_function(env, "ebox-native--module-detach-readiness-channel",
                         1, 1, ebox_module_detach_readiness_channel,
                         "Detach one native readiness pipe process.") ||
      ebox_bind_function(env, "ebox-native--module-cancel", 2, 2,
                         ebox_module_cancel,
                         "Cancel one private native generation.") ||
      ebox_bind_function(env, "ebox-native--module-stats", 1, 1,
                         ebox_module_stats,
                         "Return private native session stats as JSON.") ||
      ebox_bind_function(env, "ebox-native--module-release", 1, 1,
                         ebox_module_release,
                         "Release one private native session."))
    return 3;

  emacs_value feature = env->intern(env, "ebox-native-module");
  env->funcall(env, env->intern(env, "provide"), 1, &feature);
  return env->non_local_exit_check(env) == emacs_funcall_exit_return ? 0 : 4;
}
