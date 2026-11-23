/*-------------------------------------------------------------------------
 *
 * freelist.c
 *	  routines for managing the buffer pool's replacement strategy.
 *
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  src/backend/storage/buffer/freelist.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "pgstat.h"
#include "port/atomics.h"
#include "storage/buf_internals.h"
#include "storage/bufmgr.h"
#include "storage/proc.h"
#include "storage/shmem.h"
#include "storage/subsystems.h"
#include "common/pg_prng.h"
#include "access/htup_details.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "storage/ipc.h"
#include "storage/lwlock.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/guc_hooks.h"
#include "utils/hsearch.h"

#define INT_ACCESS_ONCE(var)	((int)(*((volatile int *)&(var))))


/*
 * Doubly linked FIFO of buffer ids used by the queue-based policies.  "head"
 * is the most recently inserted buffer, "tail" the oldest.
 */
typedef struct PolicyList
{
	int			head;
	int			tail;
	int			count;
} PolicyList;

typedef struct PolicyNode
{
	int			older;			/* towards tail, -1 at the tail */
	int			newer;			/* towards head, -1 at the head */
	int			queue;			/* index into StrategyControl->lists */
} PolicyNode;

#define S3_SMALL	0
#define S3_MAIN		1

/*
 * S3-FIFO moves a buffer from the small to the main queue when it was
 * re-referenced at least this many times while in the small queue.
 */
#define S3FIFO_MOVE_THRESHOLD	1

/* DRRIP: 1/32 of the pages lead for SRRIP, 1/32 for BRRIP */
#define DRRIP_GROUPS		32
#define DRRIP_PSEL_MAX		1023

/* BRRIP inserts with a "long" prediction once every this many misses */
#define BRRIP_EPSILON		32

typedef struct GhostEntry
{
	BufferTag	tag;			/* hash key */
	uint64		pos;			/* ring position of the latest insertion */
} GhostEntry;

/*
 * The shared freelist control information.
 */
typedef struct
{
	/* Spinlock: protects the values below */
	slock_t		buffer_strategy_lock;

	/*
	 * clock-sweep hand: index of next buffer to consider grabbing. Note that
	 * this isn't a concrete buffer - we only ever increase the value. So, to
	 * get an actual buffer, it needs to be used modulo NBuffers.
	 */
	pg_atomic_uint32 nextVictimBuffer;

	/*
	 * Statistics.  These counters should be wide enough that they can't
	 * overflow during a single bgwriter cycle.
	 */
	uint32		completePasses; /* Complete cycles of the clock-sweep */
	pg_atomic_uint32 numBufferAllocs;	/* Buffers allocated since last reset */

	/*
	 * Bgworker process to be notified upon activity or -1 if none. See
	 * StrategyNotifyBgWriter.
	 */
	int			bgwprocno;

	/*
	 * State for the alternative replacement policies.  Everything below that
	 * is not atomic is protected by BufferEvictionPolicyLock.
	 */
	PolicyList	lists[2];		/* SIEVE uses lists[0]; S3-FIFO uses both */
	int			sieve_hand;		/* SIEVE hand, -1 means "start at tail" */
	int			s3_small_target;	/* S3-FIFO: target size of the small queue */
	int			ghost_capacity; /* S3-FIFO: entries in the ghost FIFO */
	uint64		ghost_next;		/* S3-FIFO: insert position in ghost ring */
	pg_atomic_uint32 drrip_psel;	/* DRRIP policy selector, 0..1023 */

	/* statistics, see pg_buffer_eviction_stats() */
	pg_atomic_uint64 stat_allocs;	/* victims chosen by the policy */
	pg_atomic_uint64 stat_checks;	/* buffers examined to find them */
	pg_atomic_uint64 stat_small_to_main;	/* S3-FIFO S -> M promotions */
	pg_atomic_uint64 stat_ghost_inserts;
	pg_atomic_uint64 stat_ghost_hits;

	/* global sequence number for buffer access tracing */
	pg_atomic_uint64 trace_seq;
} BufferStrategyControl;

/* Pointers to shared state */
static BufferStrategyControl *StrategyControl = NULL;
static PolicyNode *PolicyNodes = NULL;	/* NBuffers entries, SIEVE/S3-FIFO */
static BufferTag *GhostRing = NULL; /* S3-FIFO ghost FIFO */
static HTAB *GhostHash = NULL;	/* S3-FIFO ghost membership */

/* GUC variables */
int			buffer_eviction_policy = BUFFER_EVICTION_CLOCK;
char	   *buffer_trace_directory = NULL;

/* derived from buffer_eviction_policy by assign_buffer_eviction_policy() */
int			BufferMaxUsageCount = BM_MAX_USAGE_COUNT;
bool		BufferHitToMax = false;

const struct config_enum_entry buffer_eviction_policy_options[] = {
	{"clock", BUFFER_EVICTION_CLOCK, false},
	{"srrip", BUFFER_EVICTION_SRRIP, false},
	{"brrip", BUFFER_EVICTION_BRRIP, false},
	{"drrip", BUFFER_EVICTION_DRRIP, false},
	{"sieve", BUFFER_EVICTION_SIEVE, false},
	{"s3fifo", BUFFER_EVICTION_S3FIFO, false},
	{NULL, 0, false}
};

#define POLICY_USES_QUEUES(p) \
	((p) == BUFFER_EVICTION_SIEVE || (p) == BUFFER_EVICTION_S3FIFO)

/* Result of examining one prospective victim, see CheckVictim() */
typedef enum VictimCheck
{
	VICTIM_BUSY,				/* pinned, cannot be used */
	VICTIM_KEEP,				/* recently used, keep it (usage maybe aged) */
	VICTIM_TAKEN,				/* pinned by us, caller owns it */
} VictimCheck;

static BufferDesc *ClockSweepGetVictim(uint64 *buf_state);
static BufferDesc *SieveGetVictim(uint64 *buf_state);
static BufferDesc *S3FifoGetVictim(uint64 *buf_state);

static void StrategyCtlShmemRequest(void *arg);
static void StrategyCtlShmemInit(void *arg);

const ShmemCallbacks StrategyCtlShmemCallbacks = {
	.request_fn = StrategyCtlShmemRequest,
	.init_fn = StrategyCtlShmemInit,
};

/*
 * Private (non-shared) state for managing a ring of shared buffers to re-use.
 * This is currently the only kind of BufferAccessStrategy object, but someday
 * we might have more kinds.
 */
