/*
 * evictsim -- offline replay of PostgreSQL shared-buffer access traces.
 *
 * Traces are written by a server built from this branch when
 * buffer_trace_directory is set: one file per backend, 24-byte records
 * ordered by a global sequence number (see BufferTraceAccess() in
 * src/backend/storage/buffer/freelist.c).
 *
 *   evictsim merge  OUT.bin  IN1.bin [IN2.bin ...]   merge per-backend files by seq
 *   evictsim stats  TRACE.bin                         footprint, one-hit-wonders, PG hit ratio
 *   evictsim sim    TRACE.bin POLICY CACHE_PAGES      replay one policy
 *   evictsim sweep  TRACE.bin CACHE_PAGES[,..]        all policies x cache sizes, CSV
 *   evictsim oracle TRACE.bin OUT.oracleGeneral       libCacheSim oracleGeneral format
 *   evictsim filter TRACE.bin OUT.bin                 drop accesses made through a ring
 *                                                     (BufferAccessStrategy), which PG keeps
 *                                                     out of the shared replacement policy
 *
 * Policies: lru, opt (Belady MIN), clock (PG clock-sweep, max 5), srrip,
 * brrip, sieve, s3fifo.  clock/srrip/sieve/s3fifo mirror the in-server
 * implementations step by step (same initial state, same hand movement), so a
 * single-backend trace replayed at the server's shared_buffers must give
 * (nearly) the same hit count the server recorded -- that is the
 * differential correctness test.  The only legitimate differences come from
 * buffers that are pinned at eviction time, which the simulator cannot see.
 *
 * Build: cc -O2 -o evictsim evictsim.c
 */
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct
{
	uint64_t	seq;
	uint32_t	db;
	uint32_t	rel;
	uint32_t	block;
	uint8_t		fork;
	uint8_t		flags;
	uint16_t	pad;
} Rec;

_Static_assert(sizeof(Rec) == 24, "record size");

#define F_HIT		0x01
#define F_EXTEND	0x02
#define F_STRATEGY	0x04

static void *
xmalloc(size_t n)
{
	void	   *p = malloc(n ? n : 1);

	if (!p)
	{
		fprintf(stderr, "out of memory (%zu bytes)\n", n);
		exit(1);
	}
	return p;
}

static Rec *
load(const char *path, size_t *n)
{
	FILE	   *f = fopen(path, "rb");
	long		sz;
	Rec		   *r;

	if (!f)
	{
		perror(path);
		exit(1);
	}
	fseek(f, 0, SEEK_END);
	sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	*n = (size_t) sz / sizeof(Rec);
	r = xmalloc(*n * sizeof(Rec));
	if (fread(r, sizeof(Rec), *n, f) != *n)
	{
		fprintf(stderr, "short read on %s\n", path);
		exit(1);
	}
	fclose(f);
	return r;
}

static int
cmp_seq(const void *a, const void *b)
{
	uint64_t	x = ((const Rec *) a)->seq,
				y = ((const Rec *) b)->seq;

	return x < y ? -1 : x > y;
}

/* ---------- dense object ids ---------- */

static uint32_t *obj;			/* obj[i] = dense id of access i */
static uint32_t nobj;
static size_t nacc;
static uint8_t *accflags;

static inline uint64_t
mix(uint64_t x)
{
	x ^= x >> 33;
	x *= 0xff51afd7ed558ccdULL;
	x ^= x >> 33;
	x *= 0xc4ceb9fe1a85ec53ULL;
	x ^= x >> 33;
	return x;
}

static void
build_ids(Rec *r, size_t n)
{
	size_t		cap = 16;
	uint64_t   *k1,
			   *k2;
	uint32_t   *val;

	while (cap < 2 * n)
		cap <<= 1;
	k1 = xmalloc(cap * 8);
	k2 = xmalloc(cap * 8);
	val = xmalloc(cap * 4);
	memset(val, 0xff, cap * 4);
	obj = xmalloc(n * 4);
	accflags = xmalloc(n);
	nobj = 0;
	nacc = n;
	for (size_t i = 0; i < n; i++)
	{
		uint64_t	a = ((uint64_t) r[i].db << 32) | r[i].rel;
		uint64_t	b = ((uint64_t) r[i].fork << 32) | r[i].block;
		size_t		h = mix(a * 31 + b) & (cap - 1);

		while (val[h] != UINT32_MAX && !(k1[h] == a && k2[h] == b))
			h = (h + 1) & (cap - 1);
		if (val[h] == UINT32_MAX)
		{
			k1[h] = a;
			k2[h] = b;
			val[h] = nobj++;
		}
		obj[i] = val[h];
		accflags[i] = r[i].flags;
	}
	free(k1);
	free(k2);
	free(val);
}

