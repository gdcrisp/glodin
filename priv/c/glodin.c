#include "glodin.h"
#include <math.h>

_Static_assert(sizeof(ERL_NIF_TERM) == sizeof(uintptr_t), "unsupported NIF term ABI");
_Static_assert(sizeof(ErlNifPid) == sizeof(uintptr_t), "update Glodin's opaque PID adapter for this OTP ABI");

int glodin_get_i64(ErlNifEnv *e, ERL_NIF_TERM t, int64_t *out) { ErlNifSInt64 n; if (!enif_get_int64(e,t,&n)) return 0; *out=n; return 1; }
int glodin_get_u64(ErlNifEnv *e, ERL_NIF_TERM t, uint64_t *out) { ErlNifUInt64 n; if (!enif_get_uint64(e,t,&n)) return 0; *out=n; return 1; }
ERL_NIF_TERM glodin_make_i64(ErlNifEnv *e, int64_t v) { return enif_make_int64(e,v); }
ERL_NIF_TERM glodin_make_u64(ErlNifEnv *e, uint64_t v) { return enif_make_uint64(e,v); }
int glodin_get_float(ErlNifEnv *e, ERL_NIF_TERM t, double *out) { return enif_get_double(e,t,out); }
ERL_NIF_TERM glodin_make_float(ErlNifEnv *e, double v) { return isfinite(v) ? enif_make_double(e,v) : enif_make_badarg(e); }
int glodin_inspect_binary(ErlNifEnv *e, ERL_NIF_TERM t, const unsigned char **data, size_t *size) { ErlNifBinary b; if (!enif_inspect_binary(e,t,&b)) return 0; *data=b.data; *size=b.size; return 1; }
ERL_NIF_TERM glodin_make_bytes(ErlNifEnv *e, const unsigned char *data, size_t size) { ERL_NIF_TERM t; unsigned char *out=enif_make_new_binary(e,size,&t); if (!out && size) return enif_make_badarg(e); if(size) memcpy(out,data,size); return t; }
ERL_NIF_TERM glodin_atom(ErlNifEnv *e, const char *data, size_t size, int existing) { ERL_NIF_TERM t=0; if (existing) enif_make_existing_atom_len(e,data,size,&t,ERL_NIF_UTF8); else if (!enif_make_new_atom_len(e,data,size,&t,ERL_NIF_UTF8)) return enif_make_badarg(e); return t; }
int glodin_atom_name(ErlNifEnv *e, ERL_NIF_TERM t, char *data, unsigned size) { return enif_get_atom(e,t,data,size,ERL_NIF_UTF8); }
int glodin_is_atom(ErlNifEnv *e, ERL_NIF_TERM t) { return enif_is_atom(e,t); }
ERL_NIF_TERM glodin_badarg(ErlNifEnv *e) { return enif_make_badarg(e); }
ERL_NIF_TERM glodin_raise(ErlNifEnv *e, ERL_NIF_TERM reason) { return enif_raise_exception(e,reason); }
int glodin_get_tuple(ErlNifEnv *e, ERL_NIF_TERM t, int *size, const ERL_NIF_TERM **terms) { return enif_get_tuple(e,t,size,terms); }
ERL_NIF_TERM glodin_tuple(ErlNifEnv *e, const ERL_NIF_TERM *terms, unsigned size) { return enif_make_tuple_from_array(e,terms,size); }
int glodin_list_cell(ErlNifEnv *e, ERL_NIF_TERM t, ERL_NIF_TERM *head, ERL_NIF_TERM *tail) { return enif_get_list_cell(e,t,head,tail); }
int glodin_list_length(ErlNifEnv *e, ERL_NIF_TERM t, unsigned *length) { return enif_get_list_length(e,t,length); }
int glodin_is_empty_list(ErlNifEnv *e, ERL_NIF_TERM t) { return enif_is_empty_list(e,t); }
ERL_NIF_TERM glodin_cons(ErlNifEnv *e, ERL_NIF_TERM head, ERL_NIF_TERM tail) { return enif_make_list_cell(e,head,tail); }
ERL_NIF_TERM glodin_empty_list(ErlNifEnv *e) { return enif_make_list(e,0); }
int glodin_map_get(ErlNifEnv *e, ERL_NIF_TERM t, ERL_NIF_TERM key, ERL_NIF_TERM *value) { return enif_get_map_value(e,t,key,value); }
ERL_NIF_TERM glodin_map_new(ErlNifEnv *e) { return enif_make_new_map(e); }
int glodin_map_put(ErlNifEnv *e, ERL_NIF_TERM map, ERL_NIF_TERM key, ERL_NIF_TERM value, ERL_NIF_TERM *out) { return enif_make_map_put(e,map,key,value,out); }
void *glodin_map_iterator(ErlNifEnv *e, ERL_NIF_TERM map) { ErlNifMapIterator *it=enif_alloc(sizeof(*it)); if (!it) return NULL; if (!enif_map_iterator_create(e,map,it,ERL_NIF_MAP_ITERATOR_FIRST)) { enif_free(it); return NULL; } return it; }
void *glodin_map_iterator_last(ErlNifEnv *e, ERL_NIF_TERM map) { ErlNifMapIterator *it=enif_alloc(sizeof(*it)); if (!it) return NULL; if (!enif_map_iterator_create(e,map,it,ERL_NIF_MAP_ITERATOR_LAST)) { enif_free(it); return NULL; } return it; }
int glodin_map_pair(ErlNifEnv *e, void *ptr, ERL_NIF_TERM *key, ERL_NIF_TERM *value) { ErlNifMapIterator *it=ptr; if (!enif_map_iterator_get_pair(e,it,key,value)) return 0; enif_map_iterator_next(e,it); return 1; }
int glodin_map_pair_previous(ErlNifEnv *e, void *ptr, ERL_NIF_TERM *key, ERL_NIF_TERM *value) { ErlNifMapIterator *it=ptr; if (!enif_map_iterator_get_pair(e,it,key,value)) return 0; enif_map_iterator_prev(e,it); return 1; }
void glodin_map_iterator_free(ErlNifEnv *e, void *it) { if(it) { enif_map_iterator_destroy(e,it); enif_free(it); } }
ErlNifEnv *glodin_alloc_env(void) { return enif_alloc_env(); }
void glodin_free_env(ErlNifEnv *e) { enif_free_env(e); }
void glodin_clear_env(ErlNifEnv *e) { enif_clear_env(e); }
ERL_NIF_TERM glodin_copy(ErlNifEnv *to, ERL_NIF_TERM t) { return enif_make_copy(to,t); }
void *glodin_alloc(size_t n) { return enif_alloc(n); }
void *glodin_realloc(void *p, size_t n) { return enif_realloc(p,n); }
void glodin_free(void *p) { enif_free(p); }
void *glodin_private(ErlNifEnv *e) { return enif_priv_data(e); }
int glodin_consume_timeslice(ErlNifEnv *e, int percent) { return enif_consume_timeslice(e,percent); }
int glodin_alive(ErlNifEnv *e) { return enif_is_current_process_alive(e); }
int glodin_compare(ERL_NIF_TERM a, ERL_NIF_TERM b) { return enif_compare(a,b); }
int glodin_identical(ERL_NIF_TERM a, ERL_NIF_TERM b) { return enif_is_identical(a,b); }
int glodin_term_type(ErlNifEnv *e, ERL_NIF_TERM t) { return enif_term_type(e,t); }
int glodin_get_pid(ErlNifEnv *e, ERL_NIF_TERM t, ErlNifPid *p) { return enif_get_local_pid(e,t,p); }
ERL_NIF_TERM glodin_make_pid(ErlNifEnv *e, const ErlNifPid *p) { return enif_make_pid(e,p); }
int glodin_self(ErlNifEnv *e, ErlNifPid *p) { return enif_self(e,p)!=NULL; }
int glodin_send(ErlNifEnv *e, ErlNifPid *p, ErlNifEnv *me, ERL_NIF_TERM msg) { return enif_send(e,p,me,msg); }
ERL_NIF_TERM glodin_reference(ErlNifEnv *e) { return enif_make_ref(e); }
int glodin_is_reference(ErlNifEnv *e, ERL_NIF_TERM t) { return enif_is_ref(e,t); }
void *glodin_owned_binary(size_t n) { ErlNifBinary *b=enif_alloc(sizeof(*b)); if(!b) return NULL; if(!enif_alloc_binary(n,b)) { enif_free(b); return NULL; } if(n) memset(b->data,0,n); return b; }
unsigned char *glodin_owned_binary_data(void *b) { return ((ErlNifBinary*)b)->data; }
size_t glodin_owned_binary_size(void *b) { return ((ErlNifBinary*)b)->size; }
int glodin_owned_binary_resize(void *ptr,size_t n) { ErlNifBinary *b=ptr; size_t old=b->size; if(!enif_realloc_binary(b,n)) return 0; if(n>old) memset(b->data+old,0,n-old); return 1; }
void glodin_owned_binary_free(void *b) { if(b) { enif_release_binary(b); enif_free(b); } }
ERL_NIF_TERM glodin_owned_binary_release(ErlNifEnv *e,void *b) { ERL_NIF_TERM t=enif_make_binary(e,b); enif_free(b); return t; }
void *glodin_external_binary(ErlNifEnv *e,ERL_NIF_TERM t) { ErlNifBinary *b=enif_alloc(sizeof(*b)); if(!b) return NULL; if(!enif_term_to_binary(e,t,b)) { enif_free(b); return NULL; } return b; }
int glodin_from_external(ErlNifEnv *e,const unsigned char *p,size_t n,ERL_NIF_TERM *t) { return enif_binary_to_term(e,p,n,t,ERL_NIF_BIN2TERM_SAFE)==n; }
void *glodin_open_resource(ErlNifEnv *e, const char *name, ErlNifResourceDtor *dtor, ErlNifResourceDown *down, ErlNifResourceStop *stop, ErlNifResourceDynCall *dyncall) { ErlNifResourceTypeInit init={0}; init.dtor=dtor; init.down=down; init.stop=stop; init.dyncall=dyncall; init.members=4; return enif_init_resource_type(e,name,&init,ERL_NIF_RT_CREATE|ERL_NIF_RT_TAKEOVER,NULL); }
int glodin_inspect_iolist(ErlNifEnv *e, ERL_NIF_TERM t, const unsigned char **data, size_t *size) { ErlNifBinary b; if (!enif_inspect_iolist_as_binary(e,t,&b)) return 0; *data=b.data; *size=b.size; return 1; }
ERL_NIF_TERM glodin_sub_binary(ErlNifEnv *e, ERL_NIF_TERM t, size_t offset, size_t size) { return enif_make_sub_binary(e,t,offset,size); }
size_t glodin_binary_to_term(ErlNifEnv *e, const unsigned char *data, size_t size, ERL_NIF_TERM *t, int trusted) { return enif_binary_to_term(e,data,size,t,trusted ? 0 : ERL_NIF_BIN2TERM_SAFE); }
void *glodin_resource_alloc(void *type,size_t size) { return enif_alloc_resource(type,size); }
ERL_NIF_TERM glodin_resource_term(ErlNifEnv *e,void *p) { return enif_make_resource(e,p); }
int glodin_resource_get(ErlNifEnv *e,ERL_NIF_TERM t,void *type,void **out) { return enif_get_resource(e,t,type,out); }
void glodin_resource_keep(void *p) { enif_keep_resource(p); }
void glodin_resource_release(void *p) { enif_release_resource(p); }
ERL_NIF_TERM glodin_resource_binary(ErlNifEnv *e,void *p,const void *data,size_t size) { return enif_make_resource_binary(e,p,data,size); }
int glodin_monitor(ErlNifEnv *e,void *p,ErlNifPid *pid,ErlNifMonitor *m) { return enif_monitor_process(e,p,pid,m); }
int glodin_demonitor(ErlNifEnv *e,void *p,ErlNifMonitor *m) { return enif_demonitor_process(e,p,m); }
size_t glodin_monitor_size(void) { return sizeof(ErlNifMonitor); }
int glodin_select(ErlNifEnv *e,ErlNifEvent event,int flags,void *p,ErlNifPid *pid,ERL_NIF_TERM ref) { return enif_select(e,event,flags,p,pid,ref); }
void *glodin_mutex_new(void) { return enif_mutex_create("glodin_resource"); }
void glodin_mutex_lock(void *p) { enif_mutex_lock(p); }
void glodin_mutex_unlock(void *p) { enif_mutex_unlock(p); }
void glodin_mutex_free(void *p) { enif_mutex_destroy(p); }
int64_t glodin_monotonic_time(int unit) { return enif_monotonic_time((ErlNifTimeUnit)unit); }
int64_t glodin_time_offset(int unit) { return enif_time_offset((ErlNifTimeUnit)unit); }
int64_t glodin_convert_time(int64_t value,int from,int to) { return enif_convert_time_unit(value,(ErlNifTimeUnit)from,(ErlNifTimeUnit)to); }
ERL_NIF_TERM glodin_schedule(ErlNifEnv *e,const char *name,int flags,void *callback,int argc,const ERL_NIF_TERM *argv) { return enif_schedule_nif(e,name,flags,(ERL_NIF_TERM(*)(ErlNifEnv*,int,const ERL_NIF_TERM*))callback,argc,argv); }

/* An ABI escape hatch generated by OTP's own function list, including APIs
 * newer than Glodin's typed convenience layer. Callers supply the exact C type. */
void *glodin_api_lookup(const char *name) {
#include "glodin_api_lookup.inc"
    return NULL;
}