typedef struct BufferAccessStrategyData
{
	/* Overall strategy type */
	BufferAccessStrategyType btype;
	/* Number of elements in buffers[] array */
	int			nbuffers;

	/*
	 * Index of the "current" slot in the ring, ie, the one most recently
	 * returned by GetBufferFromRing.
	 */
	int			current;

	/*
	 * Array of buffer numbers.  InvalidBuffer (that is, zero) indicates we
	 * have not yet selected a buffer for this ring slot.  For allocation
	 * simplicity this is palloc'd together with the fixed fields of the
	 * struct.
	 */
	Buffer		buffers[FLEXIBLE_ARRAY_MEMBER];
}			BufferAccessStrategyData;


/* Prototypes for internal functions */
static BufferDesc *GetBufferFromRing(BufferAccessStrategy strategy,
									 uint64 *buf_state);
static void AddBufferToRing(BufferAccessStrategy strategy,
							BufferDesc *buf);

/*
 * ClockSweepTick - Helper routine for StrategyGetBuffer()
 *
 * Move the clock hand one buffer ahead of its current position and return the
 * id of the buffer now under the hand.
 */
static inline uint32
ClockSweepTick(void)
{
	uint32		victim;

	/*
	 * Atomically move hand ahead one buffer - if there's several processes
	 * doing this, this can lead to buffers being returned slightly out of
	 * apparent order.
	 */
	victim =
		pg_atomic_fetch_add_u32(&StrategyControl->nextVictimBuffer, 1);

	if (victim >= NBuffers)
	{
		uint32		originalVictim = victim;

		/* always wrap what we look up in BufferDescriptors */
		victim = victim % NBuffers;

		/*
		 * If we're the one that just caused a wraparound, force
		 * completePasses to be incremented while holding the spinlock. We
		 * need the spinlock so StrategySyncStart() can return a consistent
		 * value consisting of nextVictimBuffer and completePasses.
		 */
		if (victim == 0)
		{
			uint32		expected;
			uint32		wrapped;
			bool		success = false;

			expected = originalVictim + 1;

			while (!success)
			{
				/*
				 * Acquire the spinlock while increasing completePasses. That
				 * allows other readers to read nextVictimBuffer and
				 * completePasses in a consistent manner which is required for
				 * StrategySyncStart().  In theory delaying the increment
				 * could lead to an overflow of nextVictimBuffers, but that's
				 * highly unlikely and wouldn't be particularly harmful.
				 */
				SpinLockAcquire(&StrategyControl->buffer_strategy_lock);

				wrapped = expected % NBuffers;

				success = pg_atomic_compare_exchange_u32(&StrategyControl->nextVictimBuffer,
														 &expected, wrapped);
				if (success)
					StrategyControl->completePasses++;
				SpinLockRelease(&StrategyControl->buffer_strategy_lock);
			}
		}
	}
	return victim;
}

/*
 * StrategyGetBuffer
 *
 *	Called by the bufmgr to get the next candidate buffer to use in
 *	GetVictimBuffer(). The only hard requirement GetVictimBuffer() has is that
 *	the selected buffer must not currently be pinned by anyone.
 *
 *	strategy is a BufferAccessStrategy object, or NULL for default strategy.
 *
 *	It is the callers responsibility to ensure the buffer ownership can be
 *	tracked via TrackNewBufferPin().
 *
 *	The buffer is pinned and marked as owned, using TrackNewBufferPin(),
 *	before returning.
 */
BufferDesc *
StrategyGetBuffer(BufferAccessStrategy strategy, uint64 *buf_state, bool *from_ring)
{
	BufferDesc *buf;
	int			bgwprocno;

	*from_ring = false;

	/*
	 * If given a strategy object, see whether it can select a buffer. We
	 * assume strategy objects don't need buffer_strategy_lock.
	 */
	if (strategy != NULL)
	{
		buf = GetBufferFromRing(strategy, buf_state);
		if (buf != NULL)
		{
			*from_ring = true;
			return buf;
		}
	}

	/*
	 * If asked, we need to waken the bgwriter. Since we don't want to rely on
	 * a spinlock for this we force a read from shared memory once, and then
	 * set the latch based on that value. We need to go through that length
	 * because otherwise bgwprocno might be reset while/after we check because
	 * the compiler might just reread from memory.
	 *
	 * This can possibly set the latch of the wrong process if the bgwriter
	 * dies in the wrong moment. But since PGPROC->procLatch is never
	 * deallocated the worst consequence of that is that we set the latch of
	 * some arbitrary process.
	 */
	bgwprocno = INT_ACCESS_ONCE(StrategyControl->bgwprocno);
	if (bgwprocno != -1)
	{
		/* reset bgwprocno first, before setting the latch */
		StrategyControl->bgwprocno = -1;

		/*
		 * Not acquiring ProcArrayLock here which is slightly icky. It's
		 * actually fine because procLatch isn't ever freed, so we just can
		 * potentially set the wrong process' (or no process') latch.
		 */
		SetLatch(&GetPGProcByNumber(bgwprocno)->procLatch);
	}

	/*
	 * We count buffer allocation requests so that the bgwriter can estimate
	 * the rate of buffer consumption.  Note that buffers recycled by a
	 * strategy object are intentionally not counted here.
	 */
	pg_atomic_fetch_add_u32(&StrategyControl->numBufferAllocs, 1);

	switch (buffer_eviction_policy)
	{
		case BUFFER_EVICTION_SIEVE:
			buf = SieveGetVictim(buf_state);
			break;
		case BUFFER_EVICTION_S3FIFO:
			buf = S3FifoGetVictim(buf_state);
			break;
		default:
			/* clock-sweep and the RRIP family share the clock machinery */
			buf = ClockSweepGetVictim(buf_state);
			break;
	}

	pg_atomic_fetch_add_u64(&StrategyControl->stat_allocs, 1);

	/* Found a usable buffer */
	if (strategy != NULL)
		AddBufferToRing(strategy, buf);

	TrackNewBufferPin(BufferDescriptorGetBuffer(buf));

	return buf;
}