/* ---------- doubly linked queues over cache slots ---------- */

typedef struct
{
	int			head,
				tail,
				count;
} List;

static int *older,
		   *newer,
		   *queue;
static List lists[2];

static void
lremove(int b)
{
	List	   *l = &lists[queue[b]];

	if (older[b] >= 0)
		newer[older[b]] = newer[b];
	else
		l->tail = newer[b];
	if (newer[b] >= 0)
		older[newer[b]] = older[b];
	else
		l->head = older[b];
	older[b] = newer[b] = -1;
	l->count--;
}

static void
lpush(int q, int b)
{
	List	   *l = &lists[q];

	queue[b] = q;
	newer[b] = -1;
	older[b] = l->head;
	if (l->head >= 0)
		newer[l->head] = b;
	else
		l->tail = b;
	l->head = b;
	l->count++;
}

static void
lmove(int q, int b)
{
	lremove(b);
	lpush(q, b);
}

static void
lists_init(int C, int q)
{
	older = xmalloc(C * sizeof(int));
	newer = xmalloc(C * sizeof(int));
	queue = xmalloc(C * sizeof(int));
	for (int i = 0; i < 2; i++)
		lists[i].head = lists[i].tail = -1, lists[i].count = 0;
	/* same initial order as StrategyCtlShmemInit(): slot 0 ends at the tail */
	for (int i = 0; i < C; i++)
		lpush(q, i);
}

static void
lists_free(void)
{
	free(older);
	free(newer);
	free(queue);
}

/* ---------- policies ---------- */

typedef struct
{
	uint64_t	hits;
	uint64_t	checks;			/* slots examined to find victims */
	uint64_t	misses;
} Result;

static uint64_t rng = 0x9e3779b97f4a7c15ULL;
static inline uint32_t
xrand(void)
{
	rng ^= rng << 13;
	rng ^= rng >> 7;
	rng ^= rng << 17;
	return (uint32_t) rng;
}

/* clock family: PG clock-sweep (max 5, +1 per hit, insert 1) and RRIP */
static Result
sim_clock(int C, int maxc, bool hit_to_max, int insert_mode)
{
	Result		res = {0};
	int		   *slot_obj = xmalloc(C * sizeof(int));
	int		   *where = xmalloc(nobj * sizeof(int));
	uint8_t    *cnt = calloc(C, 1);
	int			hand = 0;

	memset(slot_obj, 0xff, C * sizeof(int));
	memset(where, 0xff, nobj * sizeof(int));
	for (size_t i = 0; i < nacc; i++)
	{
		int			o = obj[i];
		int			s = where[o];

		if (s >= 0)
		{
			res.hits++;
			if (cnt[s] < maxc)
				cnt[s] = hit_to_max ? maxc : cnt[s] + 1;
			continue;
		}
		res.misses++;
		for (;;)
		{
			s = hand;
			hand = (hand + 1) % C;
			res.checks++;
			if (slot_obj[s] >= 0 && cnt[s] > 0)
			{
				cnt[s]--;
				continue;
			}
			break;
		}
		if (slot_obj[s] >= 0)
			where[slot_obj[s]] = -1;
		slot_obj[s] = o;
		where[o] = s;
		if (insert_mode == 0)
			cnt[s] = 1;
		else					/* BRRIP */
			cnt[s] = (xrand() % 32 == 0) ? 1 : 0;
	}
	free(slot_obj);
	free(where);
	free(cnt);
	return res;
}

static Result
sim_sieve(int C)
{
	Result		res = {0};
	int		   *slot_obj = xmalloc(C * sizeof(int));
	int		   *where = xmalloc(nobj * sizeof(int));
	uint8_t    *visited = calloc(C, 1);
	int			hand = -1;

	memset(slot_obj, 0xff, C * sizeof(int));
	memset(where, 0xff, nobj * sizeof(int));
	lists_init(C, 0);
	for (size_t i = 0; i < nacc; i++)
	{
		int			o = obj[i];
		int			s = where[o];
		int			b;

		if (s >= 0)
		{
			res.hits++;
			visited[s] = 1;
			continue;
		}
		res.misses++;
		for (;;)
		{
			b = hand < 0 ? lists[0].tail : hand;
			res.checks++;
			hand = newer[b];
			if (slot_obj[b] >= 0 && visited[b])
			{
				visited[b] = 0;
				continue;
			}
			break;
		}
		lmove(0, b);
		if (slot_obj[b] >= 0)
			where[slot_obj[b]] = -1;
		slot_obj[b] = o;
		where[o] = b;
		visited[b] = 0;
	}
	lists_free();
	free(slot_obj);
	free(where);
	free(visited);
	return res;
}

