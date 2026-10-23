#!/usr/bin/env python3
"""Single source of truth for a round: load schedule, forecasts, and theoretical max score."""
import json, math, os, random, sys

SCHEDULE_FILE = '/tmp/game-schedule.json'
START_RATE = 2
WORK_MS = int(os.getenv('WORK_MS', '450'))
BURN_PER_TASK_PER_SEC = 0.018
STARTING_CREDITS = 100.0
CREDIT_WEIGHT = 5
# Can only be tightened from the environment, never raised above 4.
try: MAX_TASKS = max(0, min(4, int(os.getenv('MAX_TASKS', '4'))))
except ValueError: MAX_TASKS = 4
FORECAST_LEAD_SEC = 45

BASE_STAGES = {
    'scored': [(2, 60), (4, 60), (7, 60), (3, 60), (1, 60), (6, 90), (9, 45), (4, 75), (2, 45), (8, 45)],
    'practice': [(2, 30), (6, 30), (2, 30), (5, 30)],
}
DURATION_JITTER = 0.15   # each stage duration x U(0.85, 1.15)
TARGET_JITTER = 1        # each stage target +/- 1 rps
LOAD_TOLERANCE = 0.03    # total requests within +/- 3% of the base profile
MAX_ATTEMPTS = 500

def total_requests(stages, start=START_RATE):
    prev, area = start, 0.0
    for target, dur in stages:
        area += (prev + target) / 2 * dur; prev = target
    return area

def _directions(stages, start=START_RATE):
    prev, out = start, []
    for target, _ in stages:
        out.append((target > prev) - (target < prev)); prev = target
    return out

def _jitter(base, rng):
    total = sum(d for _, d in base)
    targets = [max(1, t + rng.randint(-TARGET_JITTER, TARGET_JITTER)) for t, _ in base]
    raw = [d * rng.uniform(1 - DURATION_JITTER, 1 + DURATION_JITTER) for _, d in base]
    durs = [round(d * total / sum(raw)) for d in raw]
    durs[-1] += total - sum(durs)
    return list(zip(targets, durs))

def build(mode, seed):
    base = BASE_STAGES[mode]
    stages = base
    if mode == 'scored':
        rng = random.Random(str(seed))
        base_load, base_dirs = total_requests(base), _directions(base)
        for _ in range(MAX_ATTEMPTS):
            cand = _jitter(base, rng)
            same_shape = all(b == 0 or b == c for b, c in zip(base_dirs, _directions(cand)))
            if same_shape and abs(total_requests(cand) - base_load) <= LOAD_TOLERANCE * base_load:
                stages = cand; break
    return {'mode': mode, 'seed': str(seed), 'startRate': START_RATE,
            'duration': sum(d for _, d in stages),
            'stages': [{'target': t, 'duration': f'{d}s'} for t, d in stages]}

def load(path=SCHEDULE_FILE):
    with open(path) as f: return json.load(f)

def _pairs(plan):
    return [(s['target'], int(s['duration'].rstrip('s'))) for s in plan['stages']]

def rate_at(plan, t):
    prev, start = plan['startRate'], 0
    for target, dur in _pairs(plan):
        if t < start + dur: return prev + (target - prev) * (t - start) / dur
        prev, start = target, start + dur
    return prev

def forecast(plan, t, lead=FORECAST_LEAD_SEC):
    prev, start = plan['startRate'], 0
    for target, dur in _pairs(plan):
        if t < start <= t + lead:
            if target >= 7 and target > prev: return '[^] Heavy demand predicted soon'
            if target - prev >= 2: return '[^] Demand predicted to increase soon'
            if prev - target >= 2: return '[v] Demand predicted to decrease soon'
            if target <= 2: return '[v] Light load predicted incoming'
            return '[=] Demand steady'
        prev, start = target, start + dur
    return ''

def theoretical_max(plan):
    """Perfect, instant scaling: an upper bound, not reachable with real Fargate startup."""
    cap = 1000.0 / WORK_MS
    served = missed = task_seconds = 0.0
    for t in range(plan['duration']):
        rate = rate_at(plan, t + 0.5)
        tasks = min(MAX_TASKS, math.ceil(rate / cap - 1e-9))
        done = min(rate, tasks * cap)
        served += done; missed += rate - done; task_seconds += tasks
    credits = max(0.0, STARTING_CREDITS - BURN_PER_TASK_PER_SEC * task_seconds)
    return round(served) + round(credits * CREDIT_WEIGHT) - round(missed)

if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'practice'
    seed = sys.argv[2] if len(sys.argv) > 2 else '0'
    if mode not in BASE_STAGES: sys.exit('Usage: round_plan.py practice|scored [seed]')
    with open(SCHEDULE_FILE, 'w') as f: json.dump(build(mode, seed), f)