/*
 * CheckVictim -- examine one buffer the policy proposes to evict.
 *
 * A buffer with usage count >= keep_threshold is kept; if "age" is true its
 * usage count is decremented by one first (clock-style aging).  A pinned
 * buffer is reported busy.  Otherwise the buffer is pinned by us with a CAS
 * and VICTIM_TAKEN is returned with the new state in *buf_state.
 *
 * This is the same lock-free protocol the original clock-sweep used, so the
 * hit path (PinBuffer) never has to take any policy lock.
 */
static VictimCheck
CheckVictim(BufferDesc *buf, uint32 keep_threshold, bool age,
			uint64 *buf_state)
{
	uint64		old_buf_state = pg_atomic_read_u64(&buf->state);

	for (;;)
	{
		uint64		local_buf_state = old_buf_state;

		if (BUF_STATE_GET_REFCOUNT(local_buf_state) != 0)
			return VICTIM_BUSY;

		/* See equivalent code in PinBuffer() */
		if (unlikely(local_buf_state & BM_LOCKED))
		{
			old_buf_state = WaitBufHdrUnlocked(buf);
			continue;
		}

		if ((local_buf_state & BM_TAG_VALID) &&
			BUF_STATE_GET_USAGECOUNT(local_buf_state) >= keep_threshold)
		{
			if (!age)
				return VICTIM_KEEP;

			local_buf_state -= BUF_USAGECOUNT_ONE;
			if (pg_atomic_compare_exchange_u64(&buf->state, &old_buf_state,
											   local_buf_state))
				return VICTIM_KEEP;
			continue;
		}

		/* pin the buffer if the CAS succeeds */
		local_buf_state += BUF_REFCOUNT_ONE;
		if (pg_atomic_compare_exchange_u64(&buf->state, &old_buf_state,
										   local_buf_state))
		{
			*buf_state = local_buf_state;
			return VICTIM_TAKEN;
		}
	}
}

/*
 * Error out if we have examined every buffer without being able to make any
 * progress, i.e. all buffers are pinned.  Same rule as the original code.
 */
static inline void
CountBusyBuffer(int *trycounter)
{
	if (--(*trycounter) == 0)
		ereport(ERROR,
				errcode(ERRCODE_INSUFFICIENT_RESOURCES),
				errmsg("could not find an unpinned shared buffer"));
}

/*
 * ClockSweepGetVictim -- PostgreSQL's clock-sweep, also used by SRRIP, BRRIP
 * and DRRIP.  In RRIP terms the usage count is (max RRPV - RRPV): a hit
 * predicts a "near-immediate" re-reference, the sweep ages buffers, and a
 * buffer whose count reached zero is predicted "distant" and evicted.  The
 * RRIP variants differ from clock only in the hit and insertion rules (see
 * PinBuffer() and StrategyInitialUsage()).
 */
static BufferDesc *
ClockSweepGetVictim(uint64 *buf_state)
{
	int			trycounter = NBuffers;
	uint64		checks = 0;

	for (;;)
	{
		BufferDesc *buf = GetBufferDescriptor(ClockSweepTick());

		checks++;
		switch (CheckVictim(buf, 1, true, buf_state))
		{
			case VICTIM_BUSY:
				CountBusyBuffer(&trycounter);
				break;
			case VICTIM_KEEP:
				trycounter = NBuffers;
				break;
			case VICTIM_TAKEN:
				pg_atomic_fetch_add_u64(&StrategyControl->stat_checks, checks);
				return buf;
		}
	}
}

/* ---------------- queue primitives (BufferEvictionPolicyLock held) ---------------- */

static inline void
PolicyListRemove(int buf_id)
{
	PolicyNode *n = &PolicyNodes[buf_id];
	PolicyList *l = &StrategyControl->lists[n->queue];

	if (n->older >= 0)
		PolicyNodes[n->older].newer = n->newer;
	else
		l->tail = n->newer;
	if (n->newer >= 0)
		PolicyNodes[n->newer].older = n->older;
	else
		l->head = n->older;
	n->older = n->newer = -1;
	l->count--;
}

static inline void
PolicyListPushHead(int queue, int buf_id)
{
	PolicyNode *n = &PolicyNodes[buf_id];
	PolicyList *l = &StrategyControl->lists[queue];

	n->queue = queue;
	n->newer = -1;
	n->older = l->head;
	if (l->head >= 0)
		PolicyNodes[l->head].newer = buf_id;
	else
		l->tail = buf_id;
	l->head = buf_id;
	l->count++;
}

/* move buf_id to the head of "queue" (possibly the queue it is already in) */
static inline void
PolicyListMoveToHead(int queue, int buf_id)
{
	PolicyListRemove(buf_id);
	PolicyListPushHead(queue, buf_id);
}

#ifdef USE_ASSERT_CHECKING
/*
 * Verify the queue invariants: every buffer is in exactly one queue, links
 * are symmetric and the counts match.  O(NBuffers), so only called once in a
 * while from assert-enabled builds.
 */
static void
PolicyCheckInvariants(void)
{
	int			total = 0;

	for (int q = 0; q < 2; q++)
	{
		PolicyList *l = &StrategyControl->lists[q];
		int			n = 0;
		int			prev = -1;

		for (int b = l->tail; b >= 0; b = PolicyNodes[b].newer)
		{
			Assert(b < NBuffers);
			Assert(PolicyNodes[b].queue == q);
			Assert(PolicyNodes[b].older == prev);
			prev = b;
			n++;
			Assert(n <= NBuffers);
		}
		Assert(prev == l->head);
		Assert(n == l->count);
		total += n;
	}
	Assert(total == NBuffers);
}

#define MAYBE_CHECK_INVARIANTS() \
	do { \
		if ((pg_atomic_read_u64(&StrategyControl->stat_allocs) & 1023) == 0) \
			PolicyCheckInvariants(); \
	} while (0)
#else
#define MAYBE_CHECK_INVARIANTS() ((void) 0)
#endif

/*
 * SieveGetVictim -- SIEVE (Zhang et al., NSDI 2024).
 *
 * One FIFO of all buffers, new pages enter at the head.  The hand walks from
 * the tail towards the head; a visited buffer (usage count 1) has its bit
 * cleared and stays in place, an unvisited one is evicted.  Unlike CLOCK the
 * survivors are never moved, and the victim's slot is reinserted at the head
 * as the new page.  Hits only set the visited bit (BufferMaxUsageCount = 1).
 */
