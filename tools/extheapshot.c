/* vim: noet sw=8
 * This is a butchered version of the Mono log profiler; most features have
 * been removed, except for some features needed for heap analysis of niecza
 * which have been added.  Changes by sorear.
 */

/*
 * proflog.c: mono log profiler
 *
 * Author:
 *   Paolo Molaro (lupus@ximian.com)
 *
 * Copyright 2010 Novell, Inc (http://www.novell.com)
 * Copyright 2011 Xamarin Inc (http://www.xamarin.com)
 */

#include <mono/metadata/profiler.h>
#include <mono/metadata/threads.h>
#include <mono/metadata/mono-gc.h>
#include <mono/metadata/debug-helpers.h>

#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* For each heap shot, we do BFS to find the shortest route from the root set
 * to (all objects), then explain a sample of objects to see retention. */

/* tracks per-object data */
struct obj_info {
	MonoObject* addr; /* where is the object?  primary key. */
	size_t first_ptr; /* rference to NULL-terminated list of referees */
	ssize_t size;     /* byte count */
	size_t total_size;/* for fast picking */
	struct obj_info* prev; /* filled by BFS; points to previous */
};
/* size == -1 indicates a root pseudo-info where total_size is actually
   the root type word */

/* we keep the roots in a hash set */
struct root_hash_link {
	struct root_hash_link* next;
	MonoObject* root;
	struct obj_info pseudo_info;
};

/* holds per-image information for the types that are duplicated between Kernel
   and Run.Kernel */
struct per_image {
	MonoImage* image;
	MonoClass* p6any;
	MonoClass* stable;
	MonoClass* cursor;
	MonoClass* frame;
	MonoClass* subinfo;
	MonoClass* rxframe;

	int p6any_mo, cursor_from, cursor_pos, cursor_reduced, frame_info,
	    subinfo_name, stable_name, rxframe_from, rxframe_pos, rxframe_name;
};

struct _MonoProfiler {
	MonoObject **ptrs;
	size_t ptrs_allocated;
	size_t ptrs_used;

	struct obj_info *objs;
	size_t objs_allocated;
	size_t objs_used;

	struct root_hash_link** root_hash;
	size_t num_roots;
	size_t root_hash_size;

	size_t total_prob;

	struct per_image *run_img, *comp_img;
};

static void buffer_add(void **bufp, size_t *allocp, size_t *usedp, void *src,
		size_t nadd, size_t quantum) {
	if (*usedp + nadd > *allocp) {
		size_t newalloc = (*usedp + nadd);
		newalloc += newalloc / 2;
		*bufp = realloc(*bufp, newalloc * quantum);
		*allocp = newalloc;
	}
	memcpy(((char*)(*bufp)) + (quantum * *usedp), src, nadd * quantum);
	*usedp += nadd;
}

static int do_heap_shot = 0;

/* For linux compile with:
 * gcc -fPIC -shared -o libmono-profiler-log.so proflog.c utils.c -Wall -g -lz `pkg-config --cflags --libs mono-2`
 * gcc -o mprof-report decode.c utils.c -Wall -g -lz -lrt -lpthread `pkg-config --cflags mono-2`
 *
 * For osx compile with:
 * gcc -m32 -Dmono_free=free shared -o libmono-profiler-log.dylib proflog.c utils.c -Wall -g -lz `pkg-config --cflags mono-2` -undefined suppress -flat_namespace
 * gcc -m32 -o mprof-report decode.c utils.c -Wall -g -lz -lrt -lpthread `pkg-config --cflags mono-2`
 *
 * Install with:
 * sudo cp mprof-report /usr/local/bin
 * sudo cp libmono-profiler-log.so /usr/local/lib
 * sudo ldconfig
 */

#define FIELD(type,offs,obj) (*( (type *) (offs + (char*)(obj)) ))

#define P6ANY_MO(o) FIELD(MonoObject*, pi->p6any_mo, o)
#define STABLE_NAME(o) FIELD(MonoString*, pi->stable_name, o)
#define SUBINFO_NAME(o) FIELD(MonoString*, pi->subinfo_name, o)
#define FRAME_INFO(o) FIELD(MonoObject*, pi->frame_info, o)

#define RXFRAME_POS(o) FIELD(int32_t, pi->rxframe_pos, o)
#define RXFRAME_FROM(o) FIELD(int32_t, pi->rxframe_from, o)
#define RXFRAME_NAME(o) FIELD(MonoString*, pi->rxframe_name, o)

