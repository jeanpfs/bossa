#ifndef BOSE_CORE_H
#define BOSE_CORE_H
#ifdef __cplusplus
extern "C" {
#endif

/// Called on a Rust thread with one JSON event: {"type":"state","state":{...}} or {"type":"alert","title":..,"body":..}.
typedef void (*bose_event_cb)(void *ctx, const char *json);

void bose_start(bose_event_cb cb, void *ctx);
/// {"cmd":"set_mode","index":1} etc. Returns 0 when queued.
int bose_command(const char *json);
/// {"req":"get_prefs"|"set_pref"|"get_volume"|"set_volume",...} -> {"ok":...} | {"error":"..."}. Free with bose_free.
char *bose_request(const char *json);
void bose_free(char *p);

#ifdef __cplusplus
}
#endif
#endif