static BufferDesc *
SieveGetVictim(uint64 *buf_state)
{
	int			trycounter = NBuffers;
	uint64		checks = 0;

	LWLockAcquire(BufferEvictionPolicyLock, LW_EXCLUSIVE);
	MAYBE_CHECK_INVARIANTS();

	for (;;)
	{
		int			b = StrategyControl->sieve_hand;
		BufferDesc *buf;
		VictimCheck r;

		if (b < 0)
			b = StrategyControl->lists[0].tail;
		buf = GetBufferDescriptor(b);
		checks++;

		r = CheckVictim(buf, 1, true, buf_state);

		/* in every case the hand advances one step towards the head */
		StrategyControl->sieve_hand = PolicyNodes[b].newer;

		if (r == VICTIM_TAKEN)
		{
			/* the slot becomes the newest object */
			PolicyListMoveToHead(0, b);
			LWLockRelease(BufferEvictionPolicyLock);
			pg_atomic_fetch_add_u64(&StrategyControl->stat_checks, checks);
			return buf;
		}
		if (r == VICTIM_BUSY)
			CountBusyBuffer(&trycounter);
		else
			trycounter = NBuffers;
	}
}

/* ---------------- S3-FIFO ghost queue ---------------- */

static void
GhostInsert(const BufferTag *tag)
{
	uint64		pos = StrategyControl->ghost_next++;
	int			slot = (int) (pos % StrategyControl->ghost_capacity);
	GhostEntry *e;
	bool		found;

	/* the ring is full: forget the oldest entry, unless it was re-inserted */
	if (pos >= (uint64) StrategyControl->ghost_capacity)
	{
		e = hash_search(GhostHash, &GhostRing[slot], HASH_FIND, NULL);
		if (e != NULL && e->pos == pos - StrategyControl->ghost_capacity)
			hash_search(GhostHash, &GhostRing[slot], HASH_REMOVE, NULL);
	}

	GhostRing[slot] = *tag;
	e = hash_search(GhostHash, tag, HASH_ENTER_NULL, &found);
	if (e != NULL)
		e->pos = pos;
	pg_atomic_fetch_add_u64(&StrategyControl->stat_ghost_inserts, 1);
}

static bool
GhostRemove(const BufferTag *tag)
{
	return hash_search(GhostHash, tag, HASH_REMOVE, NULL) != NULL;
}

/*
 * S3FifoGetVictim -- S3-FIFO (Yang et al., SOSP 2023).
 *
 * Small FIFO S (10% of buffers) and main FIFO M (the rest); a ghost FIFO G
 * remembers tags recently evicted from S.  New pages go to S, or to M if
 * their tag is in G.  Usage count is the 2-bit frequency (max 3).
 *
 * evict: if |S| > target, look at the tail of S: re-referenced buffers are
 * promoted to M, others are evicted and their tag enters G.  Otherwise look
 * at the tail of M: if freq > 0, decrement and reinsert at the head of M,
 * else evict.  Pinned buffers are rotated to the head of their queue.
 *
 * The chosen slot is provisionally moved to the head of its queue so that a
 * victim that GetVictimBuffer() ends up not using is not offered again
 * immediately; StrategyBufferInserted() then puts it in the right queue.
 */
static BufferDesc *
S3FifoGetVictim(uint64 *buf_state)
{
	int			trycounter = NBuffers;
	uint64		checks = 0;
	int			busy[2] = {0, 0};	/* pinned buffers rotated, per queue */
	PolicyList *small = &StrategyControl->lists[S3_SMALL];
	PolicyList *main = &StrategyControl->lists[S3_MAIN];

	LWLockAcquire(BufferEvictionPolicyLock, LW_EXCLUSIVE);
	MAYBE_CHECK_INVARIANTS();

	for (;;)
	{
		bool		from_small = small->count > StrategyControl->s3_small_target ||
			main->count == 0;
		int			q;
		int			b;
		BufferDesc *buf;
		VictimCheck r;

		/*
		 * If every buffer of the preferred queue was found pinned during this
		 * search, take the victim from the other queue instead.  Without this
		 * a fully pinned small queue (e.g. a GiST build pinning many pages
		 * with a tiny shared_buffers) would make us rotate S until we
		 * wrongly concluded that all of shared buffers is pinned.
		 */
		if (from_small && busy[S3_SMALL] >= small->count && main->count > 0)
			from_small = false;
		else if (!from_small && busy[S3_MAIN] >= main->count && small->count > 0)
			from_small = true;

		q = from_small ? S3_SMALL : S3_MAIN;
		b = StrategyControl->lists[q].tail;
		buf = GetBufferDescriptor(b);

		checks++;
		if (from_small)
			r = CheckVictim(buf, S3FIFO_MOVE_THRESHOLD, false, buf_state);
		else
			r = CheckVictim(buf, 1, true, buf_state);

		switch (r)
		{
			case VICTIM_BUSY:
				PolicyListMoveToHead(q, b);
				busy[q]++;
				CountBusyBuffer(&trycounter);
				break;

			case VICTIM_KEEP:
				/* small: promote to main; main: reinsert (freq was aged) */
				PolicyListMoveToHead(S3_MAIN, b);
				busy[q] = 0;
				if (from_small)
					pg_atomic_fetch_add_u64(&StrategyControl->stat_small_to_main, 1);
				trycounter = NBuffers;
				break;

			case VICTIM_TAKEN:
				/* we hold a pin, so the tag is stable */
				if (from_small && (*buf_state & BM_TAG_VALID))
					GhostInsert(&buf->tag);
				PolicyListMoveToHead(q, b);
				LWLockRelease(BufferEvictionPolicyLock);
				pg_atomic_fetch_add_u64(&StrategyControl->stat_checks, checks);
				return buf;
		}
	}
}

/*
 * StrategyBufferInserted -- a victim buffer has just been given a new tag.
 *
 * For S3-FIFO, decide between the small and the main queue by consulting the
 * ghost queue.  SIEVE already put the slot at the head of its only queue, and
 * the clock policies have nothing to do.
 */
void
StrategyBufferInserted(BufferDesc *buf, const BufferTag *tag)
{
	int			want;

	if (buffer_eviction_policy != BUFFER_EVICTION_S3FIFO)
		return;

	LWLockAcquire(BufferEvictionPolicyLock, LW_EXCLUSIVE);
	if (GhostRemove(tag))
	{
		want = S3_MAIN;
		pg_atomic_fetch_add_u64(&StrategyControl->stat_ghost_hits, 1);
	}
	else
		want = S3_SMALL;

	if (PolicyNodes[buf->buf_id].queue != want)
		PolicyListMoveToHead(want, buf->buf_id);
	LWLockRelease(BufferEvictionPolicyLock);
}

