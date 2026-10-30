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
	sync.mutex_unlock(&jobs_mutex)
	for worker in workers {
		thread.join(worker)
		thread.destroy(worker)
	}
	delete(workers)
}
job_send :: proc(job: ^Job, value: $T) -> bool {
	term, ok := try_encode(job.env.env, value)
	return ok && send(nil, job.recipient, job.env.env, term)
}
