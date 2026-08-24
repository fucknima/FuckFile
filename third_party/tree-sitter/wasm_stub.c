// Minimal wasm stubs: the runtime is compiled without wasm support.
// ts_language_is_wasm() always returns false, so these are never reached.
#include <tree_sitter/api.h>
#include <stdlib.h>

bool ts_language_is_wasm(const TSLanguage *language) { return false; }
const TSLanguage *ts_wasm_language_retain(const TSLanguage *language) { return language; }
void ts_wasm_language_release(const TSLanguage *language) { (void)language; }
TSWasmStore *ts_wasm_store_new(TSWasmEngine *engine, TSWasmError *error) { (void)engine; (void)error; return NULL; }
void ts_wasm_store_delete(TSWasmStore *store) { (void)store; }
const TSLanguage *ts_wasm_store_load_language(TSWasmStore *s, const char *n, const char *w, uint32_t l, TSWasmError *e) { (void)s; (void)n; (void)w; (void)l; (void)e; return NULL; }
size_t ts_wasm_store_language_count(const TSWasmStore *store) { (void)store; return 0; }
void ts_wasm_store_init(TSWasmStore *store, TSWasmEngine *engine) { (void)store; (void)engine; }
void ts_wasm_store_reset(TSWasmStore *store) { (void)store; }
void ts_wasm_store_start(TSWasmStore *store) { (void)store; }
void ts_wasm_store_call_lex_main(TSWasmStore *store) { (void)store; }
void ts_wasm_store_call_lex_keyword(TSWasmStore *store, unsigned long long n) { (void)store; (void)n; }
void *ts_wasm_store_call_scanner_create(TSWasmStore *store) { (void)store; return NULL; }
void ts_wasm_store_call_scanner_destroy(TSWasmStore *store, void *payload) { (void)store; (void)payload; }
unsigned ts_wasm_store_call_scanner_serialize(TSWasmStore *store, void *payload, char *buffer) { (void)store; (void)payload; (void)buffer; return 0; }
void ts_wasm_store_call_scanner_deserialize(TSWasmStore *store, void *payload, const char *buffer, unsigned length) { (void)store; (void)payload; (void)buffer; (void)length; }
bool ts_wasm_store_call_scanner_scan(TSWasmStore *store, void *payload) { (void)store; (void)payload; return false; }
bool ts_wasm_store_has_error(TSWasmStore *store) { (void)store; return false; }