/* saturating update of the DRRIP policy selector, 0..DRRIP_PSEL_MAX */
static inline void
PselAdd(int delta)
{
	pg_atomic_uint32 *psel = &StrategyControl->drrip_psel;
	uint32		old = pg_atomic_read_u32(psel);

	for (;;)
	{
		uint32		new;

		if (delta > 0 && old >= DRRIP_PSEL_MAX)
			return;
		if (delta < 0 && old == 0)
			return;
		new = old + delta;
		if (pg_atomic_compare_exchange_u32(psel, &old, new))
			return;
	}
}

/* BRRIP insertion: "distant" (0) usually, "long" (1) with probability 1/32 */
static inline uint64
BrripInsertion(void)
{
	if (pg_prng_uint32(&pg_global_prng_state) % BRRIP_EPSILON == 0)
		return BUF_USAGECOUNT_ONE;
	return 0;
}

/*
 * StrategyInitialUsage -- usage count bits for a newly loaded page.
 *
 * "hashcode" is the buffer-mapping hash of the page's tag; DRRIP uses it to
 * assign pages to leader groups (the analogue of leader cache sets in the
 * set-dueling scheme of Qureshi et al. / Jaleel et al.).  A miss on an SRRIP
 * leader page increments PSEL, a miss on a BRRIP leader decrements it, and
 * follower pages use BRRIP while PSEL is in its upper half.
 *
 * Called with the buffer header lock held, so it must not block.
 */
uint64
StrategyInitialUsage(uint32 hashcode)
{
	switch (buffer_eviction_policy)
	{
		case BUFFER_EVICTION_CLOCK:
		case BUFFER_EVICTION_SRRIP:
			return BUF_USAGECOUNT_ONE;

		case BUFFER_EVICTION_BRRIP:
			return BrripInsertion();

		case BUFFER_EVICTION_DRRIP:
			{
				/* use bits not consumed by the partition/bucket selection */
				uint32		group = (hashcode >> 16) % DRRIP_GROUPS;

				if (group == 0)
				{
					PselAdd(1);
					return BUF_USAGECOUNT_ONE;
				}
				if (group == 1)
				{
					PselAdd(-1);
					return BrripInsertion();
				}
				if (pg_atomic_read_u32(&StrategyControl->drrip_psel) > DRRIP_PSEL_MAX / 2)
					return BrripInsertion();
				return BUF_USAGECOUNT_ONE;
			}

		default:
			/* SIEVE and S3-FIFO: not yet visited / freq 0 */
			return 0;
	}
}

/*
 * StrategySyncStart -- tell BgBufferSync where to start syncing
 *
 * The result is the buffer index of the best buffer to sync first.
 * BgBufferSync() will proceed circularly around the buffer array from there.
 *
 * In addition, we return the completed-pass count (which is effectively
 * the higher-order bits of nextVictimBuffer) and the count of recent buffer
 * allocs if non-NULL pointers are passed.  The alloc count is reset after
 * being read.
 */
int
StrategySyncStart(uint32 *complete_passes, uint32 *num_buf_alloc)
{
	uint32		nextVictimBuffer;
	int			result;

	SpinLockAcquire(&StrategyControl->buffer_strategy_lock);
	nextVictimBuffer = pg_atomic_read_u32(&StrategyControl->nextVictimBuffer);
	result = nextVictimBuffer % NBuffers;

	if (complete_passes)
	{
		*complete_passes = StrategyControl->completePasses;

		/*
		 * Additionally add the number of wraparounds that happened before
		 * completePasses could be incremented. C.f. ClockSweepTick().
		 */
		*complete_passes += nextVictimBuffer / NBuffers;
	}

	if (num_buf_alloc)
	{
		*num_buf_alloc = pg_atomic_exchange_u32(&StrategyControl->numBufferAllocs, 0);
	}
	SpinLockRelease(&StrategyControl->buffer_strategy_lock);
	return result;
}

/*
 * StrategyNotifyBgWriter -- set or clear allocation notification latch
 *
 * If bgwprocno isn't -1, the next invocation of StrategyGetBuffer will
 * set that latch.  Pass -1 to clear the pending notification before it
 * happens.  This feature is used by the bgwriter process to wake itself up
 * from hibernation, and is not meant for anybody else to use.
 */
void
StrategyNotifyBgWriter(int bgwprocno)
{
	/*
	 * We acquire buffer_strategy_lock just to ensure that the store appears
	 * atomic to StrategyGetBuffer.  The bgwriter should call this rather
	 * infrequently, so there's no performance penalty from being safe.
	 */
	SpinLockAcquire(&StrategyControl->buffer_strategy_lock);
	StrategyControl->bgwprocno = bgwprocno;
	SpinLockRelease(&StrategyControl->buffer_strategy_lock);
}


/*
 * StrategyCtlShmemRequest -- request shared memory for the buffer
 *		cache replacement strategy.
 */
/* S3-FIFO: small queue is 10% of the buffers, the ghost holds as many tags as M */
static inline int
S3FifoSmallTarget(void)
{
	return Max(1, NBuffers / 10);
}

static inline int
S3FifoGhostCapacity(void)
{
	return Max(1, NBuffers - S3FifoSmallTarget());
}

static void
StrategyCtlShmemRequest(void *arg)
{
	ShmemRequestStruct(.name = "Buffer Strategy Status",
					   .size = sizeof(BufferStrategyControl),
					   .ptr = (void **) &StrategyControl
		);

	/* the queue-based policies need per-buffer links */
	if (POLICY_USES_QUEUES(buffer_eviction_policy))
		ShmemRequestStruct(.name = "Buffer Eviction Policy Nodes",
						   .size = mul_size(NBuffers, sizeof(PolicyNode)),
						   .ptr = (void **) &PolicyNodes
			);

	if (buffer_eviction_policy == BUFFER_EVICTION_S3FIFO)
	{
		int			ghost = S3FifoGhostCapacity();

		ShmemRequestStruct(.name = "Buffer Eviction Ghost Ring",
						   .size = mul_size(ghost, sizeof(BufferTag)),
						   .ptr = (void **) &GhostRing
			);
		ShmemRequestHash(.name = "Buffer Eviction Ghost Table",
						 .nelems = ghost + 16,
						 .ptr = &GhostHash,
						 .hash_info.keysize = sizeof(BufferTag),
						 .hash_info.entrysize = sizeof(GhostEntry),
						 .hash_flags = HASH_ELEM | HASH_BLOBS | HASH_FIXED_SIZE,
			);
	}
}