#define CURSOR_POS(o) FIELD(int32_t, pi->cursor_pos, o)
#define CURSOR_FROM(o) FIELD(int32_t, pi->cursor_from, o)
#define CURSOR_REDUCED(o) FIELD(MonoString*, pi->cursor_reduced, o)

static void
print_mono_string (MonoString *ms)
{
	if (ms) {
		char *tmp = mono_string_to_utf8(ms);
		fputs(tmp, stdout);
		mono_free(tmp);
	} else {
		fputs("(null)", stdout);
	}
}

static int
explain_object_image (struct per_image *pi, MonoObject *obj)
{
	MonoClass *cls = mono_object_get_class(obj);

	if (pi->p6any && mono_object_isinst(obj, pi->p6any)) {
		fputs("[p6] :: ", stdout);
		print_mono_string(P6ANY_MO(obj) ? STABLE_NAME(P6ANY_MO(obj)) : NULL);

		if (cls == pi->frame) {
			fputs(" -- ", stdout);
			print_mono_string(FRAME_INFO(obj) ? SUBINFO_NAME(FRAME_INFO(obj)) : NULL);
		}
		else if (cls == pi->cursor) {
			printf(" -- %d-%d, reduced: ", (int)CURSOR_FROM(obj),
				(int)CURSOR_POS(obj));
			print_mono_string(CURSOR_REDUCED(obj));
		}

		putchar('\n');
		return 1;
	}
	else if (cls == pi->rxframe) {
		printf("rx-frame %d-%d, name=", (int)RXFRAME_FROM(obj),
			(int)RXFRAME_POS(obj));
		print_mono_string(RXFRAME_NAME(obj));
		putchar('\n');
		return 1;
	}
	else if (cls == pi->subinfo) {
		fputs("SubInfo: ", stdout);
		print_mono_string(SUBINFO_NAME(obj));
		putchar('\n');
		return 1;
	}
	return 0;
}

static void
explain_object (MonoProfiler *prof, MonoObject *obj)
{
	if (prof->run_img && explain_object_image(prof->run_img, obj))
		return;
	if (prof->comp_img && explain_object_image(prof->comp_img, obj))
		return;

	MonoType *ty = mono_class_get_type(mono_object_get_class(obj));
	const char *tn = mono_type_get_name(ty);
	printf("(clr) %s\n", tn);
	mono_free((void*)tn);
}

static int
gc_reference (MonoObject *obj, MonoClass *klass, uintptr_t size, uintptr_t num, MonoObject **refs, uintptr_t *offsets, void *data)
{
	MonoProfiler *prof = (MonoProfiler *) data;
	if (size == 0) {
		MonoObject *oref = prof->objs[prof->objs_used - 1].addr;
		if (obj != oref) {
			printf("Strange object continuation %p %p\n", (void*)obj, (void*)oref);
			return 0;
		}
		prof->ptrs_used--;
	} else {
		struct obj_info oi;
		oi.addr = obj;
		oi.first_ptr = prof->ptrs_used;
		oi.size = size;
		oi.total_size = 0;
		oi.prev = NULL;
		buffer_add((void**)(&prof->objs), &prof->objs_allocated,
			&prof->objs_used, (void*)(&oi), 1, sizeof(oi));
		//printf("Add info for object %p\n", (void*)obj);
	}
	MonoObject* null = NULL;
	buffer_add((void**)(&prof->ptrs), &prof->ptrs_allocated,
		&prof->ptrs_used, (void*)refs, num, sizeof(MonoObject*));
	buffer_add((void**)(&prof->ptrs), &prof->ptrs_allocated,
		&prof->ptrs_used, (void*)&null, 1, sizeof(MonoObject*));
	return 0;
}

static double hs_mode_s = 0;
static unsigned int hs_mode_gc = 0;
static unsigned int gc_count = 0;
static unsigned int last_gc_gen_started = -1;
static time_t last_hs_time = 0;

static int
obj_compare_addr(const void *a, const void *b)
{
	MonoObject *p1 = ((const struct obj_info*)a)->addr;
	MonoObject *p2 = ((const struct obj_info*)b)->addr;

	return (p1 < p2) ? -1 : (p1 == p2) ? 0 : 1;
}

