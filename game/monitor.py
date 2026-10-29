#!/usr/bin/env python3
import json, os, subprocess, sys, time
from round_plan import BURN_PER_TASK_PER_SEC, MAX_TASKS, STARTING_CREDITS, forecast, load
mode=sys.argv[1] if len(sys.argv)>1 else 'practice'
plan=load()
duration=plan['duration']
credits=STARTING_CREDITS
samples=[]
start=time.time()
MAX_CONSECUTIVE_FAILURES=5
last_report={}
def aws(*args):
    """Returns parsed JSON, or None if the call failed (the error is printed, at most every 30s per call type)."""
    p=subprocess.run(['aws',*args,'--output','json'],capture_output=True,text=True)
    if p.returncode==0: return json.loads(p.stdout or '{}')
    key=' '.join(args[:2]); now=time.time()
    if now-last_report.get(key,0)>30:
        lines=(p.stderr or '').strip().splitlines()
        print(f'\nAWS call failed ({key}): {lines[-1] if lines else "exit code "+str(p.returncode)}',file=sys.stderr,flush=True)
        last_report[key]=now
    return None
def set_desired(n):
    return aws('ecs','update-service','--cluster',cluster,'--service',service,'--desired-count',str(n))
cluster=os.environ['CLUSTER_NAME']; service=os.environ['SERVICE_NAME']; tg=os.environ['TG_ARN']
failures=0
while time.time()-start < duration:
    resp=aws('ecs','describe-services','--cluster',cluster,'--services',service)
    if resp is None:
        failures+=1
        if failures>=MAX_CONSECUTIVE_FAILURES:
            sys.exit('Monitor cannot read the ECS service, so the round is stopping. Check the game task role permissions.')
        time.sleep(2); continue
    failures=0
    s=(resp.get('services') or [{}])[0]
    desired=s.get('desiredCount',0); running=s.get('runningCount',0); pending=s.get('pendingCount',0)
    if desired>MAX_TASKS:
        if set_desired(MAX_TASKS) is None: print(f'WARNING: could not lower desired count to {MAX_TASKS}.',file=sys.stderr,flush=True)
        print(f'\nCapacity capped at {MAX_TASKS} tasks (desired was {desired}).')
        desired=MAX_TASKS
    h=(aws('elbv2','describe-target-health','--target-group-arn',tg) or {}).get('TargetHealthDescriptions',[])
    healthy=sum(x.get('TargetHealth',{}).get('State')=='healthy' for x in h)
    credits=max(0,credits-running*BURN_PER_TASK_PER_SEC*2)
    elapsed=int(time.time()-start); left=max(0,duration-elapsed)
    samples.append({'t':elapsed,'desired':desired,'running':running,'pending':pending,'healthy':healthy,'credits':credits})
    line=f'Time {left//60:02d}:{left%60:02d} | desired {desired} | running {running} | healthy {healthy} | credits {credits:5.1f}'
    hint=forecast(plan,elapsed)
    if hint: line+=f' | {hint}'
    # A terminal redraws one line; CloudWatch (the container case) needs one line per sample.
    if sys.stdout.isatty(): print('\r'+line.ljust(120),end='',flush=True)
    else: print(line,flush=True)
    time.sleep(2)
if sys.stdout.isatty(): print()
if mode=='scored':
    if set_desired(0) is None:
        print('WARNING: could not scale the service to 0. Run ./scripts/04-scale.sh 0',file=sys.stderr,flush=True)
    else:
        print('Round over: service scaled to 0 tasks. Scale up again before the next round.')
with open('/tmp/game-monitor.json','w') as f: json.dump({'credits':credits,'samples':samples},f)