/*
 * StrategyCtlShmemInit -- initialize the buffer cache replacement strategy.
 */
static void
StrategyCtlShmemInit(void *arg)
{
	SpinLockInit(&StrategyControl->buffer_strategy_lock);

	/* Initialize the clock-sweep pointer */
	pg_atomic_init_u32(&StrategyControl->nextVictimBuffer, 0);

	/* Clear statistics */
	StrategyControl->completePasses = 0;
	pg_atomic_init_u32(&StrategyControl->numBufferAllocs, 0);

	/* No pending notification */
	StrategyControl->bgwprocno = -1;

	/* alternative policies */
	StrategyControl->sieve_hand = -1;
	StrategyControl->s3_small_target = S3FifoSmallTarget();
	StrategyControl->ghost_capacity = S3FifoGhostCapacity();
	StrategyControl->ghost_next = 0;
	pg_atomic_init_u32(&StrategyControl->drrip_psel, DRRIP_PSEL_MAX / 2);
	pg_atomic_init_u64(&StrategyControl->stat_allocs, 0);
	pg_atomic_init_u64(&StrategyControl->stat_checks, 0);
	pg_atomic_init_u64(&StrategyControl->stat_small_to_main, 0);
	pg_atomic_init_u64(&StrategyControl->stat_ghost_inserts, 0);
	pg_atomic_init_u64(&StrategyControl->stat_ghost_hits, 0);
	pg_atomic_init_u64(&StrategyControl->trace_seq, 0);

	for (int q = 0; q < 2; q++)
	{
		StrategyControl->lists[q].head = -1;
		StrategyControl->lists[q].tail = -1;
		StrategyControl->lists[q].count = 0;
	}

	/*
	 * All buffers start out empty.  SIEVE keeps them in its single queue;
	 * S3-FIFO starts with them in the main queue so that the small queue
	 * fills up with real pages first.  Buffer 0 ends up at the tail.
	 */
	if (POLICY_USES_QUEUES(buffer_eviction_policy))
	{
		int			q = buffer_eviction_policy == BUFFER_EVICTION_S3FIFO ? S3_MAIN : 0;

		for (int i = 0; i < NBuffers; i++)
			PolicyListPushHead(q, i);
	}

	/* make the active policy visible in the server log of every run */
	for (const struct config_enum_entry *e = buffer_eviction_policy_options; e->name; e++)
		if (e->val == buffer_eviction_policy)
			elog(LOG, "buffer eviction policy: %s, shared_buffers: %d pages, max usage count: %d",
				 e->name, NBuffers, BufferMaxUsageCount);
}

/*
 * GUC assign hook: derive the hit-path parameters.  Runs in every process
 * that loads the GUC, so PinBuffer() can read plain variables.
 */
void
assign_buffer_eviction_policy(int newval, void *extra)
{
	switch (newval)
	{
		case BUFFER_EVICTION_SRRIP:
		case BUFFER_EVICTION_BRRIP:
		case BUFFER_EVICTION_DRRIP:
			/* 2-bit RRPV as in Jaleel et al., hit priority */
			BufferMaxUsageCount = 3;
			BufferHitToMax = true;
			break;
		case BUFFER_EVICTION_SIEVE:
			/* a single visited bit */
			BufferMaxUsageCount = 1;
			BufferHitToMax = false;
			break;
		case BUFFER_EVICTION_S3FIFO:
			/* 2-bit frequency counter */
			BufferMaxUsageCount = 3;
			BufferHitToMax = false;
			break;
		default:
			BufferMaxUsageCount = BM_MAX_USAGE_COUNT;
			BufferHitToMax = false;
			break;
	}
}

/*
 * pg_buffer_eviction_stats -- counters of the replacement policy since the
 * last reset.  buffers_checked / allocs is the average number of buffers the
 * policy examined to find one victim.
 */
Datum
pg_buffer_eviction_stats(PG_FUNCTION_ARGS)
{
	TupleDesc	tupdesc;
	Datum		values[7];
	bool		nulls[7] = {0};
	const char *name = "unknown";

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");

	for (const struct config_enum_entry *e = buffer_eviction_policy_options; e->name; e++)
		if (e->val == buffer_eviction_policy)
			name = e->name;

	values[0] = CStringGetTextDatum(name);
	values[1] = Int64GetDatum((int64) pg_atomic_read_u64(&StrategyControl->stat_allocs));
	values[2] = Int64GetDatum((int64) pg_atomic_read_u64(&StrategyControl->stat_checks));
	values[3] = Int64GetDatum((int64) pg_atomic_read_u64(&StrategyControl->stat_small_to_main));
	values[4] = Int64GetDatum((int64) pg_atomic_read_u64(&StrategyControl->stat_ghost_inserts));
	values[5] = Int64GetDatum((int64) pg_atomic_read_u64(&StrategyControl->stat_ghost_hits));
	values[6] = Int32GetDatum((int32) pg_atomic_read_u32(&StrategyControl->drrip_psel));

	PG_RETURN_DATUM(HeapTupleGetDatum(heap_form_tuple(tupdesc, values, nulls)));
}

Datum
pg_buffer_eviction_stats_reset(PG_FUNCTION_ARGS)
{
	pg_atomic_write_u64(&StrategyControl->stat_allocs, 0);
	pg_atomic_write_u64(&StrategyControl->stat_checks, 0);
	pg_atomic_write_u64(&StrategyControl->stat_small_to_main, 0);
	pg_atomic_write_u64(&StrategyControl->stat_ghost_inserts, 0);
	pg_atomic_write_u64(&StrategyControl->stat_ghost_hits, 0);
	PG_RETURN_VOID();
}

/* ---------------- buffer access tracing ---------------- */

/*
 * One record per shared-buffer lookup.  "seq" comes from a global counter so
 * the per-backend files can be merged into one total order offline.
 */
typedef struct BufferTraceRecord
{
	uint64		seq;
	uint32		db;
	uint32		rel;
	uint32		block;
	uint8		fork;
	uint8		flags;			/* BUFTRACE_* */
	uint16		pad;
} BufferTraceRecord;