static struct obj_info*
get_info(MonoProfiler* prof, MonoObject* obj)
{
	size_t left = 0;
	size_t right = prof->objs_used;

	while (right != left) {
		size_t mid = left + (right - left) / 2; /* may coincide with left */
		struct obj_info *minf = &(prof->objs[mid]);
		if (minf->addr == obj)
			return minf;
		if (minf->addr > obj) {
			right = mid;
		} else {
			left = mid + 1;
		}
	}
	//printf("Oops!  No information for object %p\n", obj);
	return NULL;
}

static void
bfs_mark(struct obj_info ***qtail, struct obj_info *item, struct obj_info *from)
{
	if (!item)
		return;
	if (!item->total_size) {
		item->total_size = 1;
		item->prev = from;
		*((*qtail)++) = item;
	}
}

static void
bfs(MonoProfiler *prof)
{
	/* queue holds things that have been marked, but not their children */
	struct obj_info **qbuf = (struct obj_info**)malloc(sizeof(struct obj_info*) * prof->objs_used);
	struct obj_info **qhead = qbuf, **qtail = qbuf;
	size_t ix;
	struct root_hash_link *lk;
	for (ix = 0; ix < prof->root_hash_size; ix++) {
		for (lk = prof->root_hash[ix]; lk; lk = lk->next) {
			bfs_mark(&qtail, get_info(prof, lk->root), &(lk->pseudo_info));
		}
	}

	while (qhead != qtail) {
		struct obj_info *inf = *(qhead++);
		MonoObject** pptr = prof->ptrs + inf->first_ptr;

		while (*pptr) {
			bfs_mark(&qtail, get_info(prof, *(pptr++)), inf);
		}
	}

	printf("BFS done, visited %td objects\n", qtail - qbuf);
	free(qbuf);
}

static void
gen_probs (MonoProfiler *prof)
{
	size_t ix, totbytes = 0;

	for (ix = 0; ix < prof->objs_used; ix++) {
		prof->objs[ix].total_size = totbytes;
		totbytes += prof->objs[ix].size;
	}

	prof->total_prob = totbytes;
	printf("Probability generation done, total %zd bytes\n", totbytes);
}

static void
sample (MonoProfiler *prof)
{
	size_t byteix;
	size_t max = prof->total_prob;
	do {
		byteix = rand() / (RAND_MAX / max);
	} while (byteix >= max);

	size_t ixl = 0;
	size_t ixr = prof->objs_used;
	while (ixr - ixl > 1) {
		size_t ixm = ixl + (ixr - ixl) / 2;
		if (byteix >= prof->objs[ixm].total_size) {
			ixl = ixm;
		} else {
			ixr = ixm;
		}
	}

	struct obj_info *obj = &(prof->objs[ixl]);

	printf("Byte %zd of %zd, object %zd of %zd, size %zd\n",
		byteix, max, ixl, prof->objs_used, obj->size);
	while(1) {
		if (!obj) {
			printf("[Reference set unknown]\n\n");
			return;
		}
		if (obj->size == -1) {
			int flags = (int)obj->total_size;
			const char *pin = (flags & MONO_PROFILE_GC_ROOT_PINNING) ? ", pinned" : "";
			const char *weak = (flags & MONO_PROFILE_GC_ROOT_WEAKREF) ? ", weak" : "";
			const char *interior = (flags & MONO_PROFILE_GC_ROOT_INTERIOR) ? ", interior" : "";
			const char *type = "(unknown)";
			switch (flags & MONO_PROFILE_GC_ROOT_TYPEMASK) {
				case MONO_PROFILE_GC_ROOT_STACK: type = "stack"; break;
				case MONO_PROFILE_GC_ROOT_FINALIZER: type = "finalizer"; break;
				case MONO_PROFILE_GC_ROOT_HANDLE: type = "handle"; break;
				case MONO_PROFILE_GC_ROOT_OTHER: type = "other"; break;
				case MONO_PROFILE_GC_ROOT_MISC: type = "misc"; break;
			}
			printf("[Root object: %s%s%s%s]\n\n", type, pin, weak, interior);
			return;
		}
		printf("%p  ", obj->addr);
		explain_object(prof, obj->addr);
		obj = obj->prev;
	}
}

