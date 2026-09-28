# frozen_string_literal: true

require_relative "helper"
require "puma/cluster"

class TestMoldCandidates < PumaTest
  MoldCandidates = Puma::Cluster::MoldCandidates

  def worker(index, requests, ready: nil, booted: true)
    w = Puma::Cluster::WorkerHandle.new index, 100 + index, 0, {}
    status = +%({ "requests_count":#{requests})
    status << %(, "mold_ready":#{ready ? 1 : 0}) unless ready.nil?
    w.ping! "#{status} }"
    w.boot! if booted
    w
  end

  def candidates(count: 1, ready_check: false, ready_timeout: 10, fallback_factor: 3)
    MoldCandidates.new count: count, ready_check: ready_check,
      ready_timeout: ready_timeout, fallback_factor: fallback_factor
  end

  def test_candidates_are_defined_by_index
    c = candidates(count: 2)
    assert c.candidate?(worker(0, 0))
    assert c.candidate?(worker(1, 0))
    refute c.candidate?(worker(2, 0))
  end

  def test_candidate_that_reaches_threshold_is_due
    c = candidates
    w0 = worker(0, 100)
    assert_same w0, c.due([w0, worker(1, 500), worker(2, 500)], 100, now: 0)
  end

  def test_non_candidate_that_reaches_threshold_is_not_due
    c = candidates
    assert_nil c.due([worker(0, 10), worker(1, 150), worker(2, 100)], 100, now: 0)
  end

  def test_starved_candidate_is_promoted_after_fallback_factor
    c = candidates(count: 2)
    w0 = worker(0, 5)
    w1 = worker(1, 20)
    assert_nil c.due([w0, w1, worker(2, 299), worker(3, 300)], 100, now: 0)

    # the other workers served on average 3 times the threshold, so the busiest candidate is promoted
    assert_same w1, c.due([w0, w1, worker(2, 300), worker(3, 300)], 100, now: 0)
  end

  def test_fallback_does_not_depend_on_number_of_workers
    c = candidates
    # 7 other workers served 3 times the threshold between them, but each served less than the threshold
    others = Array.new(7) { |i| worker(i + 1, 50) }
    assert_nil c.due([worker(0, 10), *others], 100, now: 0)
  end

  def test_waits_for_ready_candidate_until_timeout
    c = candidates(ready_check: true, ready_timeout: 10)
    w0 = worker(0, 100, ready: false)
    workers = [w0, worker(1, 100)]

    assert_nil c.due(workers, 100, now: 0)
    assert_nil c.due(workers, 100, now: 9)
    assert_same w0, c.due(workers, 100, now: 10)
  end

  def test_ready_candidate_is_promoted_without_waiting
    c = candidates(ready_check: true)
    w0 = worker(0, 100, ready: true)
    assert_same w0, c.due([w0, worker(1, 100)], 100, now: 0)
  end

  def test_prefers_ready_candidate_that_reached_threshold
    c = candidates(count: 2, ready_check: true)
    w0 = worker(0, 300, ready: false)
    w1 = worker(1, 120, ready: true)
    assert_same w1, c.due([w0, w1, worker(2, 0)], 100, now: 0)
  end

  def test_reset_restarts_ready_timeout
    c = candidates(ready_check: true, ready_timeout: 10)
    workers = [worker(0, 100, ready: false), worker(1, 0)]

    assert_nil c.due(workers, 100, now: 0)
    c.reset
    assert_nil c.due(workers, 100, now: 10)
    refute_nil c.due(workers, 100, now: 20)
  end

  def test_unbooted_candidate_is_not_due
    c = candidates
    assert_nil c.due([worker(0, 100, booted: false), worker(1, 1000)], 100, now: 0)
  end

  def test_pick_prefers_ready_candidates
    c = candidates(count: 2, ready_check: true)
    w0 = worker(0, 500, ready: false)
    w1 = worker(1, 10, ready: true)
    assert_same w1, c.pick([w0, w1, worker(2, 900)])
  end

  def test_pick_falls_back_to_any_booted_candidate
    c = candidates(count: 2, ready_check: true)
    w0 = worker(0, 500, ready: false)
    assert_same w0, c.pick([w0, worker(1, 10, booted: false), worker(2, 900)])
  end

  def test_pick_returns_nil_without_booted_candidates
    c = candidates
    assert_nil c.pick([worker(0, 10, booted: false), worker(1, 900)])
  end

  def test_from_options
    assert_nil MoldCandidates.from_options({})

    c = MoldCandidates.from_options(
      mold_worker_candidates: { count: 2, ready_timeout: 60.0, fallback_factor: 4.0 },
      mold_ready: -> { true }
    )
    assert_equal 2, c.count
    assert_equal 60.0, c.ready_timeout
    assert_equal 4.0, c.fallback_factor
    refute c.ready?(worker(0, 0, ready: false))
  end
end