static Result
sim_s3fifo(int C, uint64_t *promotions, uint64_t *ghost_hits)
{
	Result		res = {0};
	int		   *slot_obj = xmalloc(C * sizeof(int));
	int		   *where = xmalloc(nobj * sizeof(int));
	uint8_t    *freq = calloc(C, 1);
	int			target = C / 10 > 1 ? C / 10 : 1;
	int			gcap = C - target > 1 ? C - target : 1;
	int		   *gring = xmalloc(gcap * sizeof(int));
	int64_t    *gpos = xmalloc(nobj * sizeof(int64_t));
	uint64_t	gnext = 0;

	*promotions = *ghost_hits = 0;
	memset(slot_obj, 0xff, C * sizeof(int));
	memset(where, 0xff, nobj * sizeof(int));
	memset(gpos, 0xff, nobj * sizeof(int64_t));
	lists_init(C, 1);			/* everything starts in M */
	for (size_t i = 0; i < nacc; i++)
	{
		int			o = obj[i];
		int			s = where[o];
		int			b,
					q,
					want;

		if (s >= 0)
		{
			res.hits++;
			if (freq[s] < 3)
				freq[s]++;
			continue;
		}
		res.misses++;
		for (;;)
		{
			bool		from_small = lists[0].count > target || lists[1].count == 0;

			q = from_small ? 0 : 1;
			b = lists[q].tail;
			res.checks++;
			if (slot_obj[b] >= 0 && freq[b] >= 1)
			{
				if (!from_small)
					freq[b]--;
				else
					(*promotions)++;
				lmove(1, b);
				continue;
			}
			break;
		}
		if (q == 0 && slot_obj[b] >= 0)
		{
			/* ghost insert of the evicted object */
			uint64_t	pos = gnext++;
			int			gs = (int) (pos % gcap);

			if (pos >= (uint64_t) gcap && gpos[gring[gs]] == (int64_t) (pos - gcap))
				gpos[gring[gs]] = -1;
			gring[gs] = slot_obj[b];
			gpos[slot_obj[b]] = (int64_t) pos;
		}
		lmove(q, b);
		if (slot_obj[b] >= 0)
			where[slot_obj[b]] = -1;
		slot_obj[b] = o;
		where[o] = b;
		freq[b] = 0;
		/* StrategyBufferInserted() */
		if (gpos[o] >= 0)
		{
			gpos[o] = -1;
			want = 1;
			(*ghost_hits)++;
		}
		else
			want = 0;
		if (queue[b] != want)
			lmove(want, b);
	}
	lists_free();
	free(slot_obj);
	free(where);
	free(freq);
	free(gring);
	free(gpos);
	return res;
}

static Result
sim_lru(int C)
{
	Result		res = {0};
	int		   *slot_obj = xmalloc(C * sizeof(int));
	int		   *where = xmalloc(nobj * sizeof(int));

	memset(slot_obj, 0xff, C * sizeof(int));
	memset(where, 0xff, nobj * sizeof(int));
	lists_init(C, 0);
	for (size_t i = 0; i < nacc; i++)
	{
		int			o = obj[i];
		int			s = where[o];

		if (s >= 0)
		{
			res.hits++;
			lmove(0, s);
			continue;
		}
		res.misses++;
		s = lists[0].tail;
		if (slot_obj[s] >= 0)
			where[slot_obj[s]] = -1;
		slot_obj[s] = o;
		where[o] = s;
		lmove(0, s);
	}
	lists_free();
	free(slot_obj);
	free(where);
	return res;
}

/* Belady MIN with a lazy max-heap keyed by next use */
typedef struct
{
	uint64_t	next;
	uint32_t	o;
} HeapEnt;