StaticAssertDecl(sizeof(BufferTraceRecord) == 24, "unexpected trace record size");

static FILE *trace_file = NULL;
static bool trace_failed = false;

static void
BufferTraceClose(int code, Datum arg)
{
	if (trace_file != NULL)
	{
		fclose(trace_file);
		trace_file = NULL;
	}
}

void
BufferTraceAccess(const BufferTag *tag, int flags)
{
	BufferTraceRecord rec;

	if (trace_file == NULL)
	{
		char		path[MAXPGPATH];

		if (trace_failed)
			return;
		snprintf(path, sizeof(path), "%s/trace.%d.%lld.bin",
				 buffer_trace_directory, MyProcPid, (long long) MyStartTime);
		trace_file = fopen(path, "wb");
		if (trace_file == NULL)
		{
			trace_failed = true;
			elog(WARNING, "could not open buffer trace file \"%s\": %m", path);
			return;
		}
		setvbuf(trace_file, NULL, _IOFBF, 1024 * 1024);
		on_proc_exit(BufferTraceClose, 0);
	}

	rec.seq = pg_atomic_fetch_add_u64(&StrategyControl->trace_seq, 1);
	rec.db = tag->dbOid;
	rec.rel = tag->relNumber;
	rec.block = tag->blockNum;
	rec.fork = (uint8) tag->forkNum;
	rec.flags = (uint8) flags;
	rec.pad = 0;
	fwrite(&rec, sizeof(rec), 1, trace_file);
}


/* ----------------------------------------------------------------
 *				Backend-private buffer ring management
 * ----------------------------------------------------------------
 */


/*
 * GetAccessStrategy -- create a BufferAccessStrategy object
 *
 * The object is allocated in the current memory context.
 */
BufferAccessStrategy
GetAccessStrategy(BufferAccessStrategyType btype)
{
	int			ring_size_kb;

	/*
	 * Select ring size to use.  See buffer/README for rationales.
	 *
	 * Note: if you change the ring size for BAS_BULKREAD, see also
	 * SYNC_SCAN_REPORT_INTERVAL in access/heap/syncscan.c.
	 */
	switch (btype)
	{
		case BAS_NORMAL:
			/* if someone asks for NORMAL, just give 'em a "default" object */
			return NULL;

		case BAS_BULKREAD:
			{
				int			ring_max_kb;

				/*
				 * The ring always needs to be large enough to allow some
				 * separation in time between providing a buffer to the user
				 * of the strategy and that buffer being reused. Otherwise the
				 * user's pin will prevent reuse of the buffer, even without
				 * concurrent activity.
				 *
				 * We also need to ensure the ring always is large enough for
				 * SYNC_SCAN_REPORT_INTERVAL, as noted above.
				 *
				 * Thus we start out a minimal size and increase the size
				 * further if appropriate.
				 */
				ring_size_kb = 256;

				/*
				 * There's no point in a larger ring if we won't be allowed to
				 * pin sufficiently many buffers.  But we never limit to less
				 * than the minimal size above.
				 */
				ring_max_kb = GetPinLimit() * (BLCKSZ / 1024);
				ring_max_kb = Max(ring_size_kb, ring_max_kb);

				/*
				 * We would like the ring to additionally have space for the
				 * configured degree of IO concurrency. While being read in,
				 * buffers can obviously not yet be reused.
				 *
				 * Each IO can be up to io_combine_limit blocks large, and we
				 * want to start up to effective_io_concurrency IOs.
				 *
				 * Note that effective_io_concurrency may be 0, which disables
				 * AIO.
				 */
				ring_size_kb += (BLCKSZ / 1024) *
					io_combine_limit * effective_io_concurrency;

				if (ring_size_kb > ring_max_kb)
					ring_size_kb = ring_max_kb;
				break;
			}
		case BAS_BULKWRITE:
			ring_size_kb = 16 * 1024;
			break;
		case BAS_VACUUM:
			ring_size_kb = 2048;
			break;

		default:
			elog(ERROR, "unrecognized buffer access strategy: %d",
				 (int) btype);
			return NULL;		/* keep compiler quiet */
	}

	return GetAccessStrategyWithSize(btype, ring_size_kb);
}

/*
 * GetAccessStrategyWithSize -- create a BufferAccessStrategy object with a
 *		number of buffers equivalent to the passed in size.
 *
 * If the given ring size is 0, no BufferAccessStrategy will be created and
 * the function will return NULL.  ring_size_kb must not be negative.
 */
BufferAccessStrategy
GetAccessStrategyWithSize(BufferAccessStrategyType btype, int ring_size_kb)
{
	int			ring_buffers;
	BufferAccessStrategy strategy;

	Assert(ring_size_kb >= 0);

	/* Figure out how many buffers ring_size_kb is */
	ring_buffers = ring_size_kb / (BLCKSZ / 1024);

	/* 0 means unlimited, so no BufferAccessStrategy required */
	if (ring_buffers == 0)
		return NULL;

	/* Cap to 1/8th of shared_buffers */
	ring_buffers = Min(NBuffers / 8, ring_buffers);

	/* NBuffers should never be less than 16, so this shouldn't happen */
	Assert(ring_buffers > 0);

	/* Allocate the object and initialize all elements to zeroes */
	strategy = (BufferAccessStrategy)
		palloc0(offsetof(BufferAccessStrategyData, buffers) +
				ring_buffers * sizeof(Buffer));

	/* Set fields that don't start out zero */
	strategy->btype = btype;
	strategy->nbuffers = ring_buffers;

	return strategy;
}

/*
 * GetAccessStrategyBufferCount -- an accessor for the number of buffers in
 *		the ring
 *
 * Returns 0 on NULL input to match behavior of GetAccessStrategyWithSize()
 * returning NULL with 0 size.
 */
int
GetAccessStrategyBufferCount(BufferAccessStrategy strategy)
{
	if (strategy == NULL)
		return 0;

	return strategy->nbuffers;
}

/*
 * GetAccessStrategyPinLimit -- get cap of number of buffers that should be pinned
 *
 * When pinning extra buffers to look ahead, users of a ring-based strategy are
 * in danger of pinning too much of the ring at once while performing look-ahead.
 * For some strategies, that means "escaping" from the ring, and in others it
 * means forcing dirty data to disk very frequently with associated WAL
 * flushing.  Since external code has no insight into any of that, allow
 * individual strategy types to expose a clamp that should be applied when
 * deciding on a maximum number of buffers to pin at once.
 *
 * Callers should combine this number with other relevant limits and take the
 * minimum.
 */