static struct per_image*
get_image (const char *name)
{
	MonoImage* img = mono_image_loaded(name);
	if (!img) {
		printf("%s: No such image\n", name);
		return NULL;
	}

	struct per_image *pi = (struct per_image *)malloc(sizeof(struct per_image));

	pi->image = img;
	pi->p6any = mono_class_from_name(pi->image, "Niecza", "P6any");
	pi->frame = mono_class_from_name(pi->image, "Niecza", "Frame");
	pi->stable = mono_class_from_name(pi->image, "Niecza", "STable");
	pi->subinfo = mono_class_from_name(pi->image, "Niecza", "SubInfo");
	pi->cursor = mono_class_from_name(pi->image, "", "Cursor");
	pi->rxframe = mono_class_from_name(pi->image, "", "RxFrame");

	printf("%s: img=%p p6any=%p frame=%p subinfo=%p cursor=%p rxframe=%p\n",
		name, pi->image, pi->p6any, pi->frame, pi->subinfo, pi->cursor,
		pi->rxframe);

	pi->subinfo_name = mono_field_get_offset(mono_class_get_field_from_name(pi->subinfo, "name"));
	pi->stable_name = mono_field_get_offset(mono_class_get_field_from_name(pi->stable, "name"));
	pi->cursor_pos = mono_field_get_offset(mono_class_get_field_from_name(pi->cursor, "pos"));
	pi->cursor_from = mono_field_get_offset(mono_class_get_field_from_name(pi->cursor, "from"));
	pi->cursor_reduced = mono_field_get_offset(mono_class_get_field_from_name(pi->cursor, "reduced"));
	pi->frame_info = mono_field_get_offset(mono_class_get_field_from_name(pi->frame, "info"));
	pi->p6any_mo = mono_field_get_offset(mono_class_get_field_from_name(pi->p6any, "mo"));
	pi->rxframe_name = mono_field_get_offset(mono_class_get_field_from_name(pi->rxframe, "name"));
	pi->rxframe_from = mono_field_get_offset(mono_class_get_field_from_name(pi->rxframe, "from"));

	MonoClassField *st = mono_class_get_field_from_name(pi->rxframe, "st");
	MonoClass *state = mono_type_get_class(mono_field_get_type(st));
	int st_pos = mono_field_get_offset(mono_class_get_field_from_name(state, "pos")) - sizeof(MonoObject);
	printf("st.type.pos-offset = %d\n", st_pos);

	pi->rxframe_pos = mono_field_get_offset(mono_class_get_field_from_name(pi->rxframe, "st")) + st_pos;

	return pi;
}

static void
heap_walk (MonoProfiler *prof)
{
	int do_walk = 0;
	if (!do_heap_shot)
		return;
	if (hs_mode_s && (clock() - last_hs_time) >= (clock_t)(hs_mode_s * CLOCKS_PER_SEC))
		do_walk = 1;
	else if (hs_mode_gc && (gc_count % hs_mode_gc) == 0)
		do_walk = 1;
	else if (!hs_mode_s && !hs_mode_gc && last_gc_gen_started == mono_gc_max_generation ())
		do_walk = 1;

	if (!do_walk)
		return;

	printf("Heap shot started... %zd roots\n", prof->num_roots);
	prof->comp_img = get_image("Kernel");
	prof->run_img = get_image("Run.Kernel");

	mono_gc_walk_heap (0, gc_reference, prof);
	printf("Heap walk complete: %zd objects %zd pointers.\n", prof->objs_used, prof->ptrs_used);
	/* to allow effective access, sort the object set */
	qsort(prof->objs, prof->objs_used, sizeof(struct obj_info),
		obj_compare_addr);
	bfs(prof);
	gen_probs(prof);
	int ix;
	for (ix = 0; ix < prof->objs_used / 1000; ix++)
		sample(prof);

	free(prof->ptrs);
	free(prof->objs);
	free(prof->comp_img);
	free(prof->run_img);
	prof->ptrs_allocated = prof->ptrs_used = prof->objs_allocated =
		prof->objs_used = 0;
	prof->ptrs = NULL;
	prof->objs = NULL;
	last_hs_time = clock();
}