static Result
sim_opt(int C)
{
	Result		res = {0};
	uint64_t   *nextuse = xmalloc(nacc * sizeof(uint64_t));
	uint64_t   *last = xmalloc(nobj * sizeof(uint64_t));
	uint64_t   *cur = xmalloc(nobj * sizeof(uint64_t));
	bool	   *cached = calloc(nobj, 1);
	HeapEnt    *heap = xmalloc((nacc + 1) * sizeof(HeapEnt));
	size_t		hn = 0;
	int			size = 0;

	for (uint32_t o = 0; o < nobj; o++)
		last[o] = UINT64_MAX;
	for (size_t i = nacc; i-- > 0;)
	{
		nextuse[i] = last[obj[i]];
		last[obj[i]] = i;
	}

#define HPUSH(e) do { size_t k_ = hn++; heap[k_] = (e); \
		while (k_ > 0 && heap[(k_-1)/2].next < heap[k_].next) { \
			HeapEnt t_ = heap[k_]; heap[k_] = heap[(k_-1)/2]; heap[(k_-1)/2] = t_; k_ = (k_-1)/2; } } while (0)

	for (size_t i = 0; i < nacc; i++)
	{
		uint32_t	o = obj[i];

		if (cached[o])
			res.hits++;
		else
		{
			res.misses++;
			if (size == C)
			{
				/* pop until a live entry */
				for (;;)
				{
					HeapEnt		top = heap[0];
					size_t		k = 0;

					heap[0] = heap[--hn];
					for (;;)
					{
						size_t		l = 2 * k + 1,
									r = l + 1,
									m = k;

						if (l < hn && heap[l].next > heap[m].next)
							m = l;
						if (r < hn && heap[r].next > heap[m].next)
							m = r;
						if (m == k)
							break;
						HeapEnt		t = heap[k];

						heap[k] = heap[m];
						heap[m] = t;
						k = m;
					}
					if (cached[top.o] && cur[top.o] == top.next)
					{
						cached[top.o] = false;
						size--;
						break;
					}
				}
			}
			cached[o] = true;
			size++;
		}
		cur[o] = nextuse[i];
		HPUSH(((HeapEnt) {nextuse[i], o}));
	}
	free(nextuse);
	free(last);
	free(cur);
	free(cached);
	free(heap);
	return res;
}

static Result
run_policy(const char *p, int C, uint64_t *x1, uint64_t *x2)
{
	*x1 = *x2 = 0;
	if (!strcmp(p, "lru"))
		return sim_lru(C);
	if (!strcmp(p, "opt"))
		return sim_opt(C);
	if (!strcmp(p, "clock"))
		return sim_clock(C, 5, false, 0);
	if (!strcmp(p, "srrip"))
		return sim_clock(C, 3, true, 0);
	if (!strcmp(p, "brrip"))
		return sim_clock(C, 3, true, 1);
	if (!strcmp(p, "sieve"))
		return sim_sieve(C);
	if (!strcmp(p, "s3fifo"))
		return sim_s3fifo(C, x1, x2);
	fprintf(stderr, "unknown policy %s\n", p);
	exit(1);
}

static uint64_t
pg_hits(void)
{
	uint64_t	h = 0;

	for (size_t i = 0; i < nacc; i++)
		h += (accflags[i] & F_HIT) != 0;
	return h;
}