int
GetAccessStrategyPinLimit(BufferAccessStrategy strategy)
{
	if (strategy == NULL)
		return NBuffers;

	switch (strategy->btype)
	{
		case BAS_BULKREAD:

			/*
			 * Since BAS_BULKREAD uses StrategyRejectBuffer(), dirty buffers
			 * shouldn't be a problem and the caller is free to pin up to the
			 * entire ring at once.
			 */
			return strategy->nbuffers;

		default:

			/*
			 * Tell caller not to pin more than half the buffers in the ring.
			 * This is a trade-off between look ahead distance and deferring
			 * writeback and associated WAL traffic.
			 */
			return strategy->nbuffers / 2;
	}
}

/*
 * FreeAccessStrategy -- release a BufferAccessStrategy object
 *
 * A simple pfree would do at the moment, but we would prefer that callers
 * don't assume that much about the representation of BufferAccessStrategy.
 */
void
FreeAccessStrategy(BufferAccessStrategy strategy)
{
	/* don't crash if called on a "default" strategy */
	if (strategy != NULL)
		pfree(strategy);
}

/*
 * GetBufferFromRing -- returns a buffer from the ring, or NULL if the
 *		ring is empty / not usable.
 *
 * The buffer is pinned and marked as owned, using TrackNewBufferPin(), before
 * returning.
 */
static BufferDesc *
GetBufferFromRing(BufferAccessStrategy strategy, uint64 *buf_state)
{
	BufferDesc *buf;
	Buffer		bufnum;
	uint64		old_buf_state;
	uint64		local_buf_state;	/* to avoid repeated (de-)referencing */


	/* Advance to next ring slot */
	if (++strategy->current >= strategy->nbuffers)
		strategy->current = 0;

	/*
	 * If the slot hasn't been filled yet, tell the caller to allocate a new
	 * buffer with the normal allocation strategy.  He will then fill this
	 * slot by calling AddBufferToRing with the new buffer.
	 */
	bufnum = strategy->buffers[strategy->current];
	if (bufnum == InvalidBuffer)
		return NULL;

	buf = GetBufferDescriptor(bufnum - 1);

	/*
	 * Check whether the buffer can be used and pin it if so. Do this using a
	 * CAS loop, to avoid having to lock the buffer header.
	 */
	old_buf_state = pg_atomic_read_u64(&buf->state);
	for (;;)
	{
		local_buf_state = old_buf_state;

		/*
		 * If the buffer is pinned we cannot use it under any circumstances.
		 *
		 * If usage_count is 0 or 1 then the buffer is fair game (we expect 1,
		 * since our own previous usage of the ring element would have left it
		 * there, but it might've been decremented by clock-sweep since then).
		 * A higher usage_count indicates someone else has touched the buffer,
		 * so we shouldn't re-use it.
		 */
		if (BUF_STATE_GET_REFCOUNT(local_buf_state) != 0
			|| BUF_STATE_GET_USAGECOUNT(local_buf_state) > 1)
			break;

		/* See equivalent code in PinBuffer() */
		if (unlikely(local_buf_state & BM_LOCKED))
		{
			old_buf_state = WaitBufHdrUnlocked(buf);
			continue;
		}

		/* pin the buffer if the CAS succeeds */
		local_buf_state += BUF_REFCOUNT_ONE;

		if (pg_atomic_compare_exchange_u64(&buf->state, &old_buf_state,
										   local_buf_state))
		{
			*buf_state = local_buf_state;

			TrackNewBufferPin(BufferDescriptorGetBuffer(buf));
			return buf;
		}
	}

	/*
	 * Tell caller to allocate a new buffer with the normal allocation
	 * strategy.  He'll then replace this ring element via AddBufferToRing.
	 */
	return NULL;
}

/*
 * AddBufferToRing -- add a buffer to the buffer ring
 *
 * Caller must hold the buffer header spinlock on the buffer.  Since this
 * is called with the spinlock held, it had better be quite cheap.
 */
static void
AddBufferToRing(BufferAccessStrategy strategy, BufferDesc *buf)
{
	strategy->buffers[strategy->current] = BufferDescriptorGetBuffer(buf);
}

/*
 * Utility function returning the IOContext of a given BufferAccessStrategy's
 * strategy ring.
 */
IOContext
IOContextForStrategy(BufferAccessStrategy strategy)
{
	if (!strategy)
		return IOCONTEXT_NORMAL;

	switch (strategy->btype)
	{
		case BAS_NORMAL:

			/*
			 * Currently, GetAccessStrategy() returns NULL for
			 * BufferAccessStrategyType BAS_NORMAL, so this case is
			 * unreachable.
			 */
			pg_unreachable();
			return IOCONTEXT_NORMAL;
		case BAS_BULKREAD:
			return IOCONTEXT_BULKREAD;
		case BAS_BULKWRITE:
			return IOCONTEXT_BULKWRITE;
		case BAS_VACUUM:
			return IOCONTEXT_VACUUM;
	}

	elog(ERROR, "unrecognized BufferAccessStrategyType: %d", strategy->btype);
	pg_unreachable();
}

/*
 * StrategyRejectBuffer -- consider rejecting a dirty buffer
 *
 * When a nondefault strategy is used, the buffer manager calls this function
 * when it turns out that the buffer selected by StrategyGetBuffer needs to
 * be written out and doing so would require flushing WAL too.  This gives us
 * a chance to choose a different victim.
 *
 * Returns true if buffer manager should ask for a new victim, and false
 * if this buffer should be written and re-used.
 */
bool
StrategyRejectBuffer(BufferAccessStrategy strategy, BufferDesc *buf, bool from_ring)
{
	/* We only do this in bulkread mode */
	if (strategy->btype != BAS_BULKREAD)
		return false;

	/* Don't muck with behavior of normal buffer-replacement strategy */
	if (!from_ring ||
		strategy->buffers[strategy->current] != BufferDescriptorGetBuffer(buf))
		return false;

	/*
	 * Remove the dirty buffer from the ring; necessary to prevent infinite
	 * loop if all ring members are dirty.
	 */
	strategy->buffers[strategy->current] = InvalidBuffer;

	return true;
}
