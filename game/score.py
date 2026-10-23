#!/usr/bin/env python3
import json
from round_plan import CREDIT_WEIGHT, load, theoretical_max
m=json.load(open('/tmp/game-monitor.json')); k=json.load(open('/tmp/k6-summary.json'))
plan=load()
metrics=k.get('metrics',{})
reqs=int(metrics.get('http_reqs',{}).get('values',{}).get('count',0))
checks=metrics.get('checks',{}).get('values',{})
rate=float(checks.get('rate',0)); completed=round(reqs*rate); missed=max(0,reqs-completed)
credits=round(m['credits'],1)
# Game currency: completion dominates, preserving credits breaks close outcomes.
score=completed + round(credits*CREDIT_WEIGHT) - missed
best=theoretical_max(plan)
print('\n=== ROUND COMPLETE ===')
if plan['mode']=='scored': print(f'Round seed:      {plan["seed"]}')
print(f'Jobs sent:       {reqs}')
print(f'Completed:       {completed}')
print(f'Missed:          {missed}')
print(f'Success rate:    {rate*100:.1f}%')
print(f'Credits left:    {credits}/100')
print(f'FINAL SCORE:     {score}')
print(f'Theoretical max: {best}  (perfect instant scaling; not reachable in practice)')
print(f'Efficiency:      {score/best*100:.1f}%  <- compare this with other players' if best>0 else '')
