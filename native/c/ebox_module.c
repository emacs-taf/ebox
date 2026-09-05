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

typedef struct {
  int64_t base;
  int64_t hypothetical;
  int64_t min_main;
  int64_t max_main;
  double grow;
  double shrink;
  bool max_known;
} ebox_native_flex_item;

typedef bool (*ebox_readiness_signal_fn)(int32_t fd);
typedef void (*ebox_readiness_close_fn)(int32_t fd);

extern void *ebox_native_session_create(uint32_t workers,
                                        uint32_t max_jobs,
                                        uint32_t max_results,
                                        uint64_t max_result_bytes,
                                        ebox_native_bytes *error);
extern void *ebox_native_session_fork_confirmed(void *source,
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
extern bool ebox_native_session_render_sync(void *session,
                                            uint64_t generation,
                                            const unsigned char *payload,
                                            size_t payload_len,
                                            ebox_native_bytes *output);
extern bool ebox_native_flex_size_lines(const ebox_native_flex_item *items,
                                        size_t item_count,
                                        const size_t *line_offsets,
                                        size_t line_count,
                                        int64_t main_limit,
                                        int64_t main_gap,
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
  static const char version[] = "12:7:12";
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
ebox_module_fork_confirmed(emacs_env *env, ptrdiff_t nargs,
                           emacs_value *args, void *data)
{
  (void) nargs;
  (void) data;
  void *source = ebox_session_pointer(env, args[0]);
  if (source == NULL ||
      env->non_local_exit_check(env) != emacs_funcall_exit_return)
    return ebox_nil(env);
  ebox_native_bytes error = {0};
  void *session = ebox_native_session_fork_confirmed(source, &error);
  if (session == NULL)
    return ebox_signal_native_error(env, error,
                                    "Native confirmed session fork failed");
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

static bool
ebox_read_u16(const unsigned char *bytes, size_t length, size_t offset,
              uint16_t *value)
{
  if (offset > length || length - offset < 2)
    return false;
  *value = (uint16_t) bytes[offset] | ((uint16_t) bytes[offset + 1] << 8);
  return true;
}

static bool
ebox_read_u32(const unsigned char *bytes, size_t length, size_t offset,
              uint32_t *value)
{
  if (offset > length || length - offset < 4)
    return false;
  *value = (uint32_t) bytes[offset]
           | ((uint32_t) bytes[offset + 1] << 8)
           | ((uint32_t) bytes[offset + 2] << 16)
           | ((uint32_t) bytes[offset + 3] << 24);
  return true;
}

static bool
ebox_read_u64(const unsigned char *bytes, size_t length, size_t offset,
              uint64_t *value)
{
  if (offset > length || length - offset < 8)
    return false;
  uint64_t result = 0;
  for (size_t index = 0; index < 8; index++)
    result |= (uint64_t) bytes[offset + index] << (index * 8);
  *value = result;
  return true;
}

static bool
ebox_checked_add(size_t left, size_t right, size_t *result)
{
  if (right > SIZE_MAX - left)
    return false;
  *result = left + right;
  return true;
}

static bool
ebox_fragment_section(const unsigned char *bytes, size_t length,
                      size_t *start, size_t *fragment_length,
                      size_t *record_count)
{
  static const size_t header_length = 112;
  uint16_t version = 0;
  uint16_t flags = 0;
  uint32_t encoded_header_length = 0;
  uint64_t encoded_total_length = 0;
  uint64_t fragment_bytes = 0;
  uint64_t fragment_records = 0;
  if (length < header_length
      || memcmp(bytes, "EBXT", 4) != 0
      || !ebox_read_u16(bytes, length, 4, &version)
      || version != 12
      || !ebox_read_u16(bytes, length, 6, &flags)
      || !ebox_read_u32(bytes, length, 8, &encoded_header_length)
      || encoded_header_length != header_length
      || !ebox_read_u64(bytes, length, 12, &encoded_total_length)
      || encoded_total_length != length)
    return false;

  size_t offset = header_length;
  if ((flags & 4) != 0) {
    uint32_t patch_count = 0;
    uint32_t coordinate_patch_count = 0;
    uint64_t payload_length = 0;
    if (!ebox_read_u32(bytes, length, 120, &patch_count)
        || !ebox_read_u64(bytes, length, 136, &payload_length)
        || !ebox_read_u64(bytes, length, 144, &fragment_bytes)
        || !ebox_read_u64(bytes, length, 152, &fragment_records)
        || !ebox_read_u32(bytes, length, 160, &coordinate_patch_count))
      return false;
    size_t descriptor_bytes = 0;
    if ((size_t) patch_count > SIZE_MAX - (size_t) coordinate_patch_count
        || (size_t) patch_count + (size_t) coordinate_patch_count
             > SIZE_MAX / 32)
      return false;
    descriptor_bytes = ((size_t) patch_count + (size_t) coordinate_patch_count)
                       * 32;
    if (!ebox_checked_add(offset, 56, &offset)
        || !ebox_checked_add(offset, descriptor_bytes, &offset)
        || payload_length > SIZE_MAX
        || !ebox_checked_add(offset, (size_t) payload_length, &offset))
      return false;
  } else {
    uint64_t literal_length = 0;
    uint32_t line_count = 0;
    uint32_t metadata_length = 0;
    if (!ebox_read_u64(bytes, length, 112, &literal_length)
        || !ebox_read_u32(bytes, length, 120, &line_count)
        || !ebox_read_u32(bytes, length, 124, &metadata_length)
        || !ebox_read_u64(bytes, length, 136, &fragment_bytes)
        || !ebox_read_u64(bytes, length, 144, &fragment_records))
      return false;
    size_t width_bytes = 0;
    if ((size_t) line_count > SIZE_MAX / 8)
      return false;
    width_bytes = (size_t) line_count * 8;
    if (!ebox_checked_add(offset, 40, &offset)
        || !ebox_checked_add(offset, width_bytes, &offset)
        || literal_length > SIZE_MAX
        || !ebox_checked_add(offset, (size_t) literal_length, &offset)
        || !ebox_checked_add(offset, (size_t) metadata_length, &offset))
      return false;
  }
  if (fragment_bytes > SIZE_MAX || fragment_records > SIZE_MAX
      || offset > length || (size_t) fragment_bytes != length - offset)
    return false;
  *start = offset;
  *fragment_length = (size_t) fragment_bytes;
  *record_count = (size_t) fragment_records;
  return true;
}

static bool
ebox_fragment_flat_length(const unsigned char *bytes, size_t length,
                          size_t record_count, size_t *scalar_count)
{
  size_t cursor = 0;
  size_t scalars = 0;
  for (size_t record = 0; record < record_count; record++) {
    uint32_t roles = 0;
    uint32_t templates = 0;
    uint32_t styles = 0;
    uint32_t reserved = 0;
    if (cursor > length || length - cursor < 56
        || !ebox_read_u32(bytes, length, cursor + 40, &roles)
        || !ebox_read_u32(bytes, length, cursor + 44, &templates)
        || !ebox_read_u32(bytes, length, cursor + 48, &styles)
        || !ebox_read_u32(bytes, length, cursor + 52, &reserved)
        || reserved != 0)
      return false;
    size_t variable = 0;
    if ((size_t) roles > SIZE_MAX / 9
        || (size_t) templates > SIZE_MAX / 4
        || (size_t) styles > SIZE_MAX / 4
        || !ebox_checked_add((size_t) roles * 9,
                             (size_t) templates * 4, &variable)
        || !ebox_checked_add(variable, (size_t) styles * 4, &variable)
        || !ebox_checked_add(cursor, 56, &cursor)
        || !ebox_checked_add(cursor, variable, &cursor))
      return false;
    size_t record_scalars = 8;
    if ((size_t) roles > (SIZE_MAX - record_scalars) / 2)
      return false;
    record_scalars += (size_t) roles * 2;
    if (!ebox_checked_add(record_scalars, (size_t) templates,
                          &record_scalars)
        || !ebox_checked_add(record_scalars, (size_t) styles,
                             &record_scalars)
        || !ebox_checked_add(scalars, record_scalars, &scalars))
      return false;
  }
  if (cursor != length || scalars > PTRDIFF_MAX)
    return false;
  *scalar_count = scalars;
  return true;
}

static bool
ebox_flat_set(emacs_env *env, emacs_value vector, size_t *index,
              int64_t value)
{
  env->vec_set(env, vector, (ptrdiff_t) *index,
               env->make_integer(env, (intmax_t) value));
  (*index)++;
  return env->non_local_exit_check(env) == emacs_funcall_exit_return;
}

static emacs_value
ebox_fragment_flat_vector(emacs_env *env, const unsigned char *bytes,
                          size_t length, size_t record_count)
{
  size_t scalar_count = 0;
  if (!ebox_fragment_flat_length(bytes, length, record_count, &scalar_count)) {
    static const char message[] = "Native reflow fragment tape is malformed";
    return ebox_signal_error(env, message, sizeof message - 1);
  }
  emacs_value make_args[] = {
    env->make_integer(env, (intmax_t) scalar_count), ebox_nil(env)
  };
  emacs_value vector = env->funcall(env, env->intern(env, "make-vector"),
                                    2, make_args);
  if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
    return ebox_nil(env);

  size_t cursor = 0;
  size_t output = 0;
  for (size_t record = 0; record < record_count; record++) {
    uint64_t start = 0;
    uint64_t end = 0;
    uint64_t line = 0;
    uint64_t owner = 0;
    uint64_t content_index = 0;
    uint32_t roles = 0;
    uint32_t templates = 0;
    uint32_t styles = 0;
    ebox_read_u64(bytes, length, cursor, &start);
    ebox_read_u64(bytes, length, cursor + 8, &end);
    ebox_read_u64(bytes, length, cursor + 16, &line);
    ebox_read_u64(bytes, length, cursor + 24, &owner);
    ebox_read_u64(bytes, length, cursor + 32, &content_index);
    ebox_read_u32(bytes, length, cursor + 40, &roles);
    ebox_read_u32(bytes, length, cursor + 44, &templates);
    ebox_read_u32(bytes, length, cursor + 48, &styles);
    if (start > INT64_MAX || end > INT64_MAX || line > INT64_MAX
        || !ebox_flat_set(env, vector, &output, (int64_t) start)
        || !ebox_flat_set(env, vector, &output, (int64_t) end)
        || !ebox_flat_set(env, vector, &output, (int64_t) line)
        || !ebox_flat_set(env, vector, &output, (int64_t) owner)
        || !ebox_flat_set(env, vector, &output, (int64_t) content_index)
        || !ebox_flat_set(env, vector, &output, (int64_t) roles)
        || !ebox_flat_set(env, vector, &output, (int64_t) templates)
        || !ebox_flat_set(env, vector, &output, (int64_t) styles))
      return ebox_nil(env);
    cursor += 56;
    for (uint32_t role = 0; role < roles; role++) {
      uint8_t kind = bytes[cursor];
      uint64_t region = 0;
      ebox_read_u64(bytes, length, cursor + 1, &region);
      if (region > INT64_MAX
          || !ebox_flat_set(env, vector, &output, kind)
          || !ebox_flat_set(env, vector, &output, (int64_t) region))
        return ebox_nil(env);
      cursor += 9;
    }
    for (uint32_t index = 0; index < templates + styles; index++) {
      uint32_t value = 0;
      ebox_read_u32(bytes, length, cursor, &value);
      if (!ebox_flat_set(env, vector, &output, value))
        return ebox_nil(env);
      cursor += 4;
    }
  }
  return vector;
}

static emacs_value
ebox_module_render_frame(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
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
                                    "Native frame render failed");
  size_t fragment_start = 0;
  size_t fragment_length = 0;
  size_t record_count = 0;
  if (!ebox_fragment_section(output.data, output.len, &fragment_start,
                             &fragment_length, &record_count)) {
    ebox_native_bytes_free(output);
    static const char message[] = "Native frame has an invalid effect tape";
    return ebox_signal_error(env, message, sizeof message - 1);
  }
  emacs_value tape = env->make_unibyte_string(
    env, (const char *) output.data, (ptrdiff_t) output.len);
  emacs_value flat = ebox_fragment_flat_vector(
    env, output.data + fragment_start, fragment_length, record_count);
  ebox_native_bytes_free(output);
  if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
    return ebox_nil(env);
  emacs_value values[] = {
    tape, flat, env->make_integer(env, (intmax_t) record_count)
  };
  return env->funcall(env, env->intern(env, "vector"), 3, values);
}

static emacs_value
ebox_module_render_session_frame(emacs_env *env, ptrdiff_t nargs,
                                 emacs_value *args, void *data)
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
  ebox_native_bytes output = {0};
  bool ok = ebox_native_session_render_sync(
    session, generation, payload, payload_len, &output);
  free(payload);
  if (!ok)
    return ebox_signal_native_error(env, output,
                                    "Native retained frame render failed");
  size_t fragment_start = 0;
  size_t fragment_length = 0;
  size_t record_count = 0;
  if (!ebox_fragment_section(output.data, output.len, &fragment_start,
                             &fragment_length, &record_count)) {
    ebox_native_bytes_free(output);
    static const char message[] =
      "Native retained frame has an invalid effect tape";
    return ebox_signal_error(env, message, sizeof message - 1);
  }
  emacs_value tape = env->make_unibyte_string(
    env, (const char *) output.data, (ptrdiff_t) output.len);
  emacs_value flat = ebox_fragment_flat_vector(
    env, output.data + fragment_start, fragment_length, record_count);
  ebox_native_bytes_free(output);
  if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
    return ebox_nil(env);
  emacs_value values[] = {
    tape, flat, env->make_integer(env, (intmax_t) record_count)
  };
  return env->funcall(env, env->intern(env, "vector"), 3, values);
}

static bool
ebox_extract_flex_integer(emacs_env *env, emacs_value value, int64_t *output)
{
  *output = (int64_t) env->extract_integer(env, value);
  return env->non_local_exit_check(env) == emacs_funcall_exit_return;
}

static bool
ebox_extract_flex_float(emacs_env *env, emacs_value value, double *output)
{
  *output = env->extract_float(env, value);
  return env->non_local_exit_check(env) == emacs_funcall_exit_return;
}

static emacs_value
ebox_module_flex_size_lines(emacs_env *env, ptrdiff_t nargs,
                            emacs_value *args, void *data)
{
  (void) nargs;
  (void) data;
  ptrdiff_t packed_size = env->vec_size(env, args[0]);
  if (env->non_local_exit_check(env) != emacs_funcall_exit_return ||
      packed_size < 1) {
    return ebox_nil(env);
  }
  int64_t line_count_value = 0;
  if (!ebox_extract_flex_integer(env, env->vec_get(env, args[0], 0),
                                 &line_count_value) ||
      line_count_value < 0 || line_count_value > 2048) {
    return ebox_nil(env);
  }
  size_t line_count = (size_t) line_count_value;
  size_t *line_offsets = calloc(line_count + 1, sizeof *line_offsets);
  ebox_native_flex_item *items = NULL;
  size_t item_capacity = 0;
  size_t item_count = 0;
  ptrdiff_t cursor = 1;
  bool valid = line_offsets != NULL;
  for (size_t line = 0; valid && line < line_count; line++) {
    int64_t line_length_value = 0;
    if (cursor >= packed_size ||
        !ebox_extract_flex_integer(env, env->vec_get(env, args[0], cursor++),
                                   &line_length_value) ||
        line_length_value < 0 || line_length_value > 8192) {
      valid = false;
      break;
    }
    size_t line_length = (size_t) line_length_value;
    if (item_count > 8192 - line_length) {
      valid = false;
      break;
    }
    if (item_count + line_length > item_capacity) {
      size_t next_capacity = item_count + line_length;
      ebox_native_flex_item *next = realloc(
        items, next_capacity * sizeof *items);
      if (next == NULL) {
        valid = false;
        break;
      }
      items = next;
      item_capacity = next_capacity;
    }
    line_offsets[line] = item_count;
    for (size_t item = 0; item < line_length && valid; item++) {
      ebox_native_flex_item *target = &items[item_count++];
      if (cursor + 6 > packed_size ||
          !ebox_extract_flex_integer(env, env->vec_get(env, args[0], cursor++),
                                     &target->base) ||
          !ebox_extract_flex_integer(env, env->vec_get(env, args[0], cursor++),
                                     &target->hypothetical) ||
          !ebox_extract_flex_integer(env, env->vec_get(env, args[0], cursor++),
                                     &target->min_main)) {
        valid = false;
        break;
      }
      emacs_value max_value = env->vec_get(env, args[0], cursor++);
      target->max_known = env->is_not_nil(env, max_value);
      if (env->non_local_exit_check(env) != emacs_funcall_exit_return ||
          (target->max_known &&
           !ebox_extract_flex_integer(env, max_value, &target->max_main)) ||
          !ebox_extract_flex_float(
            env, env->vec_get(env, args[0], cursor++), &target->grow) ||
          !ebox_extract_flex_float(
            env, env->vec_get(env, args[0], cursor++), &target->shrink)) {
        valid = false;
        break;
      }
    }
    line_offsets[line + 1] = item_count;
  }
  int64_t main_limit = 0;
  int64_t main_gap = 0;
  if (cursor != packed_size ||
      !ebox_extract_flex_integer(env, args[1], &main_limit) ||
      !ebox_extract_flex_integer(env, args[2], &main_gap)) {
    valid = false;
  }
  if (!valid) {
    free(items);
    free(line_offsets);
    return ebox_nil(env);
  }
  ebox_native_bytes output = {0};
  bool ok = ebox_native_flex_size_lines(
    items, item_count, line_offsets, line_count, main_limit, main_gap,
    &output);
  free(items);
  free(line_offsets);
  if (!ok || output.data == NULL) {
    ebox_native_bytes_free(output);
    return ebox_nil(env);
  }
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
      ebox_bind_function(env, "ebox-native--module-fork-confirmed", 1, 1,
                         ebox_module_fork_confirmed,
                         "Fork one confirmed private native session.") ||
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
      ebox_bind_function(env, "ebox-native--module-render-frame", 1, 1,
                         ebox_module_render_frame,
                         "Render one native frame with decoded effects.") ||
      ebox_bind_function(env, "ebox-native--module-render-session-frame", 3, 3,
                         ebox_module_render_session_frame,
                         "Render one retained native frame synchronously.") ||
      ebox_bind_function(env, "ebox-native--module-flex-size-lines", 3, 3,
                         ebox_module_flex_size_lines,
                         "Calculate pure native Flex geometry lines.") ||
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