int
main(int argc, char **argv)
{
	if (argc >= 4 && !strcmp(argv[1], "merge"))
	{
		size_t		total = 0,
					n;
		Rec		   *all = NULL;
		FILE	   *f;

		for (int i = 3; i < argc; i++)
		{
			Rec		   *r = load(argv[i], &n);

			all = realloc(all, (total + n) * sizeof(Rec));
			memcpy(all + total, r, n * sizeof(Rec));
			total += n;
			free(r);
		}
		qsort(all, total, sizeof(Rec), cmp_seq);
		f = fopen(argv[2], "wb");
		fwrite(all, sizeof(Rec), total, f);
		fclose(f);
		printf("merged %zu records from %d files\n", total, argc - 3);
		return 0;
	}
	if (argc >= 4 && !strcmp(argv[1], "filter"))
	{
		size_t		n,
					kept = 0;
		Rec		   *r = load(argv[2], &n);
		FILE	   *f = fopen(argv[3], "wb");

		for (size_t i = 0; i < n; i++)
			if (!(r[i].flags & F_STRATEGY))
			{
				fwrite(&r[i], sizeof(Rec), 1, f);
				kept++;
			}
		fclose(f);
		printf("kept %zu of %zu records (dropped %zu ring accesses)\n", kept, n, n - kept);
		return 0;
	}
	if (argc >= 3 && !strcmp(argv[1], "stats"))
	{
		size_t		n;
		Rec		   *r = load(argv[2], &n);
		uint32_t   *cnt;
		uint64_t	once = 0,
					strat = 0,
					ext = 0;

		build_ids(r, n);
		cnt = calloc(nobj, 4);
		for (size_t i = 0; i < n; i++)
		{
			cnt[obj[i]]++;
			strat += (r[i].flags & F_STRATEGY) != 0;
			ext += (r[i].flags & F_EXTEND) != 0;
		}
		for (uint32_t o = 0; o < nobj; o++)
			once += cnt[o] == 1;
		printf("accesses=%zu unique_pages=%u footprint_mb=%.1f one_hit_pages=%.3f "
			   "pg_hit_ratio=%.4f strategy_frac=%.4f extend_frac=%.4f\n",
			   n, nobj, nobj * 8192.0 / 1048576, (double) once / nobj,
			   (double) pg_hits() / n, (double) strat / n, (double) ext / n);
		return 0;
	}
	if (argc >= 5 && !strcmp(argv[1], "sim"))
	{
		size_t		n;
		Rec		   *r = load(argv[2], &n);
		uint64_t	x1,
					x2;
		Result		res;

		build_ids(r, n);
		free(r);
		res = run_policy(argv[3], atoi(argv[4]), &x1, &x2);
		printf("policy=%s cache=%s accesses=%zu hits=%" PRIu64 " hit_ratio=%.5f "
			   "checks_per_miss=%.3f pg_hits=%" PRIu64 " pg_hit_ratio=%.5f "
			   "s3_promotions=%" PRIu64 " s3_ghost_hits=%" PRIu64 "\n",
			   argv[3], argv[4], nacc, res.hits, (double) res.hits / nacc,
			   res.misses ? (double) res.checks / res.misses : 0.0,
			   pg_hits(), (double) pg_hits() / nacc, x1, x2);
		return 0;
	}
	if (argc >= 4 && !strcmp(argv[1], "sweep"))
	{
		size_t		n;
		Rec		   *r = load(argv[2], &n);
		const char *pols[] = {"opt", "lru", "clock", "srrip", "brrip", "sieve", "s3fifo"};
		char	   *sizes = strdup(argv[3]);

		build_ids(r, n);
		free(r);
		printf("cache_pages,policy,accesses,hits,hit_ratio,miss_ratio,checks_per_miss\n");
		for (char *tok = strtok(sizes, ","); tok; tok = strtok(NULL, ","))
			for (size_t k = 0; k < sizeof(pols) / sizeof(pols[0]); k++)
			{
				uint64_t	x1,
							x2;
				Result		res = run_policy(pols[k], atoi(tok), &x1, &x2);

				printf("%s,%s,%zu,%" PRIu64 ",%.6f,%.6f,%.3f\n", tok, pols[k], nacc,
					   res.hits, (double) res.hits / nacc, 1.0 - (double) res.hits / nacc,
					   res.misses ? (double) res.checks / res.misses : 0.0);
				fflush(stdout);
			}
		return 0;
	}
	if (argc >= 4 && !strcmp(argv[1], "oracle"))
	{
		/* libCacheSim oracleGeneral: <u32 time, u64 id, u32 size, i64 next vtime> */
		size_t		n;
		Rec		   *r = load(argv[2], &n);
		int64_t    *nextv;
		int64_t    *last;
		FILE	   *f;

		build_ids(r, n);
		free(r);
		nextv = xmalloc(nacc * 8);
		last = xmalloc((size_t) nobj * 8);
		for (uint32_t o = 0; o < nobj; o++)
			last[o] = -1;
		for (size_t i = nacc; i-- > 0;)
		{
			nextv[i] = last[obj[i]];
			last[obj[i]] = (int64_t) i;
		}
		f = fopen(argv[3], "wb");
		for (size_t i = 0; i < nacc; i++)
		{
			uint32_t	t = (uint32_t) (i / 1000 + 1);
			uint64_t	id = (uint64_t) obj[i] + 1;
			uint32_t	sz = 8192;

			fwrite(&t, 4, 1, f);
			fwrite(&id, 8, 1, f);
			fwrite(&sz, 4, 1, f);
			fwrite(&nextv[i], 8, 1, f);
		}
		fclose(f);
		printf("wrote %zu requests, %u objects\n", nacc, nobj);
		return 0;
	}
	fprintf(stderr, "usage: see header comment\n");
	return 2;
}
