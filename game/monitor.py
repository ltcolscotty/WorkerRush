#!/usr/bin/env python3
import json, os, subprocess, sys, time
from round_plan import BURN_PER_TASK_PER_SEC, MAX_TASKS, STARTING_CREDITS, forecast, load
mode=sys.argv[1] if len(sys.argv)>1 else 'practice'
plan=load()
duration=plan['duration']
credits=STARTING_CREDITS
samples=[]
start=time.time()
def aws(*args):
    p=subprocess.run(['aws',*args,'--output','json'],capture_output=True,text=True)
    return json.loads(p.stdout or '{}') if p.returncode==0 else {}
def set_desired(n):
    return aws('ecs','update-service','--cluster',cluster,'--service',service,'--desired-count',str(n))
cluster=os.environ['CLUSTER_NAME']; service=os.environ['SERVICE_NAME']; tg=os.environ['TG_ARN']
while time.time()-start < duration:
    s=aws('ecs','describe-services','--cluster',cluster,'--services',service).get('services',[{}])[0]
    desired=s.get('desiredCount',0); running=s.get('runningCount',0); pending=s.get('pendingCount',0)
    if desired>MAX_TASKS:
        set_desired(MAX_TASKS)
        print(f'\nCapacity capped at {MAX_TASKS} tasks (desired was {desired}).')
        desired=MAX_TASKS
    h=aws('elbv2','describe-target-health','--target-group-arn',tg).get('TargetHealthDescriptions',[])
    healthy=sum(x.get('TargetHealth',{}).get('State')=='healthy' for x in h)
    credits=max(0,credits-running*BURN_PER_TASK_PER_SEC*2)
    elapsed=int(time.time()-start); left=max(0,duration-elapsed)
    samples.append({'t':elapsed,'desired':desired,'running':running,'pending':pending,'healthy':healthy,'credits':credits})
    line=f'Time {left//60:02d}:{left%60:02d} | desired {desired} | running {running} | healthy {healthy} | credits {credits:5.1f}'
    hint=forecast(plan,elapsed)
    if hint: line+=f' | {hint}'
    print('\r'+line.ljust(120),end='',flush=True)
    time.sleep(2)
print()
if mode=='scored':
    set_desired(0)
    print('Round over: service scaled to 0 tasks. Scale up again before the next round.')
with open('/tmp/game-monitor.json','w') as f: json.dump({'credits':credits,'samples':samples},f)
