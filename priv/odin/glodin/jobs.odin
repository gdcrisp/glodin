package glodin

import "base:runtime"
import "core:sync"
import "core:thread"

// Retain resources and copy borrowed buffers before putting them in job data.
Job :: struct {
	data:      rawptr,
	recipient: Pid,
	work:      proc(job: ^Job),
	env:       Owned_Env,
}

@(private)
jobs_mutex: sync.Mutex
@(private)
jobs: [dynamic]^thread.Thread
@(private)
pools: [dynamic]^Worker_Pool
@(private)
jobs_stopping: bool

spawn :: proc(recipient: Pid, data: rawptr, work: proc(job: ^Job)) -> bool {
	context.allocator = runtime.heap_allocator()
	sync.mutex_lock(&jobs_mutex)
	defer sync.mutex_unlock(&jobs_mutex)
	if jobs_stopping {
		return false
	}
	i := 0
	for i < len(jobs) {
		if thread.is_done(jobs[i]) {
			thread.destroy(jobs[i])
			unordered_remove(&jobs, i)
		} else {
			i += 1
		}
	}
	job := new(Job, runtime.heap_allocator())
	job^ = Job {
		data      = data,
		recipient = recipient,
		work      = work,
	}
	t := thread.create_and_start_with_data(job, proc(ptr: rawptr) {
		job := (^Job)(ptr)
		defer free(job, runtime.heap_allocator())
		job.env = env_new()
		defer env_destroy(&job.env)
		job.work(job)
	})
	if t == nil {
		free(job, runtime.heap_allocator())
		return false
	}
	if jobs.allocator.procedure == nil {
		jobs = make([dynamic]^thread.Thread, runtime.heap_allocator())
	}
	append(&jobs, t)
	return true
}

// The generated unload callback joins workers before their library can unload.
jobs_shutdown :: proc() {
	sync.mutex_lock(&jobs_mutex)
	jobs_stopping = true
	workers := jobs
	jobs = {}
	owned_pools := pools
	pools = {}
	sync.mutex_unlock(&jobs_mutex)
	for pool in owned_pools {
		pool_close(pool)
		delete(pool.queue, runtime.heap_allocator())
		free(pool, runtime.heap_allocator())
	}
	delete(owned_pools)
	for worker in workers {
		thread.join(worker)
		thread.destroy(worker)
	}
	delete(workers)
}

// Pool handles belong to this library instance and remain valid until unload.
// Closing drains accepted jobs; rejected submissions leave data with the caller.
Worker_Pool :: struct {
	mutex:       sync.Mutex,
	ready:       sync.Cond,
	close_mutex: sync.Mutex,
	queue:       []Job,
	head:        int,
	count:       int,
	workers:     [dynamic]^thread.Thread,
	stopping:    bool,
	closed:      bool,
}

pool_new :: proc(worker_count, queue_capacity: int) -> (^Worker_Pool, bool) {
	if worker_count <= 0 || queue_capacity <= 0 {
		return nil, false
	}
	sync.mutex_lock(&jobs_mutex)
	defer sync.mutex_unlock(&jobs_mutex)
	if jobs_stopping {
		return nil, false
	}
	allocator := runtime.heap_allocator()
	pool := new(Worker_Pool, allocator)
	pool.queue = make([]Job, queue_capacity, allocator)
	pool.workers = make([dynamic]^thread.Thread, 0, worker_count, allocator)
	for _ in 0..<worker_count {
		worker := thread.create_and_start_with_data(pool, pool_worker)
		if worker == nil {
			pool_close(pool)
			delete(pool.queue, allocator)
			free(pool, allocator)
			return nil, false
		}
		append(&pool.workers, worker)
	}
	if pools.allocator.procedure == nil {
		pools = make([dynamic]^Worker_Pool, allocator)
	}
	append(&pools, pool)
	return pool, true
}

pool_submit :: proc(pool: ^Worker_Pool, recipient: Pid, data: rawptr, work: proc(job: ^Job)) -> bool {
	if pool == nil || work == nil {
		return false
	}
	sync.mutex_lock(&pool.mutex)
	defer sync.mutex_unlock(&pool.mutex)
	if pool.stopping || pool.count == len(pool.queue) {
		return false
	}
	index := (pool.head + pool.count) % len(pool.queue)
	pool.queue[index] = Job{data = data, recipient = recipient, work = work}
	pool.count += 1
	sync.cond_signal(&pool.ready)
	return true
}

// Blocking: use a dirty I/O NIF or lifecycle callback, never a normal scheduler.
// Do not close a pool from one of its own jobs, which would join itself.
pool_close :: proc(pool: ^Worker_Pool) {
	if pool == nil {
		return
	}
	sync.mutex_lock(&pool.close_mutex)
	defer sync.mutex_unlock(&pool.close_mutex)
	if pool.closed {
		return
	}
	sync.mutex_lock(&pool.mutex)
	pool.stopping = true
	sync.cond_broadcast(&pool.ready)
	sync.mutex_unlock(&pool.mutex)
	for worker in pool.workers {
		thread.join(worker)
		thread.destroy(worker)
	}
	delete(pool.workers)
	pool.workers = {}
	pool.closed = true
}

@(private)
pool_worker :: proc(data: rawptr) {
	context.allocator = runtime.heap_allocator()
	pool := (^Worker_Pool)(data)
	for {
		sync.mutex_lock(&pool.mutex)
		for pool.count == 0 && !pool.stopping {
			sync.cond_wait(&pool.ready, &pool.mutex)
		}
		if pool.count == 0 {
			sync.mutex_unlock(&pool.mutex)
			return
		}
		job := pool.queue[pool.head]
		pool.queue[pool.head] = {}
		pool.head = (pool.head + 1) % len(pool.queue)
		pool.count -= 1
		sync.mutex_unlock(&pool.mutex)
		job.env = env_new()
		job.work(&job)
		env_destroy(&job.env)
	}
}
job_send :: proc(job: ^Job, value: $T) -> bool {
	term, ok := try_encode(job.env.env, value)
	return ok && send(nil, job.recipient, job.env.env, term)
}