static void
gc_event (MonoProfiler *prof, MonoGCEvent ev, int generation) {
	/* to deal with nested gen1 after gen0 started */
	if (ev == MONO_GC_EVENT_START) {
		last_gc_gen_started = generation;
		if (generation == 0) {
			/* entering GC - clear out the old roots */
			struct root_hash_link *l, *ln;
			size_t ix;
			for (ix = 0; ix < prof->root_hash_size; ix++) {
				l = prof->root_hash[ix];
				while (l != NULL) {
					ln = l->next;
					free(l);
					l = ln;
				}
			}
			free(prof->root_hash);

			prof->root_hash = NULL;
			prof->root_hash_size = prof->num_roots = 0;
		}
		if (generation == mono_gc_max_generation ())
			gc_count++;
	}
	if (ev == MONO_GC_EVENT_PRE_START_WORLD)
		heap_walk (prof);
}

static void
gc_handle (MonoProfiler *prof, int op, int type, uintptr_t handle, MonoObject *obj) {
}

#define HASH_ROOT(prof, ptr) (((size_t)(((uintptr_t) ptr) * 0x9E3779B9UL)) & (prof->root_hash_size - 1))

static void
add_root(MonoProfiler* prof, MonoObject* root, size_t info)
{
	if (prof->num_roots == prof->root_hash_size) {
		size_t ohsz = prof->root_hash_size;
		size_t ix;
		struct root_hash_link *lp, *nlp;
		struct root_hash_link **ohash = prof->root_hash;
		prof->root_hash_size = ohsz == 0 ? 512 :
			2 * prof->root_hash_size;

		prof->root_hash = (struct root_hash_link **)calloc(
			prof->root_hash_size, sizeof(struct root_hash_link *));
		prof->num_roots = 0;

		for (ix = 0; ix < ohsz; ix++) {
			lp = ohash[ix];
			while (lp) {
				nlp = lp->next;
				add_root(prof, lp->root, lp->pseudo_info.total_size);
				free(lp);
				lp = nlp;
			}
		}
		free(ohash);
	}

	size_t ix = HASH_ROOT(prof, root);
	struct root_hash_link *l = (struct root_hash_link *)malloc(sizeof(struct root_hash_link));
	l->root = root;
	l->next = prof->root_hash[ix];
	l->pseudo_info.total_size = info;
	l->pseudo_info.size = -1;
	prof->root_hash[ix] = l;
	prof->num_roots++;
	//printf("Added root %p\n", root);
}

static void
move_root(MonoProfiler* prof, MonoObject* from, MonoObject* to)
{
	int oix = HASH_ROOT(prof, from);
	struct root_hash_link **chainp = &prof->root_hash[oix];

	while (1) {
		if (!(*chainp))
			return;
		if ((*chainp)->root == from)
			break;
		chainp = &((*chainp)->next);
	}

	int nix = HASH_ROOT(prof, to);
	struct root_hash_link *link = *chainp;
	*chainp = (*chainp)->next;
	link->next = prof->root_hash[nix];
	link->root = to;
	prof->root_hash[nix] = link;
	//printf("Moved root %p to %p\n", from, to);
}

static void
gc_roots (MonoProfiler *prof, int num, void **objects, int *root_types, uintptr_t *extra_info)
{
	int i;
	for (i = 0; i < num; ++i) {
		add_root(prof, (MonoObject*)objects[i], (size_t)root_types[i]);
	}
}

static void
gc_moves (MonoProfiler *prof, void **objects, int num)
{
	int i;
	for (i = 0; i < num; i += 2) {
		move_root(prof, (MonoObject*)objects[i], (MonoObject*)objects[i+1]);
	}
}

/* 
 * declaration to silence the compiler: this is the entry point that
 * mono will load from the shared library and call.
 */
extern void
mono_profiler_startup (const char *desc);

static void
log_shutdown (MonoProfiler *prof)
{
	fflush(stdout);
	free(prof);
}

static void
gc_resize (MonoProfiler *profiler, int64_t new_size) {
}

void
mono_profiler_startup (const char *desc)
{
	int events = MONO_PROFILE_GC|MONO_PROFILE_GC_MOVES|
	    MONO_PROFILE_GC_ROOTS;

	do_heap_shot = 1;
	hs_mode_s = 3.0;

	MonoProfiler* prof = (MonoProfiler*)calloc(1, sizeof(MonoProfiler));
	mono_profiler_install (prof, log_shutdown);
	mono_profiler_install_gc (gc_event, gc_resize);
	mono_profiler_install_gc_moves (gc_moves);
	mono_profiler_install_gc_roots (gc_handle, gc_roots);

	mono_profiler_set_events (events);
}

